import AppKit
import SwiftUI

/// O que o corvo fala: o Claude terminou (com a primeira frase do que ele fez) ou precisa de você.
struct Speech: Equatable {
    enum Kind { case finished, waiting, focus }

    let id = UUID()
    let kind: Kind
    let project: String
    let color: Color
    let text: String
    let open: () -> Void

    static func == (lhs: Speech, rhs: Speech) -> Bool { lhs.id == rhs.id }

    /// Primeira frase da mensagem do Claude, sem Markdown, até ~120 caracteres.
    static func headline(_ message: String) -> String {
        var text = message
        for pattern in ["```[\\s\\S]*?```", "`", "\\*\\*", "__", "(?m)^#+ .*$", "\\[([^\\]]+)\\]\\([^)]*\\)"] {
            let template = pattern.hasPrefix("\\[") ? "$1" : ""
            text = text.replacingOccurrences(of: pattern, with: template, options: [.regularExpression])
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        // A primeira frase que diga algo: pula aberturas curtas ("Pronto.", "Feito!").
        let sentences = text.components(separatedBy: ". ").flatMap { $0.components(separatedBy: "! ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var sentence = sentences.first { $0.count >= 25 } ?? text
        if !sentence.hasSuffix(".") && !sentence.hasSuffix("!") && !sentence.hasSuffix("?") && sentence.count < text.count { sentence += "." }
        guard sentence.count > 120 else { return sentence }
        let cut = sentence.prefix(118)
        return String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) + "…"
    }
}

/// Balão em cima do corvo da tela: escreve o texto letra por letra, some sozinho (não com o mouse em cima)
/// e, clicado, abre a conversa.
@MainActor
final class SpeechBubbleController {
    private var panel: DesktopPetPanel?
    private var hosting: NSHostingView<AnyView>?
    private(set) var speech: Speech?
    private var shownAt = Date()
    private var hovering = false
    private var hideWork: DispatchWorkItem?
    private var measured: (id: UUID, height: CGFloat)?
    var environment: (AnyView) -> AnyView = { $0 }

    static let lettersPerSecond: Double = 55

    var isVisible: Bool { speech != nil }
    var window: NSWindow? { speech == nil ? nil : panel }

    /// Ainda escrevendo (o corvo mexe o bico enquanto isso).
    var isTyping: Bool {
        guard let speech else { return false }
        return Date().timeIntervalSince(shownAt) < Double(speech.text.count) / Self.lettersPerSecond
    }

    func show(_ speech: Speech, near crow: CGRect) {
        self.speech = speech
        shownAt = Date()
        hovering = false
        if panel == nil {
            let panel = DesktopPetPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            self.panel = panel
        }
        render(near: crow)
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel?.animator().alphaValue = 1
        }
        scheduleHide()
    }

    /// Acompanha o corvo enquanto ele anda ou voa.
    func follow(_ crow: CGRect) {
        guard speech != nil else { return }
        render(near: crow)
    }

    func hide() {
        hideWork?.cancel()
        guard let panel else { return }
        speech = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            MainActor.assumeIsolated {
                // Fora da tela, a interface é descartada: escondida, a animação continuaria rodando à toa.
                guard self?.speech == nil else { return }
                panel?.orderOut(nil)
                panel?.contentView = nil
                self?.hosting = nil
            }
        })
    }

    private func scheduleHide() {
        hideWork?.cancel()
        guard let speech else { return }
        let typing = Double(speech.text.count) / Self.lettersPerSecond
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.hovering { self.scheduleHide() } else { self.hide() }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + typing + (speech.kind == .finished ? 7 : 12), execute: work)
    }

    private func render(near crow: CGRect) {
        guard let panel, let speech else { return }
        let screen = (NSScreen.screens.first { $0.frame.contains(CGPoint(x: crow.midX, y: crow.midY)) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let width: CGFloat = 250
        // Mede a altura com o texto inteiro (não muda enquanto as letras aparecem), uma vez por fala.
        if measured?.id != speech.id {
            let measure = NSHostingView(rootView: environment(AnyView(SpeechBubbleView(speech: speech, shownAt: .distantPast, tailX: width / 2,
                                                                                        below: false, onHover: { _ in }))))
            measured = (speech.id, measure.fittingSize.height)
        }
        let height = measured?.height ?? 80
        var origin = CGPoint(x: crow.midX - width / 2, y: crow.maxY - 4)
        let below = origin.y + height > screen.maxY
        if below { origin.y = crow.minY - height + 4 }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - width - 4)
        let tailX = min(max(crow.midX - origin.x, 22), width - 22)
        let view = SpeechBubbleView(speech: speech, shownAt: shownAt, tailX: tailX, below: below) { [weak self] inside in
            self?.hovering = inside
        }
        if let hosting {
            hosting.rootView = environment(AnyView(view))
        } else {
            let hosting = NSHostingView(rootView: environment(AnyView(view)))
            panel.contentView = hosting
            self.hosting = hosting
        }
        panel.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
    }
}

/// O balão: projeto (na cor dele), o texto aparecendo letra por letra e a pontinha apontando para o corvo.
private struct SpeechBubbleView: View {
    let speech: Speech
    let shownAt: Date
    let tailX: CGFloat
    let below: Bool
    let onHover: (Bool) -> Void
    @State private var hovering = false

    private static let tail: CGFloat = 8

    /// Quando a última letra aparece: depois disso a linha do tempo acaba e nada mais redesenha.
    private var typingEnd: Date { shownAt.addingTimeInterval(Double(speech.text.count) / SpeechBubbleController.lettersPerSecond) }

    private var label: String {
        switch speech.kind {
        case .focus: "modo foco"
        case .waiting: hovering ? "abrir conversa ›" : "precisa de você"
        case .finished: hovering ? "abrir conversa ›" : "terminou"
        }
    }

    var body: some View {
        Button(action: speech.open) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(speech.color).frame(width: 7, height: 7)
                    Text(speech.project).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textMuted).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(hovering || speech.kind == .focus ? AnyShapeStyle(Theme.sheen)
                                         : speech.kind == .waiting ? AnyShapeStyle(Theme.ember) : AnyShapeStyle(Theme.success))
                }
                TimelineView(.explicit(Array(stride(from: shownAt, through: typingEnd + 0.05, by: 1.0 / 30)))) { context in
                    let shown = Int(context.date.timeIntervalSince(shownAt) * SpeechBubbleController.lettersPerSecond)
                    // O texto inteiro reserva o espaço; a parte ainda não "falada" fica invisível.
                    (Text(speech.text.prefix(max(0, shown))) + Text(speech.text.dropFirst(max(0, shown))).foregroundColor(.clear))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 9 + (below ? Self.tail : 0))
            .padding(.bottom, 10 + (below ? 0 : Self.tail))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BubbleShape(tailX: tailX, tail: Self.tail, below: below).fill(Theme.plumage))
            .overlay(BubbleShape(tailX: tailX, tail: Self.tail, below: below).stroke(Theme.quillStrong, lineWidth: 1))
            .contentShape(BubbleShape(tailX: tailX, tail: Self.tail, below: below))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            onHover(inside)
        }
        .frame(width: 250)
    }
}

/// Retângulo arredondado com a pontinha embaixo (ou em cima, quando o balão fica abaixo do corvo).
private struct BubbleShape: Shape {
    let tailX: CGFloat
    let tail: CGFloat
    let below: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 12
        let top = below ? rect.minY + tail : rect.minY
        let bottom = below ? rect.maxY : rect.maxY - tail
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: top))
        if below {
            path.addLine(to: CGPoint(x: tailX - tail, y: top))
            path.addLine(to: CGPoint(x: tailX, y: rect.minY))
            path.addLine(to: CGPoint(x: tailX + tail, y: top))
        }
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: top), tangent2End: CGPoint(x: rect.maxX, y: bottom), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: bottom), tangent2End: CGPoint(x: rect.minX, y: bottom), radius: radius)
        if !below {
            path.addLine(to: CGPoint(x: tailX + tail, y: bottom))
            path.addLine(to: CGPoint(x: tailX, y: rect.maxY))
            path.addLine(to: CGPoint(x: tailX - tail, y: bottom))
        }
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: bottom), tangent2End: CGPoint(x: rect.minX, y: top), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: top), tangent2End: CGPoint(x: rect.maxX, y: top), radius: radius)
        path.closeSubpath()
        return path
    }
}
