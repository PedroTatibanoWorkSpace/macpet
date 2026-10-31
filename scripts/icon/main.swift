// Gera o AppIcon.icns a partir do quadro "idle" de PetArt.
// Compilado junto com Sources/MacPet/Pet/PetArt.swift pelo build-app.sh.
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let frame = PetArt.frames["idle"]![4]
let background = NSColor(srgbRed: 0.10, green: 0.08, blue: 0.16, alpha: 1)

func color(_ char: Character) -> NSColor {
    let hex = char == "z" ? 0xFFFFFF : PetArt.palette[char]!
    return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                   blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    // Margem padrão dos ícones do macOS (~10%) e cantos arredondados.
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    background.setFill()
    NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225).fill()

    let pixel = max(1, floor(tile.width * 0.86 / CGFloat(PetArt.width)))
    let originX = tile.midX - pixel * CGFloat(PetArt.width) / 2
    let originY = tile.midY + pixel * CGFloat(PetArt.height) / 2
    for (row, line) in frame.enumerated() {
        for (col, char) in line.enumerated() where char != "." {
            color(char).setFill()
            NSRect(x: originX + CGFloat(col) * pixel, y: originY - CGFloat(row + 1) * pixel, width: pixel, height: pixel).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacPet-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output]
try process.run()
process.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(output)
