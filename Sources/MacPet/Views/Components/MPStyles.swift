import SwiftUI

// Estilos do design system "MacPet" aplicados na raiz das janelas: todo Button, Toggle, TextField e
// ProgressView sem estilo próprio passa a ser desenhado pelo app, não pelo sistema.

// MARK: - Button

/// primary: a única ação principal da tela · secondary: o resto · ghost: ações dentro de cards e listas ·
/// danger: destrutivas (confirme com um MPDialog antes).
struct MPButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, ghost, danger }
    enum Size { case sm, md }

    var variant: Variant = .secondary
    var size: Size = .md

    func makeBody(configuration: Configuration) -> some View {
        MPButtonBody(configuration: configuration, variant: variant, declaredSize: size)
    }
}

private struct MPButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let variant: MPButtonStyle.Variant
    let declaredSize: MPButtonStyle.Size
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var controlSize
    @State private var hovering = false

    /// `.controlSize(.small)` (usado nas barras e cards) vira o tamanho sm.
    private var size: MPButtonStyle.Size { controlSize == .small || controlSize == .mini ? .sm : declaredSize }

    var body: some View {
        let radius = size == .sm ? Theme.Radius.sm : Theme.Radius.md
        configuration.label
            .font(.system(size: size == .sm ? 12 : 13, weight: .semibold))
            .lineLimit(1)
            .fixedSize()  // rótulo de botão nunca é cortado
            .foregroundStyle(foreground)
            .padding(.horizontal, size == .sm ? 8 : 12)
            .frame(height: size == .sm ? 24 : 30)
            .background(background, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(border))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(enabled ? 1 : 0.45)
            .onHover { hovering = $0 && enabled }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var foreground: AnyShapeStyle {
        switch variant {
        case .primary: AnyShapeStyle(Theme.onSheen)
        case .secondary: AnyShapeStyle(Theme.text)
        case .ghost: AnyShapeStyle(Theme.sheen)
        case .danger: AnyShapeStyle(Theme.danger)
        }
    }

    private var background: AnyShapeStyle {
        switch variant {
        case .primary: AnyShapeStyle(Theme.sheenStrong.opacity(hovering ? 0.9 : 1))
        case .secondary: AnyShapeStyle(hovering ? AnyShapeStyle(Theme.plumageRaised) : AnyShapeStyle(Theme.plumage))
        case .ghost: AnyShapeStyle(hovering ? Theme.sheenSoft : Color.clear)
        case .danger: AnyShapeStyle(hovering ? AnyShapeStyle(Theme.plumageRaised) : AnyShapeStyle(Color.clear))
        }
    }

    private var border: AnyShapeStyle {
        switch variant {
        case .primary, .ghost: AnyShapeStyle(Color.clear)
        case .secondary, .danger: AnyShapeStyle(Theme.quill)
        }
    }
}

extension ButtonStyle where Self == MPButtonStyle {
    static func mp(_ variant: MPButtonStyle.Variant = .secondary, size: MPButtonStyle.Size = .md) -> MPButtonStyle {
        MPButtonStyle(variant: variant, size: size)
    }
}

// MARK: - Toggle

/// Liga/desliga que vale na hora (preferências, plugins, MCP).
struct MPSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: 8) {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? AnyShapeStyle(Theme.sheenStrong) : AnyShapeStyle(Theme.plumageRaised))
                        .overlay(Capsule().strokeBorder(configuration.isOn ? AnyShapeStyle(Theme.sheenStrong) : AnyShapeStyle(Theme.quillStrong)))
                        .frame(width: 30, height: 18)
                    Circle()
                        .fill(configuration.isOn ? AnyShapeStyle(Theme.onSheen) : AnyShapeStyle(Theme.textMuted))
                        .frame(width: 12, height: 12)
                        .padding(3)
                }
                configuration.label.foregroundStyle(Theme.text)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "ligado" : "desligado")
    }
}

/// Escolher itens de uma lista (tarefas a lançar, arquivos).
struct MPCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
                    .fill(configuration.isOn ? AnyShapeStyle(Theme.sheenStrong) : AnyShapeStyle(Theme.plumage))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
                        .strokeBorder(configuration.isOn ? AnyShapeStyle(Theme.sheenStrong) : AnyShapeStyle(Theme.quillStrong)))
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.onSheen)
                        }
                    }
                    .frame(width: 16, height: 16)
                configuration.label.foregroundStyle(Theme.text)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
    }
}

extension ToggleStyle where Self == MPSwitchStyle { static var mpSwitch: MPSwitchStyle { MPSwitchStyle() } }
extension ToggleStyle where Self == MPCheckboxStyle { static var mpCheckbox: MPCheckboxStyle { MPCheckboxStyle() } }

// MARK: - TextField

/// Campo afundado (ink) com borda de controle; o foco ganha borda e halo no brilho da pena.
struct MPTextFieldStyle: TextFieldStyle {
    var mono = false

    func _body(configuration: TextField<Self._Label>) -> some View {
        MPFieldChrome(mono: mono) { configuration }
    }
}

extension TextFieldStyle where Self == MPTextFieldStyle {
    static var mp: MPTextFieldStyle { MPTextFieldStyle() }
    static var mpMono: MPTextFieldStyle { MPTextFieldStyle(mono: true) }
}

/// Moldura comum a campos de uma linha e de várias linhas.
struct MPFieldChrome<Content: View>: View {
    var mono = false
    var verticalPadding: CGFloat = 6
    @ViewBuilder let content: () -> Content
    @FocusState private var focused: Bool

    var body: some View {
        content()
            .textFieldStyle(.plain)
            .font(mono ? Theme.mono(12) : .system(size: 13))
            .foregroundStyle(Theme.text)
            .focused($focused)
            .padding(.horizontal, 10)
            .padding(.vertical, verticalPadding)
            .background(Theme.ink, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(focused ? AnyShapeStyle(Theme.sheen) : AnyShapeStyle(Theme.quillStrong)))
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md + 3, style: .continuous)
                .fill(focused ? Theme.sheenSoft : .clear).padding(-3))
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

// MARK: - ProgressView

/// Indeterminado: três pontos pulsando no brilho da pena (com o rótulo ao lado). Determinado: barra fina.
struct MPProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        if let fraction = configuration.fractionCompleted {
            VStack(alignment: .leading, spacing: 4) {
                configuration.label.font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.plumageRaised)
                        Capsule().fill(Theme.sheen).frame(width: max(4, proxy.size.width * fraction))
                    }
                }
                .frame(height: 6)
            }
        } else {
            HStack(spacing: 8) {
                MPLoaderDots()
                configuration.label.font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
        }
    }
}

extension ProgressViewStyle where Self == MPProgressStyle { static var mp: MPProgressStyle { MPProgressStyle() } }

struct MPLoaderDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle().fill(Theme.sheen)
                        .frame(width: 6, height: 6)
                        .opacity(reduceMotion ? 0.8 : 0.35 + 0.65 * (0.5 + 0.5 * sin((t - Double(index) * 0.2) * .pi / 0.6)))
                }
            }
        }
        .accessibilityLabel("Carregando")
    }
}

// MARK: - Raiz

extension View {
    /// Aplica o design system a tudo dentro: botões, interruptores, campos, progresso e cor de destaque.
    func mpDesignSystem() -> some View {
        self
            .buttonStyle(.mp())
            .toggleStyle(.mpSwitch)
            .textFieldStyle(.mp)
            .progressViewStyle(.mp)
            .tint(Theme.sheen)
            .foregroundStyle(Theme.text)
    }
}
