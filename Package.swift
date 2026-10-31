// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacPet",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Emulador de terminal para a aba de comandos/servidores de cada projeto.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        // Leitura dos sensores de temperatura do Apple Silicon (API privada do IOHID).
        .target(
            name: "CSensors",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(
            name: "MacPet",
            dependencies: ["CSensors", .product(name: "SwiftTerm", package: "SwiftTerm")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // CLI chamado pelos hooks do Claude Code; repassa o evento para o app via socket.
        .executableTarget(name: "macpet-hook"),
    ],
    swiftLanguageModes: [.v5]
)
