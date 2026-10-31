import Foundation

/// Qual `claude` usar. Pode haver várias instalações (Homebrew, instalador nativo em ~/.local/bin,
/// a embutida na extensão do VS Code) em versões diferentes; modelos novos exigem versões novas,
/// então usamos a mais recente em vez da primeira do PATH.
enum ClaudeCLI {
    static let executable: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = (ShellEnvironment.variables["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        candidates.append("\(home)/.local/bin/claude")
        for editor in [".vscode", ".cursor"] {
            let extensions = "\(home)/\(editor)/extensions"
            for folder in (try? FileManager.default.contentsOfDirectory(atPath: extensions)) ?? []
            where folder.hasPrefix("anthropic.claude-code-") {
                candidates.append("\(extensions)/\(folder)/resources/native-binary/claude")
            }
        }
        var seen = Set<String>()
        let found = candidates.filter { FileManager.default.isExecutableFile(atPath: $0) }
            .filter { seen.insert(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path).inserted }
            .compactMap { path in version(of: path).map { (path: path, version: $0) } }
        return found.max { $0.version.lexicographicallyPrecedes($1.version) }?.path ?? ShellEnvironment.which("claude")
    }()

    /// Resposta do `initialize` do modo stream-json (modelos, comandos e skills, agentes, conta),
    /// como o Claude Code enxerga a partir de `directory`. Leva alguns segundos (roda os hooks de início).
    static func initialize(in directory: String) -> [String: Any]? {
        guard let executable else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                             "--no-session-persistence"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = ShellEnvironment.variables
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        defer { process.terminate() }
        let request = #"{"type":"control_request","request_id":"init","request":{"subtype":"initialize"}}"# + "\n"
        try? input.fileHandleForWriting.write(contentsOf: Data(request.utf8))

        var buffer = Data()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            // availableData bloqueia até chegar algo: sem o poll, um claude mudo nunca respeitaria o prazo.
            var ready = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, Int32(max(0, deadline.timeIntervalSinceNow) * 1000)) > 0 else { return nil }
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      event["type"] as? String == "control_response",
                      let response = (event["response"] as? [String: Any])?["response"] as? [String: Any] else { continue }
                return response
            }
        }
        return nil
    }

    /// "2.1.312 (Claude Code)" → [2, 1, 312]
    private static func version(of path: String) -> [Int]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.environment = ShellEnvironment.variables
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let numbers = output.split(separator: " ").first?.split(separator: ".").compactMap { Int($0) } ?? []
        return numbers.isEmpty ? nil : numbers
    }
}

struct ModelOption: Codable, Hashable, Identifiable {
    /// O que vai em `--model` ("default", "opus", "claude-fable-5-1[1m]"…).
    let value: String
    /// Nome curto com a versão, ex.: "Opus 5.5".
    let name: String
    let detail: String
    let efforts: [String]

    var id: String { value }
}

/// Modelos que a conta oferece, lidos do próprio Claude Code (`initialize` do modo stream-json),
/// para o seletor do chat acompanhar modelos novos sem atualizar o MacPet.
@MainActor
final class ModelCatalog: ObservableObject {
    static let shared = ModelCatalog()
    private static let key = "chat.models"
    static let effortLevels = ["low", "medium", "high", "xhigh", "max"]

    @Published private(set) var models: [ModelOption]

    private init() {
        let cached = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([ModelOption].self, from: $0) }
        models = cached ?? ["default", "opus", "sonnet", "haiku"].map {
            ModelOption(value: $0, name: $0 == "default" ? "Modelo padrão" : $0.capitalized, detail: "", efforts: Self.effortLevels)
        }
    }

    func refresh() {
        Task {
            let fetched = await Task.detached(priority: .utility) { Self.fetch() }.value
            guard let fetched, !fetched.isEmpty else { return }
            models = fetched
            UserDefaults.standard.set(try? JSONEncoder().encode(fetched), forKey: Self.key)
        }
    }

    static func effortLabel(_ level: String) -> String {
        switch level {
        case "low": "Esforço baixo"
        case "medium": "Esforço médio"
        case "high": "Esforço alto"
        case "xhigh": "Esforço extra alto"
        case "max": "Esforço máximo"
        default: level
        }
    }

    nonisolated static func fetch() -> [ModelOption]? {
        guard let response = ClaudeCLI.initialize(in: FileManager.default.homeDirectoryForCurrentUser.path),
              let models = response["models"] as? [[String: Any]] else { return nil }
        // Aliases ("opus") primeiro; IDs completos que apontam para o mesmo modelo saem.
        var seen = Set<String>()
        return models.compactMap(option).filter { $0.option.value == "default" || seen.insert($0.resolved).inserted }.map(\.option)
    }

    /// {"value": "opus", "resolvedModel": "claude-opus-5-5", "description": "…", "supportedEffortLevels": [...]}
    private nonisolated static func option(_ model: [String: Any]) -> (option: ModelOption, resolved: String)? {
        guard let value = model["value"] as? String else { return nil }
        let resolved = model["resolvedModel"] as? String ?? value
        let name = displayName(resolved: resolved, fallback: model["displayName"] as? String ?? value)
        // A descrição às vezes começa com o nome ("Opus 5.5 · Best for…").
        var detail = model["description"] as? String ?? ""
        if let range = detail.range(of: " · ") { detail = String(detail[range.upperBound...]) }
        return (ModelOption(value: value, name: value == "default" ? "Padrão (\(name))" : name, detail: detail,
                            efforts: model["supportedEffortLevels"] as? [String] ?? []), resolved)
    }

    /// "claude-opus-5-5[1m]" → "Opus 5.5 · 1M"; "claude-haiku-4-5-20251001" → "Haiku 4.5".
    nonisolated static func displayName(resolved: String, fallback: String) -> String {
        let longContext = resolved.hasSuffix("[1m]")
        let parts = resolved.replacingOccurrences(of: "[1m]", with: "").split(separator: "-").map(String.init)
        guard parts.count >= 3, parts[0] == "claude" else { return fallback }
        let version = parts.dropFirst(2).filter { $0.count < 8 && Int($0) != nil }.joined(separator: ".")
        return parts[1].capitalized + (version.isEmpty ? "" : " \(version)") + (longContext ? " · 1M" : "")
    }
}
