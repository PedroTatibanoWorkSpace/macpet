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
