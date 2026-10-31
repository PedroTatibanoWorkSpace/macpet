import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Imagem anexada a uma mensagem (colada, arrastada ou escolhida), já no formato aceito pela API.
struct ChatImage: Identifiable, Equatable {
    let id = UUID()
    let data: Data
    let mediaType: String

    /// Compara só o id: as mensagens são comparadas a cada pedaço de texto que chega.
    static func == (lhs: ChatImage, rhs: ChatImage) -> Bool { lhs.id == rhs.id }

    var contentBlock: [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": data.base64EncodedString()]]
    }

    /// Bloco `image` de um transcript.
    init?(block: [String: Any]) {
        guard let source = block["source"] as? [String: Any], source["type"] as? String == "base64",
              let base64 = source["data"] as? String, let data = Data(base64Encoded: base64) else { return nil }
        self.data = data
        mediaType = source["media_type"] as? String ?? "image/png"
    }

    init(data: Data, mediaType: String) {
        self.data = data
        self.mediaType = mediaType
    }

    /// Abre no Preview (zoom, cópia) a partir de um arquivo temporário.
    func openInPreview() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macpet-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = mediaType.split(separator: "/").last.map(String.init) ?? "png"
        let file = folder.appendingPathComponent("\(id.uuidString).\(ext == "jpeg" ? "jpg" : ext)")
        if (try? data.write(to: file)) != nil { NSWorkspace.shared.open(file) }
    }
}

/// Converte qualquer imagem para PNG/JPEG dentro dos limites da API (lado ≤ 2000px, ≤ 3,5MB).
enum ChatImageEncoder {
    private static let maxSide = 2000
    private static let maxBytes = 3_500_000
    private static let passthrough: [String: String] = [
        UTType.png.identifier: "image/png", UTType.jpeg.identifier: "image/jpeg",
        UTType.gif.identifier: "image/gif", UTType.webP.identifier: "image/webp",
    ]

    static func make(data: Data) -> ChatImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        if let type = CGImageSourceGetType(source) as String?, let mediaType = passthrough[type],
           max(width, height) <= maxSide, data.count <= maxBytes {
            return ChatImage(data: data, mediaType: mediaType)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxSide, max(width, height, 1)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if let png = encode(image, as: .png), png.count <= maxBytes { return ChatImage(data: png, mediaType: "image/png") }
        guard let jpeg = encode(image, as: .jpeg, quality: 0.85) else { return nil }
        return ChatImage(data: jpeg, mediaType: "image/jpeg")
    }

    static func make(file: URL) -> ChatImage? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return make(data: data)
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

enum PasteboardImages {
    /// Imagens no clipboard: arquivos de imagem copiados no Finder ou a imagem em si (print, navegador, Slack).
    /// Texto com imagem junto (ex.: célula de planilha) continua sendo colado como texto.
    static func read(_ pasteboard: NSPasteboard = .general) -> [ChatImage] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let imageFiles = urls.filter(ChatImageEncoder.isImage)
        if !imageFiles.isEmpty { return imageFiles.compactMap(ChatImageEncoder.make(file:)) }
        guard urls.isEmpty, pasteboard.string(forType: .string) == nil else { return [] }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let image = ChatImageEncoder.make(data: data) { return [image] }
        }
        return []
    }
}

/// Arquivos do projeto para o autocompletar de `@`.
enum ProjectFileIndex {
    private static let limit = 50_000

    /// Arquivos versionados e não ignorados (respeita o .gitignore), mais as pastas que os contêm.
    static func load(_ root: String) async -> [String] {
        let result = await Shell.run("/usr/bin/git", ["ls-files", "--cached", "--others", "--exclude-standard"], in: root)
        var files = result.ok ? result.stdout.split(separator: "\n").map(String.init) : []
        if files.count > limit { files = Array(files.prefix(limit)) }
        var folders = Set<String>()
        for file in files {
            var parent = (file as NSString).deletingLastPathComponent
            while !parent.isEmpty, folders.insert(parent + "/").inserted {
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return files + folders.sorted()
    }

    static func matches(_ query: String, in paths: [String], limit: Int = 8) -> [String] {
        guard !query.isEmpty else { return Array(paths.prefix(limit)) }
        let needle = query.lowercased()
        var scored: [(score: Int, path: String)] = []
        for path in paths {
            let lower = path.lowercased()
            let name = (lower.hasSuffix("/") ? String(lower.dropLast()) : lower).split(separator: "/").last.map(String.init) ?? lower
            let score: Int
            if name.hasPrefix(needle) { score = 0 }
            else if name.contains(needle) { score = 1 }
            else if lower.contains(needle) { score = 2 }
            else if isSubsequence(needle, of: lower) { score = 3 }
            else { continue }
            scored.append((score, path))
        }
        return scored.sorted { $0.score != $1.score ? $0.score < $1.score : $0.path.count < $1.path.count }
            .prefix(limit).map(\.path)
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = needle[...]
        for character in haystack where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}

/// Comandos `/` do Claude Code. A lista real vem no `init` de cada conversa e fica guardada para a próxima.
enum SlashCommands {
    private static let key = "chat.slashCommands"
    private static let common = ["compact", "context", "clear", "review", "code-review", "init", "usage", "model"]
    private static let descriptions: [String: String] = [
        "compact": "Resume a conversa para liberar contexto",
        "context": "Mostra quanto do contexto está em uso",
        "clear": "Começa uma conversa nova",
        "review": "Revisa um pull request",
        "code-review": "Revisa as mudanças atuais",
        "security-review": "Revisão de segurança das mudanças",
        "init": "Cria ou atualiza o CLAUDE.md do projeto",
        "usage": "Uso do plano",
        "model": "Troca o modelo",
        "simplify": "Simplifica o código alterado",
        "recap": "Resumo do que foi feito",
        "debug": "Ajuda a depurar um problema",
    ]

    static var cached: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? common }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func description(_ name: String) -> String? {
        descriptions[name] ?? (name.contains(":") ? "skill de \(name.split(separator: ":")[0])" : nil)
    }

    static func matches(_ query: String, in commands: [String], limit: Int = 8) -> [String] {
        let needle = query.lowercased()
        let ranked = commands.filter { !$0.hasPrefix("_") }.sorted { lhs, rhs in
            let l = common.firstIndex(of: lhs) ?? Int.max, r = common.firstIndex(of: rhs) ?? Int.max
            return l != r ? l < r : lhs < rhs
        }
        guard !needle.isEmpty else { return Array(ranked.prefix(limit)) }
        let prefix = ranked.filter { $0.lowercased().hasPrefix(needle) || $0.lowercased().split(separator: ":").last?.hasPrefix(needle) == true }
        let contains = ranked.filter { $0.lowercased().contains(needle) && !prefix.contains($0) }
        return Array((prefix + contains).prefix(limit))
    }
}
