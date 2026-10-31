// Gera o ícone do Cawde (PNG 1024 px) com o mesmo corvo do MacPet; o `tauri icon` deriva o .ico e os demais.
// Uso (na raiz do repositório): ./windows/tools/app-icon.sh
import AppKit

let frame = PetArt.frames["idle"]![4]
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let s = CGFloat(size)
// No Windows o ícone ocupa quase todo o quadro; cantos arredondados no estilo do Windows 11.
let tile = NSRect(x: s * 0.04, y: s * 0.04, width: s * 0.92, height: s * 0.92)
NSColor(srgbRed: 0x12 / 255, green: 0x13 / 255, blue: 0x19 / 255, alpha: 1).setFill()
NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.18, yRadius: tile.width * 0.18).fill()
let pixel = floor(tile.width * 0.88 / CGFloat(PetArt.width))
let originX = tile.midX - pixel * CGFloat(PetArt.width) / 2
let originY = tile.midY + pixel * CGFloat(PetArt.height) / 2
for (row, line) in frame.enumerated() {
    for (col, char) in line.enumerated() where char != "." {
        let hex = PetArt.palette[char] ?? 0xFFFFFF
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1).setFill()
        NSRect(x: originX + CGFloat(col) * pixel, y: originY - CGFloat(row + 1) * pixel, width: pixel, height: pixel).fill()
    }
}
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
