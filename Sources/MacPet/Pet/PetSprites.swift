import AppKit

enum PetMood: String {
    case sleeping, idle, working, waiting, celebrating, hot, tired

    var fps: Double {
        switch self {
        case .sleeping: 1
        case .idle: 2
        case .working: 6
        case .waiting: 4
        case .celebrating: 6
        case .hot: 2
        case .tired: 1.5
        }
    }

    var frames: [[String]] { PetArt.frames[rawValue] ?? [] }
}

/// Converte os quadros ASCII de `PetArt` em imagens.
enum PetSprites {
    static var width: Int { PetArt.width }
    static var height: Int { PetArt.height }

    static func color(_ char: Character) -> NSColor {
        if char == "z" { return .labelColor }
        let hex = PetArt.palette[char] ?? 0xFF00FF
        return NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Um pixel por célula; a camada amplia sem suavizar.
    static func cgImage(_ frame: [String], flipped: Bool = false) -> CGImage? {
        let width = frame.first?.count ?? PetArt.width, height = frame.count
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // y para baixo, como a grade; virado para a esquerda, espelha.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        if flipped {
            context.translateBy(x: CGFloat(width), y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        context.setShouldAntialias(false)
        for (row, line) in frame.enumerated() where row < height {
            for (col, char) in line.enumerated() where char != "." && col < width {
                guard let color = PetSprites.color(char).usingColorSpace(.sRGB) else { continue }
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: col, y: row, width: 1, height: 1))
            }
        }
        return context.makeImage()
    }

    /// Quadros de uma animação como imagens, guardados: a mesma animação devolve as mesmas imagens.
    @MainActor static func cgFrames(_ frames: [[String]]) -> [CGImage] {
        let key = frames.joined().joined()
        if let cached = frameCache[key] { return cached }
        let images = frames.compactMap { cgImage($0) }
        if frameCache.count > 64 { frameCache.removeAll() }
        frameCache[key] = images
        return images
    }
    @MainActor private static var frameCache: [String: [CGImage]] = [:]

    static func image(_ frame: [String], scale: CGFloat) -> NSImage {
        let size = NSSize(width: CGFloat(frame.first?.count ?? width) * scale, height: CGFloat(frame.count) * scale)
        return NSImage(size: size, flipped: true) { _ in
            for (row, line) in frame.enumerated() {
                for (col, char) in line.enumerated() where char != "." {
                    color(char).setFill()
                    NSRect(x: CGFloat(col) * scale, y: CGFloat(row) * scale, width: scale, height: scale).fill()
                }
            }
            return true
        }
    }
}
