import AppKit
import SwiftUI

/// Identidade visual do MacPet: "corvo à noite".
/// Tinta azulada no fundo, plumagem nas superfícies, o brilho furta-cor da pena (violeta → ciano)
/// só onde algo acontece, e âmbar de abóbora para o que espera você.
enum Theme {
    // Tokens do design system "MacPet" (Claude Design): mesmos nomes e valores do tokens.json.
    static let ink = AdaptiveColor(dark: 0x121319, light: 0xF5F5F8)
    static let plumage = AdaptiveColor(dark: 0x1A1B23, light: 0xFFFFFF)
    static let plumageRaised = AdaptiveColor(dark: 0x22232D, light: 0xEEEEF3)
    static let quill = AdaptiveColor(dark: 0x2C2E3A, light: 0xDEDEE6)
    /// Borda de controle (inputs, checkbox, trilho do switch): 3:1 sobre plumage.
    static let quillStrong = AdaptiveColor(dark: 0x6A6D82, light: 0x878899)
    static let text = AdaptiveColor(dark: 0xECEBF3, light: 0x17181F)
    static let textMuted = AdaptiveColor(dark: 0xA6A7B9, light: 0x55566A)
    static let textFaint = AdaptiveColor(dark: 0x8B8CA0, light: 0x6B6C80)
    /// Acento como texto, ícone e marca de foco.
    static let sheen = Color(hex: 0x9A8BFF)
    /// Preenchimento da única ação principal da tela (texto `onSheen`, 4,9:1).
    static let sheenStrong = Color(hex: 0x6A55E8)
    static let sheenTeal = Color(hex: 0x39C2C9)
    static let sheenSoft = Color(hex: 0x8C7BFF).opacity(0.15)
    static let onSheen = Color.white
    static let focus = AdaptiveColor(dark: 0xB3A8FF, light: 0x4A35C9)
    /// Espera por você: permissão, pico, parar.
    static let ember = Color(hex: 0xF0A04B)
    static let emberSoft = Color(hex: 0xF0A04B).opacity(0.14)
    static let onEmber = AdaptiveColor(dark: 0x1A1206, light: 0xFFFFFF)
    static let success = AdaptiveColor(dark: 0x5CCF95, light: 0x1D7A4C)
    static let danger = AdaptiveColor(dark: 0xFF7B72, light: 0xC4302B)
    static let diffAdd = Color(hex: 0x2EA043).opacity(0.18)
    static let diffRemove = Color(hex: 0xF85149).opacity(0.18)

    /// O brilho da pena de corvo. Usado com parcimônia: enviar e "trabalhando".
    static let iridescent = LinearGradient(colors: [sheenStrong, sheenTeal], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Raios do design system (cantos contínuos).
    enum Radius {
        static let xs: CGFloat = 5, sm: CGFloat = 6, md: CGFloat = 8, lg: CGFloat = 10, xl: CGFloat = 12
        static let xl2: CGFloat = 14, xl3: CGFloat = 16, xl4: CGFloat = 20
    }

    /// Títulos em serifa (New York), com moderação.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Dados: caminhos, custos, durações, modelo, nomes de ferramentas.
    static func mono(_ size: CGFloat = 11, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Cor que segue o modo claro/escuro pelo ambiente do SwiftUI. (Um `NSColor` dinâmico resolvia
/// com a aparência do app, que para um app de barra de menus pode não ser a do sistema.)
struct AdaptiveColor: ShapeStyle {
    let dark: Color
    let light: Color

    init(dark: UInt32, light: UInt32) {
        self.dark = Color(hex: dark)
        self.light = Color(hex: light)
    }

    func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        (environment.colorScheme == .dark ? dark : light).resolve(in: environment)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Cor de cada projeto (barra lateral, cabeçalho e o seu balão no chat).
enum ProjectColor: String, CaseIterable, Identifiable {
    case violet, teal, ember, rose, sky, sage, sand, slate

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .violet: Color(red: 0.55, green: 0.48, blue: 1.0)
        case .teal: Color(red: 0.22, green: 0.76, blue: 0.79)
        case .ember: Color(red: 0.94, green: 0.63, blue: 0.29)
        case .rose: Color(red: 0.94, green: 0.42, blue: 0.61)
        case .sky: Color(red: 0.35, green: 0.66, blue: 0.94)
        case .sage: Color(red: 0.50, green: 0.75, blue: 0.50)
        case .sand: Color(red: 0.85, green: 0.70, blue: 0.43)
        case .slate: Color(red: 0.54, green: 0.58, blue: 0.65)
        }
    }

    var label: String {
        switch self {
        case .violet: "Violeta"
        case .teal: "Ciano"
        case .ember: "Abóbora"
        case .rose: "Rosa"
        case .sky: "Céu"
        case .sage: "Sálvia"
        case .sand: "Areia"
        case .slate: "Ardósia"
        }
    }

    /// Sem escolha: deriva do nome, para cada projeto já nascer com uma cor estável.
    static func `for`(_ project: Project) -> ProjectColor {
        if let raw = project.color, let color = ProjectColor(rawValue: raw) { return color }
        let hash = project.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return allCases[hash % allCases.count]
    }
}

/// Quadradinho com a inicial do projeto, na cor dele.
struct ProjectMonogram: View {
    let project: Project
    var size: CGFloat = 20

    var body: some View {
        let tint = ProjectColor.for(project).color
        Text(String(project.name.prefix(1)).uppercased())
            .font(Theme.display(size * 0.6, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

/// O corvo do menu bar, animado, dentro do app.
struct CrowView: View {
    let mood: PetMood
    var scale: CGFloat = 4

    var body: some View {
        // Core Animation, não TimelineView: trocar o quadro não refaz o layout da janela (ver MPSpriteAnimation).
        MPSpriteAnimation(frames: PetSprites.cgFrames(mood.frames), fps: mood.fps)
            .frame(width: CGFloat(PetSprites.width) * scale, height: CGFloat(PetSprites.height) * scale)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Vidro (macOS 26) ou material translúcido nas versões anteriores.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

/// Sons de notificação disponíveis (do sistema e os seus em ~/Library/Sounds).
enum NotificationSounds {
    static var all: [String] {
        let folders = ["/System/Library/Sounds", FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Sounds"]
        let names = folders.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
            .map { ($0 as NSString).deletingPathExtension }
        return Array(Set(names)).sorted()
    }

    static func play(_ name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }
}
