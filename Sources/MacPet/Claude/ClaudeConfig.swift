import Foundation

struct MCPServerInfo: Identifiable, Hashable {
    let name: String
    let scope: String
    let detail: String
    var id: String { "\(scope)|\(name)" }
}

struct SkillInfo: Identifiable, Hashable {
    let name: String
    let description: String
    let path: String
    var id: String { path }
}

struct HookInfo: Identifiable, Hashable {
    let event: String
    let matcher: String?
    let command: String
    var id: String { "\(event)|\(matcher ?? "")|\(command)" }
    var isMacPet: Bool { command.contains("macpet-hook") }
}

/// Visão da configuração do Claude Code: settings.json, ~/.claude.json (MCPs), skills e CLAUDE.md global.
@MainActor
final class ClaudeConfig: ObservableObject {
    @Published private(set) var mcpServers: [MCPServerInfo] = []
    @Published private(set) var skills: [SkillInfo] = []
    @Published private(set) var hooks: [HookInfo] = []
    @Published private(set) var plugins: [(name: String, enabled: Bool)] = []
    @Published private(set) var model: String?
    @Published var allow: [String] = []
    @Published var deny: [String] = []
    @Published var claudeMd = ""
    @Published private(set) var lastError: String?

    static let claudeMdURL = MacPetPaths.home.appendingPathComponent(".claude/CLAUDE.md")
    private let globalConfigURL = MacPetPaths.home.appendingPathComponent(".claude.json")
    private let skillsURL = MacPetPaths.home.appendingPathComponent(".claude/skills")

    func reload() {
        let settings = (try? ClaudeSettingsFile.load()) ?? [:]
        model = settings["model"] as? String
        let permissions = settings["permissions"] as? [String: Any] ?? [:]
        allow = permissions["allow"] as? [String] ?? []
        deny = permissions["deny"] as? [String] ?? []
        plugins = (settings["enabledPlugins"] as? [String: Bool] ?? [:])
            .map { (name: $0.key, enabled: $0.value) }
            .sorted { $0.name < $1.name }

        var hookList: [HookInfo] = []
        for (event, value) in settings["hooks"] as? [String: Any] ?? [:] {
            for group in value as? [[String: Any]] ?? [] {
                for hook in group["hooks"] as? [[String: Any]] ?? [] {
                    hookList.append(HookInfo(event: event, matcher: group["matcher"] as? String, command: hook["command"] as? String ?? "?"))
                }
            }
        }
        hooks = hookList.sorted { ($0.event, $0.command) < ($1.event, $1.command) }

        mcpServers = loadMCPServers()
        skills = loadSkills()
        claudeMd = (try? String(contentsOf: Self.claudeMdURL, encoding: .utf8)) ?? ""
    }

    func savePermissions() {
        do {
            try ClaudeSettingsFile.update { settings in
                var permissions = settings["permissions"] as? [String: Any] ?? [:]
                permissions["allow"] = allow.isEmpty ? nil : allow
                permissions["deny"] = deny.isEmpty ? nil : deny
                settings["permissions"] = permissions.isEmpty ? nil : permissions
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setPlugin(_ name: String, enabled: Bool) {
        do {
            try ClaudeSettingsFile.update { settings in
                var plugins = settings["enabledPlugins"] as? [String: Bool] ?? [:]
                plugins[name] = enabled
                settings["enabledPlugins"] = plugins
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        reload()
    }

    func saveClaudeMd() {
        do {
            try claudeMd.write(to: Self.claudeMdURL, atomically: true, encoding: .utf8)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func loadMCPServers() -> [MCPServerInfo] {
        guard let data = try? Data(contentsOf: globalConfigURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var result = Self.servers(json["mcpServers"], scope: "Global")
        for (path, value) in json["projects"] as? [String: Any] ?? [:] {
            let project = value as? [String: Any]
            let name = URL(fileURLWithPath: path).lastPathComponent
            result += Self.servers(project?["mcpServers"], scope: "Projeto \(name)")
        }
        return result.sorted { ($0.scope, $0.name) < ($1.scope, $1.name) }
    }

    private static func servers(_ value: Any?, scope: String) -> [MCPServerInfo] {
        (value as? [String: Any] ?? [:]).map { name, config in
            let config = config as? [String: Any] ?? [:]
            // Nunca exibe env/headers: costumam ter tokens.
            let detail = (config["url"] as? String)
                ?? ([config["command"] as? String] + (config["args"] as? [String] ?? []).map(Optional.some))
                    .compactMap { $0 }.joined(separator: " ")
            return MCPServerInfo(name: name, scope: scope, detail: detail)
        }
    }

    private func loadSkills() -> [SkillInfo] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: skillsURL, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            let file = dir.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let description = text.split(separator: "\n")
                .first { $0.hasPrefix("description:") }
                .map { $0.dropFirst("description:".count).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            return SkillInfo(name: dir.lastPathComponent, description: description ?? "", path: file.path)
        }
        .sorted { $0.name < $1.name }
    }
}
