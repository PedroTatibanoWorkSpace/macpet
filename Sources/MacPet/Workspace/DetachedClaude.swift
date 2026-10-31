import Darwin
import Foundation

/// Um `claude -p` que sobrevive ao MacPet fechar ou reiniciar.
///
/// O processo roda numa sessão própria (`setsid`), lê a entrada de um FIFO que ele mesmo mantém aberto
/// para escrita (então nunca recebe EOF quando o MacPet sai) e escreve os eventos num arquivo.
/// O MacPet escreve no FIFO e acompanha o arquivo; ao reabrir, reconecta pelo `meta.json`.
///
/// Arquivos em `~/.macpet/chats/<id do projeto>/`: `in` (FIFO), `out.jsonl` (eventos do claude),
/// `input.jsonl` (o que o MacPet enviou), `err.log` e `meta.json`.
final class DetachedClaude: @unchecked Sendable {
    let directory: URL
    let pid: pid_t
    private let input: FileHandle
    private let output: FileHandle
    private let writeQueue = DispatchQueue(label: "macpet.chat.input")
    private let readQueue = DispatchQueue(label: "macpet.chat.output")
    private var outputSource: DispatchSourceFileSystemObject?
    private var exitSource: DispatchSourceProcess?

    private struct Meta: Codable {
        let pid: Int32
        let executable: String
    }

    private init(directory: URL, pid: pid_t, input: FileHandle, output: FileHandle) {
        self.directory = directory
        self.pid = pid
        self.input = input
        self.output = output
    }

    static func directory(for id: UUID) -> URL {
        MacPetPaths.support.appendingPathComponent("chats/\(id.uuidString)", isDirectory: true)
    }

    private static func file(_ directory: URL, _ name: String) -> String {
        directory.appendingPathComponent(name).path
    }

    // MARK: Iniciar / reconectar

    static func launch(id: UUID, executable: String, arguments: [String], directory cwd: String,
                       environment: [String: String]) throws -> DetachedClaude {
        let dir = directory(for: id)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fifo = file(dir, "in"), out = file(dir, "out.jsonl"), err = file(dir, "err.log")
        guard mkfifo(fifo, 0o600) == 0 else { throw posixError("mkfifo") }
        FileManager.default.createFile(atPath: out, contents: nil)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // O_RDWR: o próprio claude conta como escritor do FIFO, então não vê EOF quando o MacPet sai.
        posix_spawn_file_actions_addopen(&actions, 0, fifo, O_RDWR, 0)
        posix_spawn_file_actions_addopen(&actions, 1, out, O_WRONLY | O_APPEND, 0)
        posix_spawn_file_actions_addopen(&actions, 2, err, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_addchdir_np(&actions, cwd)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }

        let meta = Meta(pid: pid, executable: executable)
        try? JSONEncoder().encode(meta).write(to: dir.appendingPathComponent("meta.json"))
        return try open(dir: dir, pid: pid)
    }

    /// Reconecta a um claude iniciado antes (por esta ou por uma execução anterior do MacPet).
    static func attach(id: UUID) -> DetachedClaude? {
        let dir = directory(for: id)
        guard let data = FileManager.default.contents(atPath: file(dir, "meta.json")),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return nil }
        // O pid pode ter sido reaproveitado por outro programa: confere o executável.
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard kill(meta.pid, 0) == 0, proc_pidpath(meta.pid, &path, UInt32(path.count)) > 0,
              URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
                == URL(fileURLWithPath: meta.executable).resolvingSymlinksInPath().path else {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        return try? open(dir: dir, pid: meta.pid)
    }

    private static func open(dir: URL, pid: pid_t) throws -> DetachedClaude {
        // Fica não bloqueante: mensagens grandes (prompts longos, imagens) vão em pedaços (ver `writeAll`).
        // Bloqueante, uma escrita de 64 KB ou mais no FIFO travava para sempre, e com ela a fila inteira de envio.
        let fd = Darwin.open(file(dir, "in"), O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else { throw posixError("open in") }
        guard let output = FileHandle(forReadingAtPath: file(dir, "out.jsonl")) else {
            close(fd)
            throw posixError("open out")
        }
        return DetachedClaude(directory: dir, pid: pid, input: FileHandle(fileDescriptor: fd, closeOnDealloc: true), output: output)
    }

    private static func posixError(_ what: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(errno)))"])
    }

    // MARK: Estado salvo

    /// Tamanho atual da saída: eventos até aqui vêm de `savedLines`, os seguintes de `follow`.
    var outputSize: UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: Self.file(directory, "out.jsonl"))[.size] as? UInt64) ?? 0
    }

    /// Eventos do claude (até `limit` bytes) e linhas que o MacPet já enviou.
    func savedLines(upTo limit: UInt64) -> (output: [[String: Any]], input: [[String: Any]]) {
        func lines(_ name: String, limit: UInt64? = nil) -> [[String: Any]] {
            guard var data = FileManager.default.contents(atPath: Self.file(directory, name)) else { return [] }
            if let limit, data.count > limit { data = data.prefix(Int(limit)) }
            return data.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        return (lines("out.jsonl", limit: limit), lines("input.jsonl"))
    }

    // MARK: Entrada e saída

    /// Acompanha a saída a partir de `offset`, entregando uma linha (evento) por vez.
    func follow(from offset: UInt64, onLine: @escaping (Data) -> Void, onExit: @escaping (String) -> Void) {
        let reader = LineReader(onLine: onLine)
        let output = output
        readQueue.sync { try? output.seek(toOffset: offset) }
        let drain = { reader.feed(output.availableData) }

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: output.fileDescriptor,
                                                               eventMask: [.extend, .write], queue: readQueue)
        source.setEventHandler(handler: drain)
        source.resume()
        outputSource = source
        readQueue.async(execute: drain)

        let pid = pid, directory = directory
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: readQueue)
        exit.setEventHandler { [weak self] in
            drain()
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG)  // só funciona se o MacPet for o pai; evita processo zumbi
            let errors = (try? String(contentsOfFile: Self.file(directory, "err.log"), encoding: .utf8)) ?? ""
            self?.stopFollowing()
            try? FileManager.default.removeItem(at: directory)
            onExit(String(errors.suffix(2000)))
        }
        exit.resume()
        exitSource = exit
    }

    func send(_ line: Data, onError: @escaping (String) -> Void) {
        var data = line
        data.append(UInt8(ascii: "\n"))
        let input = input, log = Self.file(directory, "input.jsonl")
        writeQueue.async {
            guard Self.writeAll(input.fileDescriptor, data) else {
                onError("O Claude parou de ler as mensagens. Pare a conversa e mande de novo.")
                return
            }
            // Só o necessário para reconstruir o estado ao reconectar (imagens não entram).
            if let handle = FileHandle(forWritingAtPath: log) ?? {
                FileManager.default.createFile(atPath: log, contents: nil)
                return FileHandle(forWritingAtPath: log)
            }() {
                handle.seekToEndOfFile()
                handle.write(Self.logLine(for: data))
                try? handle.close()
            }
        }
    }

    /// Escreve em pedaços de 4 KB sem bloquear: com o FIFO cheio, espera até 100 ms e tenta de novo. Desiste se
    /// o Claude ficar 20 s sem ler nada (em vez de travar a fila de envio para sempre).
    private static func writeAll(_ fd: Int32, _ data: Data, stallTimeout: TimeInterval = 20) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            var lastProgress = Date()
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, min(4096, raw.count - offset))
                if written > 0 {
                    offset += written
                    lastProgress = Date()
                } else if written < 0, errno == EAGAIN || errno == EINTR {
                    if Date().timeIntervalSince(lastProgress) > stallTimeout { return false }
                    var target = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&target, 1, 100)
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static func logLine(for data: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Data() }
        var entry: [String: Any] = ["type": object["type"] ?? ""]
        if let response = object["response"] as? [String: Any], let id = response["request_id"] { entry["request_id"] = id }
        var line = (try? JSONSerialization.data(withJSONObject: entry)) ?? Data()
        line.append(UInt8(ascii: "\n"))
        return line
    }

    /// Para de acompanhar sem encerrar o claude (ele segue trabalhando).
    func stopFollowing() {
        outputSource?.cancel()
        outputSource = nil
        exitSource?.cancel()
        exitSource = nil
    }

    func terminate() {
        stopFollowing()
        kill(pid, SIGTERM)
        try? FileManager.default.removeItem(at: directory)
    }
}
