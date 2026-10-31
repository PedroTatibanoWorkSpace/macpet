import Foundation

/// Instala/remove a integração do MacPet em ~/.claude/settings.json, preservando o que já existe:
/// os hooks de eventos e a statusLine (que traz os limites do plano e o uso de contexto).
@MainActor
final class HookInstaller: ObservableObject {
    @Published private(set) var installed = false
    @Published private(set) var statusLineInstalled = false
    /// Já existe uma statusLine de outra ferramenta; não sobrescrevemos sem o usuário pedir.
    @Published private(set) var statusLineTaken = false
    @Published private(set) var lastError: String?

    static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PostToolUse", "Notification", "Stop"]

    /// Se o MacPet for desinstalado o hook vira no-op em vez de quebrar o Claude Code.
    static let command = #"[ -x "$HOME/.macpet/bin/macpet-hook" ] && "$HOME/.macpet/bin/macpet-hook" || true"#
    static let statusLineCommand = #""$HOME/.macpet/bin/macpet-hook" statusline 2>/dev/null || true"#

    init() {
        refresh()
    }

    /// Mantém ~/.macpet/bin/macpet-hook apontando para o binário dentro do .app atual.
    func linkBinary() {
        guard let binary = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("macpet-hook"),
              FileManager.default.isExecutableFile(atPath: binary.path) else { return }
        let link = MacPetPaths.hookLink
        try? FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == binary.path { return }
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
    }

    func refresh() {
        let settings = (try? ClaudeSettingsFile.load()) ?? [:]
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        installed = Self.events.allSatisfy { event in
            (hooks[event] as? [[String: Any]])?.contains(where: Self.isOurs) ?? false
        }
        let statusLine = settings["statusLine"] as? [String: Any]
        statusLineInstalled = Self.isOurStatusLine(statusLine)
        statusLineTaken = statusLine != nil && !statusLineInstalled
    }

    /// Instala hooks e, se não houver outra statusLine, a do MacPet. `replaceStatusLine` força a troca.
    func install(replaceStatusLine: Bool = false) {
        update { settings in
            var hooks = settings["hooks"] as? [String: Any] ?? [:]
            for event in Self.events {
                var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !Self.isOurs($0) }
                var group: [String: Any] = ["hooks": [["type": "command", "command": Self.command, "timeout": 5]]]
                if event == "PostToolUse" {
                    group["matcher"] = "*"
                }
                groups.append(group)
                hooks[event] = groups
            }
            settings["hooks"] = hooks
            if settings["statusLine"] == nil || replaceStatusLine || Self.isOurStatusLine(settings["statusLine"] as? [String: Any]) {
                settings["statusLine"] = ["type": "command", "command": Self.statusLineCommand, "padding": 0]
            }
        }
    }

    func uninstall() {
        update { settings in
            var hooks = settings["hooks"] as? [String: Any] ?? [:]
            for (event, value) in hooks {
                guard let groups = value as? [[String: Any]] else { continue }
                let remaining = groups.filter { !Self.isOurs($0) }
                hooks[event] = remaining.isEmpty ? nil : remaining
            }
            settings["hooks"] = hooks.isEmpty ? nil : hooks
            if Self.isOurStatusLine(settings["statusLine"] as? [String: Any]) {
                settings["statusLine"] = nil
            }
        }
    }

    private func update(_ change: (inout [String: Any]) -> Void) {
        do {
            try ClaudeSettingsFile.update(change)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("macpet-hook") ?? false } ?? false
    }

    private static func isOurStatusLine(_ statusLine: [String: Any]?) -> Bool {
        (statusLine?["command"] as? String)?.contains("macpet-hook") ?? false
    }
}
