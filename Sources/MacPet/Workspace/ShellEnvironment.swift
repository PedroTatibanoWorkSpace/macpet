import Foundation

/// Ambiente do shell de login do usuário. Apps abertos pelo Finder herdam um PATH mínimo
/// (/usr/bin:/bin…), sem Homebrew, nvm etc.; capturamos o ambiente do `zsh -l` uma vez.
enum ShellEnvironment {
    static let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

    static let variables: [String: String] = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "env -0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var result = ProcessInfo.processInfo.environment
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            for entry in data.split(separator: 0) {
                guard let line = String(data: entry, encoding: .utf8), let equals = line.firstIndex(of: "=") else { continue }
                result[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
        } catch {
            NSLog("MacPet: não consegui ler o ambiente do shell: \(error)")
        }
        // Processos filhos não devem achar que estão dentro do app (ex.: hooks do Claude).
        result["TERM"] = result["TERM"] ?? "xterm-256color"
        return result
    }()

    /// Caminho absoluto de um executável procurando no PATH do shell de login.
    static func which(_ name: String) -> String? {
        for dir in (variables["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { status == 0 }
}

enum Shell {
    /// Roda um executável fora da main thread e devolve stdout/stderr.
    static func run(_ executable: String, _ args: [String], in directory: String, input: String? = nil) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: directory)
                process.environment = ShellEnvironment.variables
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                let inPipe = Pipe()
                process.standardInput = input == nil ? FileHandle.nullDevice : inPipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: CommandResult(status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                if let input {
                    DispatchQueue.global().async {
                        inPipe.fileHandleForWriting.write(Data(input.utf8))
                        try? inPipe.fileHandleForWriting.close()
                    }
                }
                // Lê os dois pipes em paralelo para não travar quando a saída é grande.
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: CommandResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }
}
