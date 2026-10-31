import SwiftUI

// Componentes do design system "MacPet" (https://claude.ai/artifact/5icy3KVaXCEvTV5YB4RGa4).
// Cada um corresponde a um componente de mesmo nome lá, com os mesmos tokens.

// MARK: - IconButton

/// Ação só com ícone; `label` vira a dica e o nome acessível. `glass` para a barra da janela.
struct MPIconButton: View {
    let icon: String
    let label: String
    var glass = false
    var tint: Color?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? (hovering ? AnyShapeStyle(Theme.text) : AnyShapeStyle(Theme.textMuted)))
                .frame(width: 28, height: 28)
                .background(background, in: glass ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)))
                .overlay { if glass { Capsule().strokeBorder(Theme.quill) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }

    private var background: AnyShapeStyle {
        if glass { return AnyShapeStyle(hovering ? AnyShapeStyle(Theme.plumageRaised) : AnyShapeStyle(Theme.plumage)) }
        return hovering ? AnyShapeStyle(Theme.plumageRaised) : AnyShapeStyle(Color.clear)
    }
}

// MARK: - Tabs

/// Abas em pílula; a selecionada ganha fundo e um sublinhado no brilho da pena. Contagem opcional.
struct MPTabs<Value: Hashable>: View {
    struct Item {
        let value: Value
        let label: String
        var count: Int = 0
        var waiting = false
    }

    let items: [Item]
    @Binding var selection: Value
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                let selected = item.value == selection
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { selection = item.value }
                } label: {
                    HStack(spacing: 5) {
                        Text(item.label)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Theme.text : Theme.textMuted)
                        if item.count > 0 {
                            Text("\(item.count)")
                                .font(Theme.mono(10))
                                .foregroundStyle(item.waiting ? Theme.ember : Theme.sheen)
                                .padding(.horizontal, 5)
                                .background(item.waiting ? Theme.emberSoft : Theme.sheenSoft, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background {
                        if selected {
                            Capsule().fill(Theme.plumageRaised)
                                .overlay(alignment: .bottom) {
                                    Capsule().fill(Theme.sheen).frame(height: 2).padding(.horizontal, 10)
                                }
                                .matchedGeometryEffect(id: "tab", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.plumage, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.quill))
    }
}

// MARK: - Stepper

struct MPStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var suffix = ""

    var body: some View {
        HStack(spacing: 0) {
            step("−") { value = max(range.lowerBound, value - 1) }
            Text("\(value)\(suffix)")
                .font(Theme.mono(12))
                .frame(minWidth: 54)
                .frame(height: 26)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.quill).frame(width: 1) }
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.quill).frame(width: 1) }
            step("+") { value = min(range.upperBound, value + 1) }
        }
        .background(Theme.plumage, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.quillStrong))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    }

    private func step(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol).frame(width: 26, height: 26).foregroundStyle(Theme.textMuted).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Campos com rótulo

/// Rótulo em cima, campo, dica ou erro embaixo.
struct MPField<Content: View>: View {
    let label: String?
    var hint: String?
    var error: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label { MPSectionLabel(label) }
            content()
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.danger)
            } else if let hint {
                Text(hint).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
            }
        }
    }
}

/// Várias linhas (mensagem de commit, primeiro pedido, instruções de skill), com placeholder alinhado.
struct MPTextArea: View {
    @Binding var text: String
    var placeholder = ""
    var mono = false
    var height: CGFloat = 80

    var body: some View {
        MPFieldChrome(mono: mono, verticalPadding: 8) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty, !placeholder.isEmpty {
                    Text(placeholder).foregroundStyle(Theme.textFaint).padding(.leading, 5).allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .frame(height: height)
            }
        }
    }
}

/// Rótulo de seção (sidebars, formulários).
struct MPSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).tracking(0.2).foregroundStyle(Theme.textMuted)
    }
}

// MARK: - Status

struct MPBadge: View {
    enum Tone { case neutral, sheen, ember, success, danger }
    let text: String
    var tone: Tone = .neutral
    var icon: String?
    var mono = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(text)
        }
        .font(mono ? Theme.mono(10) : .system(size: 11, weight: .semibold))
        .foregroundStyle(foreground)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
    }

    private var foreground: AnyShapeStyle {
        switch tone {
        case .neutral: AnyShapeStyle(Theme.textMuted)
        case .sheen: AnyShapeStyle(Theme.sheen)
        case .ember: AnyShapeStyle(Theme.ember)
        case .success: AnyShapeStyle(Theme.success)
        case .danger: AnyShapeStyle(Theme.danger)
        }
    }

    private var background: AnyShapeStyle {
        switch tone {
        case .sheen: AnyShapeStyle(Theme.sheenSoft)
        case .ember: AnyShapeStyle(Theme.emberSoft)
        default: AnyShapeStyle(Theme.plumageRaised)
        }
    }
}

/// Ponto + palavra para o estado vivo de um agente ou servidor.
struct MPStatusDot: View {
    enum Status { case working, waiting, ok, error, idle }
    let status: Status
    var label: String?
    var showsLabel = true

    var body: some View {
        HStack(spacing: 6) {
            Group {
                switch status {
                case .working: MPPulse { Circle().fill(Theme.iridescent) }
                case .waiting: Circle().fill(Theme.ember)
                case .ok: Circle().fill(Theme.success)
                case .error: Circle().fill(Theme.danger)
                case .idle: Circle().fill(Theme.textFaint)
                }
            }
            .frame(width: 8, height: 8)
            if showsLabel {
                Text(label ?? defaultLabel).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
        }
        .help(label ?? defaultLabel)
    }

    private var defaultLabel: String {
        switch status {
        case .working: "trabalhando"
        case .waiting: "esperando você"
        case .ok: "conectado"
        case .error: "falhou"
        case .idle: "parado"
        }
    }
}

/// Limite do plano: rótulo, porcentagem, barra e quando reinicia. ≥70% âmbar, ≥90% perigo.
struct MPMeter: View {
    let label: String
    let value: Double?
    var foot: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let value {
                    Text("\(Int(value.rounded()))%")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(color(value))
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.plumageRaised)
                    if let value {
                        Capsule().fill(color(value)).frame(width: max(6, proxy.size.width * min(value, 100) / 100))
                    }
                }
            }
            .frame(height: 6)
            Text(foot).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.plumage, in: RoundedRectangle(cornerRadius: Theme.Radius.xl2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xl2, style: .continuous).strokeBorder(Theme.quill))
    }

    private func color(_ value: Double) -> AnyShapeStyle {
        value >= 90 ? AnyShapeStyle(Theme.danger) : value >= 70 ? AnyShapeStyle(Theme.ember) : AnyShapeStyle(Theme.success)
    }
}

/// Aviso de largura total acima de uma seção.
struct MPBanner: View {
    enum Tone { case peak, info, danger }
    let tone: Tone
    let title: String
    var message: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(iconColor).font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let message { Text(message).font(.system(size: 12)).foregroundStyle(Theme.textMuted) }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tone == .peak ? AnyShapeStyle(Theme.emberSoft) : AnyShapeStyle(Theme.plumage),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.xl2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xl2, style: .continuous)
            .strokeBorder(tone == .peak ? AnyShapeStyle(Theme.ember.opacity(0.55)) : AnyShapeStyle(Theme.quill)))
    }

    private var icon: String {
        switch tone {
        case .peak: "flame.fill"
        case .info: "info.circle"
        case .danger: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: AnyShapeStyle {
        switch tone {
        case .peak: AnyShapeStyle(Theme.ember)
        case .info: AnyShapeStyle(Theme.sheen)
        case .danger: AnyShapeStyle(Theme.danger)
        }
    }
}

/// Tela vazia: figura opcional, pergunta em serifa, uma frase e atalhos.
struct MPEmptyState<Figure: View>: View {
    let title: String
    var message: String?
    var hints: [(String, String)] = []
    @ViewBuilder var figure: () -> Figure

    var body: some View {
        VStack(spacing: 12) {
            figure()
            Text(title).font(Theme.display(22)).multilineTextAlignment(.center)
            if let message {
                Text(message).foregroundStyle(Theme.textMuted).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            if !hints.isEmpty {
                HStack(spacing: 16) {
                    ForEach(hints, id: \.0) { key, text in
                        HStack(spacing: 6) {
                            Text(key).font(Theme.mono(11, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.plumageRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.xs))
                                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xs).strokeBorder(Theme.quill))
                            Text(text).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension MPEmptyState where Figure == EmptyView {
    init(title: String, message: String? = nil, hints: [(String, String)] = []) {
        self.init(title: title, message: message, hints: hints) { EmptyView() }
    }
}

/// Ícone grande e discreto para telas vazias que não são do corvo.
struct MPEmptyIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName).font(.system(size: 30, weight: .light)).foregroundStyle(Theme.textFaint)
    }
}

// MARK: - Listas

/// Uma linha selecionável de lista: título, subtítulo, meta à direita, item à esquerda.
struct MPListRow<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    var meta: String?
    var selected = false
    var titleLines = 1
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            leading()
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).lineLimit(titleLines).foregroundStyle(Theme.text)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let meta { Text(meta).font(Theme.mono(11)).foregroundStyle(Theme.textMuted) }
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? AnyShapeStyle(Theme.sheenSoft) : hovering ? AnyShapeStyle(Theme.plumageRaised) : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

extension MPListRow where Leading == EmptyView, Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, meta: String? = nil, selected: Bool = false, titleLines: Int = 1) {
        self.init(title: title, subtitle: subtitle, meta: meta, selected: selected, titleLines: titleLines,
                  leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

extension MPListRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, meta: String? = nil, selected: Bool = false, titleLines: Int = 1,
         @ViewBuilder leading: @escaping () -> Leading) {
        self.init(title: title, subtitle: subtitle, meta: meta, selected: selected, titleLines: titleLines,
                  leading: leading, trailing: { EmptyView() })
    }
}

/// Lista selecionável desenhada pelo app (no lugar de List): rola, destaca a seleção e agrupa por seção.
struct MPList<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                content()
            }
            .padding(6)
        }
        .background(Theme.plumage)
    }
}

/// Cabeçalho de grupo dentro de um MPList.
struct MPListSection: View {
    let title: String
    var trailing: AnyView?

    init(_ title: String, trailing: AnyView? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            MPSectionLabel(title)
            Spacer()
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

// MARK: - SidebarItem

/// Linha da barra lateral: hover em plumage-raised; selecionada ganha também uma borda de 2pt no brilho da pena.
struct MPSidebarItem<Content: View>: View {
    var selected = false
    var indent: CGFloat = 0
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) { content() }
                .padding(.leading, 8 + indent)
                .padding(.trailing, 8)
                .frame(height: 30)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected || hovering ? AnyShapeStyle(Theme.plumageRaised) : AnyShapeStyle(Color.clear),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .overlay(alignment: .leading) {
                    if selected { Capsule().fill(Theme.sheen).frame(width: 2.5, height: 16).padding(.leading, 1) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Divisória e superfície de diálogo

/// Linha fina no tom das bordas (no lugar do Divider do sistema).
struct MPDivider: View {
    var body: some View { Rectangle().fill(Theme.quill).frame(height: 1) }
}

extension View {
    /// Moldura de diálogo para conteúdo próprio aberto com `mpSheet`.
    func mpDialogSurface(width: CGFloat? = nil) -> some View {
        self
            .padding(24)
            .frame(width: width, alignment: .leading)
            .background(Theme.plumage, in: RoundedRectangle(cornerRadius: Theme.Radius.xl2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xl2, style: .continuous).strokeBorder(Theme.quill))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
    }
}

// MARK: - Formulários

/// Seção de formulário: título, um cartão com linhas divididas por hairlines e uma nota embaixo.
struct MPFormSection<Content: View>: View {
    let title: String?
    var footer: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { MPSectionLabel(title).padding(.leading, 4) }
            VStack(alignment: .leading, spacing: 0) {
                _VariadicView.Tree(MPFormRows()) { content() }
            }
            .background(Theme.plumage, in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous).strokeBorder(Theme.quill))
            if let footer {
                Text(footer).font(.system(size: 11)).foregroundStyle(Theme.textMuted).padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Coloca cada filho numa linha com padding e uma divisória entre elas.
private struct MPFormRows: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            if child.id != last { MPDivider().padding(.leading, 14) }
        }
    }
}

/// Linha de formulário: rótulo à esquerda, controle à direita.
struct MPFormRow<Control: View>: View {
    let label: String
    var detail: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textMuted) }
            }
            Spacer(minLength: 12)
            control()
        }
    }
}

// MARK: - Slider

/// Trilho fino com a parte preenchida no brilho da pena e um botão redondo arrastável.
struct MPSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = (value - range.lowerBound) / max(range.upperBound - range.lowerBound, 0.0001)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.plumageRaised).frame(height: 4)
                Capsule().fill(Theme.sheen).frame(width: max(0, width * fraction), height: 4)
                Circle().fill(Theme.text)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: max(0, min(width - 14, width * fraction - 7)))
            }
            .frame(height: 18)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let raw = range.lowerBound + (range.upperBound - range.lowerBound) * min(max(drag.location.x / width, 0), 1)
                value = (raw / step).rounded() * step
            })
        }
        .frame(height: 18)
    }
}
