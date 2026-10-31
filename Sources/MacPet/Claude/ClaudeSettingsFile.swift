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
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: backupURL)
            try FileManager.default.copyItem(at: url, to: backupURL)
        }
        change(&settings)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
