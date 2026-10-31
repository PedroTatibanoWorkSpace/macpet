import SwiftUI

// Animações contínuas feitas pelo Core Animation, no servidor de janelas. Um TimelineView ou um repeatForever do
// SwiftUI refaz o layout da janela inteira a cada quadro (com o chat aberto, as ~60 mensagens, Markdown incluído);
// aqui o quadro muda sem passar pelo SwiftUI.

/// Quadros de um sprite trocados em laço, com pixels nítidos.
struct MPSpriteAnimation: NSViewRepresentable {
    let frames: [CGImage]
    let fps: Double

    final class Coordinator {
        var shown: [ObjectIdentifier] = []
        var fps: Double = 0
        var reduceMotion = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.magnificationFilter = .nearest
        view.layer?.contentsGravity = .resize
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let layer = view.layer else { return }
        let ids = frames.map(ObjectIdentifier.init)
        let reduceMotion = context.environment.accessibilityReduceMotion
        let state = context.coordinator
        // Mesmos quadros: não reinicia a animação a cada atualização da tela.
        guard ids != state.shown || fps != state.fps || reduceMotion != state.reduceMotion else { return }
        state.shown = ids
        state.fps = fps
        state.reduceMotion = reduceMotion

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "frames")
        layer.contents = frames.first
        if frames.count > 1, fps > 0, !reduceMotion {
            let animation = CAKeyframeAnimation(keyPath: "contents")
            animation.values = frames
            animation.calculationMode = .discrete
            animation.duration = Double(frames.count) / fps
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: "frames")
        }
        CATransaction.commit()
    }
}

/// Pulsa a opacidade do conteúdo (0,35 ↔ 1), como o ponto de "trabalhando".
struct MPPulse<Content: View>: NSViewRepresentable {
    /// Meio ciclo (apagado → aceso), em segundos.
    var duration = 0.9
    /// Atraso do ciclo, para ondas como a dos três pontos de carregamento.
    var delay = 0.0
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let view = NSHostingView(rootView: content)
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSHostingView<Content>, context: Context) {
        view.rootView = content
        guard let layer = view.layer else { return }
        if context.environment.accessibilityReduceMotion {
            layer.removeAnimation(forKey: "pulse")
            layer.opacity = 0.8
            return
        }
        guard layer.animation(forKey: "pulse") == nil else { return }
        layer.opacity = 1
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.35
        animation.toValue = 1
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.timeOffset = (2 * duration - delay.truncatingRemainder(dividingBy: 2 * duration))
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "pulse")
    }
}
