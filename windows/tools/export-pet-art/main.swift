import Foundation
// Gera windows/shared/pet-art.json a partir do PetArt.swift do MacPet (a arte tem uma fonte só).
// Uso (na raiz do repositório): ./windows/tools/export-pet-art.sh
let fps: [String: Double] = ["sleeping": 1, "idle": 2, "working": 6, "waiting": 4, "celebrating": 6, "hot": 2, "tired": 1.5]
var palette: [String: String] = [:]
for (char, hex) in PetArt.palette { palette[String(char)] = String(format: "#%06X", hex) }
palette["z"] = "#ECEBF3"  // Zzz: no Mac é a cor do texto do sistema; o Cawde usa o tema escuro
let bar = PetArt.frames.mapValues { frames in frames }
let output: [String: Any] = [
    "width": PetArt.width, "height": PetArt.height, "palette": palette,
    "moods": Dictionary(uniqueKeysWithValues: bar.map { ($0.key, ["fps": fps[$0.key] ?? 2, "frames": $0.value]) }),
]
let data = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("pet-art.json: \(bar.count) humores, \(bar.values.map(\.count).reduce(0, +)) quadros")
