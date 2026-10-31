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
    /// Início do processo (µs desde 1970): distingue o claude de outro programa que reaproveitou o pid.
    private let started: UInt64?
    private let input: FileHandle
    private let output: FileHandle
    private let writeQueue = DispatchQueue(label: "macpet.chat.input")
    private let readQueue = DispatchQueue(label: "macpet.chat.output")
    private var outputSource: DispatchSourceFileSystemObject?
    private var exitSource: DispatchSourceProcess?

    private struct Meta: Codable {
        let pid: Int32
        let executable: String
        /// Ausente nos meta.json de versões anteriores do MacPet.
        var started: UInt64?
    }

    private init(directory: URL, pid: pid_t, started: UInt64?, input: FileHandle, output: FileHandle) {
        self.directory = directory
        self.pid = pid
        self.started = started
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
        // Um claude anterior desta conversa que ainda roda (não deu para reconectar): sem a pasta ele
        // ficaria órfão para sempre (o FIFO dele nunca fecha), então encerra antes de apagar.
        if let meta = readMeta(dir), isRunning(meta) { kill(meta.pid, SIGTERM) }
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fifo = file(dir, "in"), out = file(dir, "out.jsonl"), err = file(dir, "err.log")
        guard mkfifo(fifo, 0o600) == 0 else { throw posixError("mkfifo") }
        FileManager.default.createFile(atPath: out, contents: nil, attributes: [.posixPermissions: 0o600])

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

        let meta = Meta(pid: pid, executable: URL(fileURLWithPath: executable).resolvingSymlinksInPath().path,
                        started: startTime(of: pid))
        writeMeta(meta, dir)
        return try open(dir: dir, pid: pid, started: meta.started)
    }

    /// Reconecta a um claude iniciado antes (por esta ou por uma execução anterior do MacPet).
    static func attach(id: UUID) -> DetachedClaude? {
        let dir = directory(for: id)
        guard var meta = readMeta(dir) else { return nil }
        guard isRunning(meta) else {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        // meta.json antigo: passa a guardar o início do processo.
        if meta.started == nil, let started = startTime(of: meta.pid) {
            meta.started = started
            writeMeta(meta, dir)
        }
        return try? open(dir: dir, pid: meta.pid, started: meta.started)
    }

    private static func readMeta(_ dir: URL) -> Meta? {
        guard let data = FileManager.default.contents(atPath: file(dir, "meta.json")) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    private static func writeMeta(_ meta: Meta, _ dir: URL) {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        FileManager.default.createFile(atPath: file(dir, "meta.json"), contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// O processo do meta ainda é aquele claude? O pid pode ter sido reaproveitado por outro programa.
    /// Compara o horário de início, que não muda quando o claude se atualiza (o instalador troca o alvo do
    /// symlink `~/.local/bin/claude`, e o caminho do processo antigo deixa de bater com o do link).
    private static func isRunning(_ meta: Meta) -> Bool {
        guard kill(meta.pid, 0) == 0 else { return false }
        if let started = meta.started { return startTime(of: meta.pid) == started }
        // meta.json antigo, sem horário: confere o executável, aceitando outra versão do instalador nativo.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(meta.pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        return path == URL(fileURLWithPath: meta.executable).resolvingSymlinksInPath().path
            || path.contains("/claude/versions/")
    }

    /// Início do processo em µs desde 1970 (nil se ele não existe mais).
    private static func startTime(of pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
    }

    private static func open(dir: URL, pid: pid_t, started: UInt64?) throws -> DetachedClaude {
        // Fica não bloqueante: mensagens grandes (prompts longos, imagens) vão em pedaços (ver `writeAll`).
        // Bloqueante, uma escrita de 64 KB ou mais no FIFO travava para sempre, e com ela a fila inteira de envio.
        let fd = Darwin.open(file(dir, "in"), O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else { throw posixError("open in") }
        guard let output = FileHandle(forReadingAtPath: file(dir, "out.jsonl")) else {
            close(fd)
            throw posixError("open out")
        }
        return DetachedClaude(directory: dir, pid: pid, started: started, input: FileHandle(fileDescriptor: fd, closeOnDealloc: true), output: output)
    }

    private static func posixError(_ what: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(what): \(String(cString: strerror(errno)))"])
    }

    // MARK: Estado salvo

    /// Tamanho atual da saída: eventos até aqui vêm de `savedLines`, os seguintes de `follow`.
    var outputSize: UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: Self.file(directory, "out.jsonl"))[.size] as? UInt64) ?? 0
    }

    /// Os pedaços de texto em streaming, mensagens e progresso de agentes são quase todo o `out.jsonl`
    /// (dezenas de MB depois de um dia) e a reconexão não usa nenhum deles: saem antes do parse, que é o que custa.
    private static let skippedPrefixes = [#"{"type":"stream_event""#, #"{"type":"assistant""#, #"{"type":"user""#,
                                           #"{"type":"system","subtype":"task_progress""#].map { Data($0.utf8) }

    /// Eventos do claude (até `limit` bytes; sem texto em streaming, mensagens nem progresso de agentes)
    /// e linhas que o MacPet já enviou.
    func savedLines(upTo limit: UInt64) -> (output: [[String: Any]], input: [[String: Any]]) {
        func lines(_ name: String, limit: UInt64? = nil, skipping prefixes: [Data] = []) -> [[String: Any]] {
            guard var data = FileManager.default.contents(atPath: Self.file(directory, name)) else { return [] }
            if let limit, data.count > limit { data = data.prefix(Int(limit)) }
            return data.split(separator: UInt8(ascii: "\n"))
                .filter { line in !prefixes.contains { line.starts(with: $0) } }
                .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        return (lines("out.jsonl", limit: limit, skipping: Self.skippedPrefixes), lines("input.jsonl"))
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
                FileManager.default.createFile(atPath: log, contents: nil, attributes: [.posixPermissions: 0o600])
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
        let pid = pid, started = started
        kill(pid, SIGTERM)
        try? FileManager.default.removeItem(at: directory)
        // Com o exitSource cancelado, ninguém mais colhe o processo (viraria zumbi até o MacPet fechar).
        // Se em 5 s ele não sair com o SIGTERM (travado), encerra com SIGKILL, junto com o grupo do setsid.
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            for _ in 0..<50 {
                let reaped = waitpid(pid, &status, WNOHANG)
                if reaped == pid { return }
                // Não é filho deste MacPet (foi reconectado): só dá para ver se ainda é o mesmo processo.
                if reaped < 0, errno == ECHILD {
                    guard let now = Self.startTime(of: pid), started == nil || now == started else { return }
                }
                usleep(100_000)
            }
            if kill(-pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
            _ = waitpid(pid, &status, 0)
        }
    }
}
