import AppKit
import SwiftUI

// Menus e diálogos do design system. Os nativos (NSMenu, alert, confirmationDialog) não aceitam estilo;
// estes são janelas sem borda desenhadas pelo app: o menu abre colado ao botão, o diálogo centrado
// sobre a janela com um véu por cima dela.

// MARK: - Janela flutuante

/// Painel sem borda. Diálogos aceitam foco (campos de texto); menus não: se o menu virasse a janela ativa,
/// a janela de baixo perderia o foco no clique, o que fecha o menu antes de a opção ser escolhida.
private final class MPPanel: NSPanel {
    var acceptsKey = true
    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }
}

/// O primeiro clique já vale (o painel nunca é a janela ativa, então o clique não pode ser gasto ativando-o).
private final class MPHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Menus e diálogos ficam em camadas separadas: um menu pode abrir por cima de um diálogo (o seletor de som
/// dentro de "Cor e som") sem derrubá-lo. Com uma camada só, o menu fechava o diálogo e, pendurado na janela
/// dele, o trazia de volta "solto": os botões Salvar/Cancelar não tinham mais o que fechar.
@MainActor
final class MPOverlayPresenter {
    static let shared = MPOverlayPresenter()
    /// Injeta os objetos do app (projetos, uso, configurações…) no conteúdo, que roda numa janela à parte.
    var environment: (AnyView) -> AnyView = { $0 }

    private final class Layer {
        let panel: MPPanel
        var monitors: [Any] = []
        var observers: [NSObjectProtocol] = []
        let onDismiss: () -> Void

        init(panel: MPPanel, onDismiss: @escaping () -> Void) {
            self.panel = panel
            self.onDismiss = onDismiss
        }
    }

    private var menu: Layer?
    private var dialog: Layer?
    var dialogWindow: NSWindow? { dialog?.panel }
    var menuWindow: NSWindow? { menu?.panel }
    /// Margem transparente em volta do menu, onde a sombra é desenhada.
    static let menuInset: CGFloat = 18

    /// Menu colado abaixo (ou acima, sem espaço) de `anchor`, em coordenadas de tela.
    func showMenu<Content: View>(at anchor: NSRect, in window: NSWindow?, @ViewBuilder content: () -> Content, onDismiss: @escaping () -> Void) {
        dismissMenu()
        let hosting = MPHostingView(rootView: environment(AnyView(content().mpDesignSystem().fixedSize())))
        let size = hosting.fittingSize
        let inset = Self.menuInset
        let screen = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        // Topo do menu 4pt abaixo do botão; se não couber, abre para cima.
        var origin = NSPoint(x: anchor.minX - inset, y: anchor.minY - 4 + inset - size.height)
        if origin.y < screen.minY { origin.y = anchor.maxY + 4 - inset }
        origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
        let layer = present(hosting, frame: NSRect(origin: origin, size: size), parent: window, level: .popUpMenu, onDismiss: onDismiss)
        menu = layer
        // Clique fora do menu (inclusive no diálogo embaixo dele, ou em outro app) fecha só o menu; Esc também.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            if event.window !== self?.menu?.panel { self?.dismissMenu() }
            return event
        }) { layer.monitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissMenu() }
        }) { layer.monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }  // Esc
            self?.dismissMenu()
            return nil
        }) { layer.monitors.append(monitor) }
        if let window {
            // Trocar de app ou de janela fecha o menu.
            layer.observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismissMenu() }
            })
        }
    }

    /// Diálogo centrado sobre a janela, com véu cobrindo o conteúdo dela.
    func showDialog<Content: View>(over window: NSWindow?, @ViewBuilder content: () -> Content, onDismiss: @escaping () -> Void) {
        dismissDialog()
        guard let window else { return }
        let root = ZStack {
            Rectangle().fill(Theme.ink.opacity(0.62)).ignoresSafeArea()
            content()
        }
        .mpDesignSystem()
        .preferredColorScheme(window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)
        let hosting = NSHostingView(rootView: environment(AnyView(root)))
        let layer = present(hosting, frame: window.frame, parent: window, level: .floating, onDismiss: onDismiss)
        dialog = layer
        // Esc fecha o diálogo, a não ser que haja um menu aberto por cima (aí fecha o menu).
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53, self?.menu == nil else { return event }
            self?.dismissDialog()
            return nil
        }) { layer.monitors.append(monitor) }
        layer.panel.makeKey()
    }

    private func present(_ view: NSView, frame: NSRect, parent: NSWindow?, level: NSWindow.Level, onDismiss: @escaping () -> Void) -> Layer {
        let panel = MPPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.acceptsKey = level != .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = level
        panel.isReleasedWhenClosed = false
        panel.appearance = parent?.effectiveAppearance
        panel.contentView = view
        parent?.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        return Layer(panel: panel, onDismiss: onDismiss)
    }

    /// Fecha o que estiver por cima: o menu, se houver; senão o diálogo.
    func dismiss() {
        if menu != nil { dismissMenu() } else { dismissDialog() }
    }

    func dismissMenu() {
        guard let layer = menu else { return }
        menu = nil
        close(layer)
    }

    /// Fecha o diálogo (e um menu aberto em cima dele).
    func dismissDialog() {
        dismissMenu()
        guard let layer = dialog else { return }
        dialog = nil
        close(layer)
    }

    private func close(_ layer: Layer) {
        layer.monitors.forEach(NSEvent.removeMonitor)
        layer.observers.forEach(NotificationCenter.default.removeObserver)
        layer.panel.parent?.removeChildWindow(layer.panel)
        layer.panel.orderOut(nil)
        layer.onDismiss()
    }
}

/// Guarda a NSView de um trecho da interface, para saber onde ela está na tela.
private struct MPAnchorReader: NSViewRepresentable {
    let box: MPAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}

@MainActor
final class MPAnchorBox {
    weak var view: NSView?

    var screenRect: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

// MARK: - Menu

/// Uma entrada de menu: item, título de seção ou divisória.
struct MPMenuEntry: Identifiable {
    enum Kind { case item, header, divider }
    let id = UUID()
    let kind: Kind
    var label = ""
    var detail: String?
    var icon: String?
    var checked = false
    var shortcut: String?
    var danger = false
    var disabled = false
    var action: () -> Void = {}

    static func item(_ label: String, detail: String? = nil, icon: String? = nil, checked: Bool = false,
                     shortcut: String? = nil, danger: Bool = false, disabled: Bool = false,
                     action: @escaping () -> Void) -> MPMenuEntry {
        MPMenuEntry(kind: .item, label: label, detail: detail, icon: icon, checked: checked, shortcut: shortcut,
                    danger: danger, disabled: disabled, action: action)
    }

    static func header(_ label: String) -> MPMenuEntry { MPMenuEntry(kind: .header, label: label) }
    static var divider: MPMenuEntry { MPMenuEntry(kind: .divider) }
}

struct MPMenuPanel: View {
    let entries: [MPMenuEntry]
    let close: () -> Void
    @State private var hovered: UUID?

    var body: some View {
        let hasChecks = entries.contains { $0.checked }
        VStack(alignment: .leading, spacing: 1) {
            ForEach(entries) { entry in
                switch entry.kind {
                case .divider:
                    Rectangle().fill(Theme.quill).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 4)
                case .header:
                    Text(entry.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textFaint)
                        .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
                case .item:
                    Button {
                        close()
                        entry.action()
                    } label: {
                        HStack(spacing: 8) {
                            if hasChecks {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.sheen).opacity(entry.checked ? 1 : 0).frame(width: 12)
                            }
                            if let icon = entry.icon {
                                Image(systemName: icon).font(.system(size: 11)).frame(width: 14)
                                    .foregroundStyle(entry.danger ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(Theme.textMuted))
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.label).font(.system(size: 13))
                                    .foregroundStyle(entry.danger ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(Theme.text))
                                if let detail = entry.detail {
                                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                                }
                            }
                            Spacer(minLength: 16)
                            if let shortcut = entry.shortcut {
                                Text(shortcut).font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(hovered == entry.id ? Theme.sheenSoft : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                        .contentShape(Rectangle())
                        .opacity(entry.disabled ? 0.45 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(entry.disabled)
                    .onHover { if $0 { hovered = entry.id } else if hovered == entry.id { hovered = nil } }
                }
            }
        }
        .padding(4)
        // Com descrições, largura fixa: a altura é medida já com o texto quebrado (senão o menu sai cortado).
        .frame(minWidth: 220, idealWidth: entries.contains { $0.detail != nil } ? 340 : nil, maxWidth: 380, alignment: .leading)
        .background(Theme.plumage, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.quill))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
        .padding(MPOverlayPresenter.menuInset)  // espaço para a sombra dentro do painel transparente
    }

}

/// Botão que abre um menu do design system. O rótulo é qualquer view.
struct MPMenuButton<Label: View>: View {
    let entries: () -> [MPMenuEntry]
    @ViewBuilder let label: () -> Label
    @State private var box = MPAnchorBox()
    @State private var open = false

    init(entries: @escaping () -> [MPMenuEntry], @ViewBuilder label: @escaping () -> Label) {
        self.entries = entries
        self.label = label
    }

    var body: some View {
        Button {
            guard !open, let rect = box.screenRect else { return MPOverlayPresenter.shared.dismissMenu() }
            open = true
            // O painel tem 18pt de margem para a sombra: compensa para o menu encostar no botão.
            MPOverlayPresenter.shared.showMenu(at: rect, in: box.view?.window) {
                MPMenuPanel(entries: entries()) { MPOverlayPresenter.shared.dismissMenu() }
            } onDismiss: { open = false }
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .background(MPAnchorReader(box: box))
    }
}

/// Seletor em chip (modo, modelo, esforço): mostra o valor atual e abre as opções num menu.
struct MPSelect<Value: Hashable>: View {
    struct Option {
        let value: Value
        let label: String
        var detail: String?
    }

    var icon: String?
    let title: String?
    var highlighted = false
    var help = ""
    let options: [Option]
    var extra: [MPMenuEntry] = []
    @Binding var selection: Value
    @State private var hovering = false

    var body: some View {
        MPMenuButton(entries: {
            options.map { option in
                MPMenuEntry.item(option.label, detail: option.detail, checked: option.value == selection) { selection = option.value }
            } + extra
        }) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 11)) }
                if let title { Text(title).font(.system(size: 12)) }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.6)
            }
            .foregroundStyle(highlighted ? AnyShapeStyle(Theme.sheen) : hovering ? AnyShapeStyle(Theme.text) : AnyShapeStyle(Theme.textMuted))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(highlighted ? AnyShapeStyle(Theme.sheenSoft) : hovering ? AnyShapeStyle(Theme.plumageRaised) : AnyShapeStyle(Color.clear),
                        in: Capsule())
            .contentShape(Capsule())
            .onHover { hovering = $0 }
        }
        .fixedSize()
        .help(help)
    }
}

// MARK: - Diálogo

struct MPDialogAction {
    let label: String
    var variant: MPButtonStyle.Variant = .secondary
    var action: () -> Void = {}
}

/// Cartão do diálogo: título em serifa, texto, conteúdo opcional e ações à direita.
struct MPDialogCard<Content: View>: View {
    let title: String
    var message: String?
    var width: CGFloat = 420
    let actions: [MPDialogAction]
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(Theme.display(20)).fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
            content()
            if !actions.isEmpty {
                // Numa linha quando cabe; senão empilhados na largura toda, a ação principal em cima.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Spacer()
                        ForEach(Array(actions.enumerated()), id: \.offset) { index, item in
                            button(item, index: index, fill: false)
                        }
                    }
                    VStack(spacing: 8) {
                        ForEach(Array(actions.enumerated().reversed()), id: \.offset) { index, item in
                            button(item, index: index, fill: true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(24)
        .frame(width: width, alignment: .leading)
        .background(Theme.plumage, in: RoundedRectangle(cornerRadius: Theme.Radius.xl2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xl2, style: .continuous).strokeBorder(Theme.quill))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
    }

    private func button(_ item: MPDialogAction, index: Int, fill: Bool) -> some View {
        Button {
            MPOverlayPresenter.shared.dismissDialog()
            item.action()
        } label: {
            Text(item.label)
        }
        .buttonStyle(.mp(item.variant))
        .environment(\.mpButtonFills, fill)
        .keyboardShortcut(item.variant == .primary ? .defaultAction : (index == 0 ? .cancelAction : nil))
    }
}

extension MPDialogCard where Content == EmptyView {
    init(title: String, message: String? = nil, width: CGFloat = 420, actions: [MPDialogAction]) {
        self.init(title: title, message: message, width: width, actions: actions) { EmptyView() }
    }
}

private struct MPDialogModifier<Card: View>: ViewModifier {
    @Binding var isPresented: Bool
    let card: () -> Card
    @State private var box = MPAnchorBox()

    func body(content: Content) -> some View {
        content
            .background(MPAnchorReader(box: box))
            .onChange(of: isPresented) { _, presented in
                if presented {
                    MPOverlayPresenter.shared.showDialog(over: box.view?.window ?? NSApp.keyWindow) {
                        card()
                    } onDismiss: { isPresented = false }
                } else {
                    MPOverlayPresenter.shared.dismissDialog()
                }
            }
    }
}

extension View {
    /// Pergunta antes de algo que não dá para desfazer, ou um formulário curto. Esc cancela.
    func mpDialog(isPresented: Binding<Bool>, title: String, message: String? = nil, actions: [MPDialogAction]) -> some View {
        modifier(MPDialogModifier(isPresented: isPresented) { MPDialogCard(title: title, message: message, actions: actions) })
    }

    /// Diálogo com conteúdo próprio (formulários, folhas).
    func mpSheet<Card: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Card) -> some View {
        modifier(MPDialogModifier(isPresented: isPresented, card: content))
    }
}

/// Fecha o diálogo aberto (de dentro de um `mpSheet`).
@MainActor
func mpDismissOverlay() { MPOverlayPresenter.shared.dismissDialog() }

// MARK: - Menu de clique direito

/// Camada invisível que só "existe" para o clique direito: abre o menu do design system onde o mouse está.
private final class MPContextCatcherView: NSView {
    var entries: () -> [MPMenuEntry] = { [] }

    override func hitTest(_ point: NSPoint) -> NSView? {
        NSApp.currentEvent?.type == .rightMouseDown ? super.hitTest(point) : nil
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let entries = entries()
        MPOverlayPresenter.shared.showMenu(at: NSRect(x: point.x, y: point.y, width: 1, height: 1), in: window) {
            MPMenuPanelPublic(entries: entries)
        } onDismiss: {}
    }
}

private struct MPContextCatcher: NSViewRepresentable {
    let entries: () -> [MPMenuEntry]

    func makeNSView(context: Context) -> MPContextCatcherView {
        let view = MPContextCatcherView()
        view.entries = entries
        return view
    }

    func updateNSView(_ nsView: MPContextCatcherView, context: Context) { nsView.entries = entries }
}

/// O mesmo painel de menu, para quem abre de fora do MPMenuButton.
struct MPMenuPanelPublic: View {
    let entries: [MPMenuEntry]
    var body: some View { MPMenuPanel(entries: entries) { MPOverlayPresenter.shared.dismissMenu() } }
}

extension View {
    /// Menu de clique direito desenhado pelo app (no lugar do contextMenu nativo).
    func mpContextMenu(_ entries: @escaping () -> [MPMenuEntry]) -> some View {
        overlay(MPContextCatcher(entries: entries))
    }
}
