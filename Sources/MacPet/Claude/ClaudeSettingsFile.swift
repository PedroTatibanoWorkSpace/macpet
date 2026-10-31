import Foundation

/// Leitura e escrita de ~/.claude/settings.json, sempre com backup antes de alterar.
enum ClaudeSettingsFile {
    static let url = MacPetPaths.home.appendingPathComponent(".claude/settings.json")
    static let backupURL = url.deletingLastPathComponent().appendingPathComponent("settings.json.macpet-backup")

    static func load() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    static func update(_ change: (inout [String: Any]) -> Void) throws {
        var settings = try load()
        // Com dotfiles (stow, chezmoi…) o settings.json é um symlink: escreve no arquivo de verdade, senão a
        // escrita atômica troca o link por um arquivo comum e ele deixa de acompanhar o repositório.
        let target = url.resolvingSymlinksInPath()
        var permissions: Any?
        if FileManager.default.fileExists(atPath: target.path) {
            // Backup do conteúdo (copiar o link guardaria só o link).
            let previous = try Data(contentsOf: target)
            try? FileManager.default.removeItem(at: backupURL)
            try previous.write(to: backupURL)
            permissions = try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
        }
        change(&settings)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        // A escrita atômica cria um arquivo novo: mantém as permissões que ele tinha.
        if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
    }
}
