import AppKit
import AVFoundation

/// Minijogo: o corvo samba e você toca a batucada (A S D F ou setas). As notas descem do alto da tela, direto na
/// área de trabalho (sem janela nem fundo), até os alvos em cima da cabeça dele.
/// Leve de propósito: cada nota desce por uma animação do Core Animation agendada para o instante certo (nada roda
/// a cada quadro), a batucada são dois compassos sintetizados uma vez e repetidos pelo áudio, um timer de 10 Hz
/// só solta notas e marca erros, e ao sair tudo (som, timer, camadas) é destruído.
@MainActor
final class SambaGame: NSObject, NSWindowDelegate {
    var onStart: ((Date) -> Void)?
    /// Fim da partida, com o aproveitamento (0…1).
    var onEnd: ((Double) -> Void)?
    var onClose: (() -> Void)?
    /// Depuração (e gravação de vídeo): a partida começa sozinha e toca todas as notas.
    var autoplay = false

    private struct Note {
        let time: CFTimeInterval
        let lane: Int
        var layer: CALayer?
        var done = false
    }

    private enum State { case ready, playing, ended }

    // Ritmo: pagode a 92 bpm em 2/4, grade de semicolcheias.
    private static let step: Double = 60.0 / 92 / 4
    private static let barSteps = 8
    private static let introBars = 2
    private static let playBars = 36
    private static let totalBars = 40
    /// Tempo que a nota leva do alto da tela até o alvo.
    private static let travel: Double = 2.0
    private static let perfect = 0.08, good = 0.17

    private static let laneColors: [UInt32] = [0x4ADE80, 0xF5C542, 0x55B4FF, 0xFF4F81]
    private static let laneKeys = ["A", "S", "D", "F"]
    private static let laneWidth: CGFloat = 46

    private weak var crow: NSWindow?
    private var window: SambaGameWindow?
    private let stage = CALayer()
    private var targets: [CALayer] = []
    private let scoreText = CATextLayer(), judgeText = CATextLayer(), messageText = CATextLayer()
    /// Altura do centro dos alvos, em coordenadas da camada.
    private var hitY: CGFloat = 0

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var song: AVAudioPCMBuffer?
    private var muted = UserDefaults.standard.bool(forKey: "sambaGame.muted")

    private var state = State.ready
    private var notes: [Note] = []
    private var nextSpawn = 0
    private var timer: Timer?
    private var keyMonitor: Any?
    private var autoClose: DispatchWorkItem?
    private var start: CFTimeInterval = 0
    private var end: CFTimeInterval = 0
    private var score = 0, combo = 0, bestCombo = 0
    private var earned = 0.0

    init(crow: NSWindow?) {
        self.crow = crow
        super.init()
    }

    // MARK: Palco (janela transparente, os cliques passam)

    func show() {
        let (frame, crowTop) = placement()
        // Não ativa o app (como o Spotlight): recebe o teclado sem trazer as outras janelas do MacPet para a frente.
        let window = SambaGameWindow(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                                     defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = crow?.level ?? .floating
        window.joinAllSpaces()
        window.isReleasedWhenClosed = false
        window.delegate = self
        let view = SambaGameView(frame: NSRect(origin: .zero, size: frame.size))
        view.onKey = { [weak self] code in self?.key(code) }
        window.contentView = view
        hitY = crowTop + 26
        build(in: view)
        // A música é sintetizada ao abrir (~0,1 s), antes da partida.
        song = SambaSong.render(format: AVAudioFormat(standardFormatWithSampleRate: SambaSong.rate, channels: 1)!,
                                bars: Self.totalBars, step: Self.step)
        self.window = window
        addStopButton(to: window)
        window.orderFront(nil)
        if let crow, crow.isVisible { window.order(.below, relativeTo: crow.windowNumber) }
        // Começa sozinho (a introdução dá uns 3 s até a primeira nota). O teclado vem depois que o menu do corvo
        // termina de fechar: antes disso, a janela que estava ativa pegaria o foco de volta.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.window != nil else { return }
            self.focus()
            self.watchKeys()
            self.begin()
        }
    }

    /// Botão "Parar" clicável ao lado do placar (as pistas deixam os cliques passarem; ele não).
    private func addStopButton(to window: NSWindow) {
        let size = NSSize(width: 64, height: 22)
        let origin = NSPoint(x: window.frame.maxX + 2, y: window.frame.minY + hitY - size.height / 2)
        let panel = SambaGameWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = window.level
        panel.joinAllSpaces()
        let button = SambaStopButton(frame: NSRect(origin: .zero, size: size))
        button.onClick = { [weak self] in self?.quit() }
        panel.contentView = button
        window.addChildWindow(panel, ordered: .above)
    }

    func focus() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        if let crow, crow.isVisible { window.order(.below, relativeTo: crow.windowNumber) }
        window.makeFirstResponder(window.contentView)
    }

    /// Com o MacPet ativo e o foco em outra janela dele (o chat, por exemplo), as teclas do jogo ainda chegam aqui
    /// durante a partida. Fora dela, o teclado fica como sempre.
    private func watchKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.state == .playing, event.window !== self.window,
                      event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                      [0, 1, 2, 3, 53, 123, 124, 125, 126].contains(event.keyCode) else { return false }
                if !event.isARepeat { self.key(event.keyCode) }
                return true
            }
            return handled ? nil : event
        }
    }

    /// Coluna acima do corvo, do chão dele até o alto da tela. Sem corvo, no meio da parte de baixo da tela.
    private func placement() -> (NSRect, CGFloat) {
        let crowFrame = crow?.isVisible == true ? crow?.frame : nil
        let screen = NSScreen.screens.first { crowFrame.map($0.frame.intersects) ?? false } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = Self.laneWidth * 4 + 24
        var anchor = crowFrame ?? NSRect(x: visible.midX - 48, y: visible.minY + 20, width: 96, height: 80)
        // Corvo no alto da tela (pousado numa janela): sem espaço para as notas caírem, o jogo vai para baixo.
        if visible.maxY - anchor.minY < 420 {
            anchor = NSRect(x: anchor.midX - 48, y: visible.minY + 20, width: 96, height: 80)
        }
        let x = min(max(anchor.midX - width / 2, visible.minX), visible.maxX - width)
        let bottom = max(anchor.minY, visible.minY)
        // O topo do corvo, sem a folga de 2 linhas do quadro reservada a chapéus.
        let crowTop = max(0, anchor.maxY - anchor.height * 0.1 - bottom)
        return (NSRect(x: x, y: bottom, width: width, height: visible.maxY - bottom), crowTop)
    }

    func windowWillClose(_ notification: Notification) {
        teardown()
        // Solta a janela e o jogo só depois que o fechamento terminar.
        DispatchQueue.main.async { [self] in
            window = nil
            onClose?()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Outro app pegou o teclado (no MacPet, as teclas continuam chegando pelo monitor).
        if state != .ended, !NSApp.isActive { showMessage("Clique no corvo para voltar a tocar") }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if state == .playing { showMessage(nil) }
    }

    /// Encerra o jogo (Esc ou "Parar o samba" no menu do corvo).
    func quit() {
        for child in window?.childWindows ?? [] { child.close() }
        window?.close()
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        autoClose?.cancel()
        autoClose = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        song = nil
        window?.delegate = nil
    }

    // MARK: Desenho (camadas; nada é redesenhado por quadro)

    private func build(in view: NSView) {
        guard let root = view.layer else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        stage.frame = root.bounds
        root.addSublayer(stage)

        for lane in 0..<4 {
            let x = laneX(lane)
            // Trilho fininho da pista, sumindo para cima.
            let rail = CAGradientLayer()
            rail.frame = CGRect(x: x - 1, y: hitY, width: 2, height: stage.bounds.height - hitY)
            rail.colors = [Self.color(Self.laneColors[lane], alpha: 0.45), Self.color(Self.laneColors[lane], alpha: 0)]
            rail.startPoint = CGPoint(x: 0.5, y: 0)
            rail.endPoint = CGPoint(x: 0.5, y: 1)
            stage.addSublayer(rail)

            let target = CALayer()
            target.frame = CGRect(x: x - 17, y: hitY - 17, width: 34, height: 34)
            target.cornerRadius = 17
            target.borderWidth = 2.5
            target.borderColor = Self.color(Self.laneColors[lane], alpha: 0.95)
            target.backgroundColor = CGColor(srgbRed: 0.08, green: 0.09, blue: 0.14, alpha: 0.55)
            shadow(target)
            let label = CATextLayer()
            configure(label, Self.laneKeys[lane], size: 12, weight: .heavy, scale: scale)
            label.frame = CGRect(x: 0, y: 9, width: 34, height: 16)
            label.alignmentMode = .center
            label.foregroundColor = Self.color(Self.laneColors[lane], alpha: 1)
            target.addSublayer(label)
            stage.addSublayer(target)
            targets.append(target)
        }

        let width = stage.bounds.width
        configure(scoreText, "", size: 12, weight: .bold, scale: scale)
        scoreText.frame = CGRect(x: 0, y: hitY + 28, width: width, height: 16)
        scoreText.alignmentMode = .center
        configure(judgeText, "", size: 17, weight: .heavy, scale: scale)
        judgeText.frame = CGRect(x: 0, y: hitY + 50, width: width, height: 24)
        judgeText.alignmentMode = .center
        judgeText.opacity = 0
        configure(messageText, "", size: 12, weight: .semibold, scale: scale)
        messageText.frame = CGRect(x: 0, y: hitY + 50, width: width, height: 110)
        messageText.alignmentMode = .center
        messageText.isWrapped = true
        for layer in [scoreText, judgeText, messageText] {
            shadow(layer)
            stage.addSublayer(layer)
        }
        updateHeader()
    }

    private func laneX(_ lane: Int) -> CGFloat {
        stage.bounds.midX + (CGFloat(lane) - 1.5) * Self.laneWidth
    }

    /// Sombra escura para ler em qualquer papel de parede.
    private func shadow(_ layer: CALayer) {
        layer.shadowColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        layer.shadowOpacity = 0.85
        layer.shadowRadius = 2.5
        layer.shadowOffset = .zero
    }

    private func configure(_ layer: CATextLayer, _ string: String, size: CGFloat, weight: NSFont.Weight, scale: CGFloat) {
        layer.string = string
        layer.font = NSFont.systemFont(ofSize: size, weight: weight)
        layer.fontSize = size
        layer.foregroundColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95)
        layer.contentsScale = scale
    }

    private static func color(_ hex: UInt32, alpha: CGFloat) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private func showMessage(_ string: String?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        messageText.string = string ?? ""
        messageText.isHidden = string == nil
        CATransaction.commit()
    }

    private func updateHeader() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let sound = muted ? " · sem som" : ""
        scoreText.string = state == .ready ? "" : combo > 1
            ? "\(score.formatted()) · combo \(combo) x\(multiplier)\(sound)" : "\(score.formatted())\(sound)"
        CATransaction.commit()
    }

    private var multiplier: Int { 1 + min(combo, 30) / 10 }

    // MARK: Partida

    private func begin() {
        autoClose?.cancel()
        autoClose = nil
        for note in notes { note.layer?.removeFromSuperlayer() }
        notes = Self.chart()
        nextSpawn = 0
        score = 0
        combo = 0
        bestCombo = 0
        earned = 0
        showMessage(nil)
        startAudio()
        // Relógio da partida = relógio do áudio agendado (ambos no tempo de máquina), sem desencontro.
        start = CACurrentMediaTime() + 1.0
        if let engine, engine.isRunning, let player {
            player.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: start)))
        }
        notes = notes.map { Note(time: start + $0.time, lane: $0.lane) }
        end = start + Double(Self.totalBars * Self.barSteps) * Self.step
        state = .playing
        updateHeader()
        onStart?(Date().addingTimeInterval(end - CACurrentMediaTime()))
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
        if autoplay {
            for note in notes {
                DispatchQueue.main.asyncAfter(deadline: .now() + (note.time - CACurrentMediaTime())) { [weak self] in
                    self?.press(note.lane)
                }
            }
        }
    }

    /// Notas da música (tempo relativo ao início). Fácil de propósito: uma nota por compasso na entrada, duas no
    /// meio e no máximo quatro no final, nos tempos fortes da batucada, passando pelas quatro pistas desde o começo.
    private static func chart() -> [Note] {
        let sweep = [0, 1, 2, 3, 3, 2, 1, 0]
        let pairs = [(0, 2), (1, 3), (2, 0), (3, 1), (0, 3), (2, 1)]
        let fours = [[0, 1, 2, 3], [3, 2, 1, 0], [0, 2, 1, 3], [3, 1, 2, 0]]
        var notes: [Note] = []
        for bar in introBars..<(introBars + playBars) {
            let section = bar < introBars + 8 ? 1 : bar < introBars + 20 ? 2 : 3
            func note(_ index: Int, _ lane: Int) {
                notes.append(Note(time: Double(bar * barSteps + index) * Self.step, lane: lane))
            }
            switch section {
            case 1:
                note(4, sweep[(bar - introBars) % sweep.count])     // tantã forte
            case 2:
                let pair = pairs[(bar - introBars) % pairs.count]
                note(0, pair.0)
                note(4, pair.1)
            default:
                let lanes = fours[bar % fours.count]
                note(0, lanes[0])
                note(bar % 2 == 0 ? 2 : 3, lanes[1])                  // tamborim, um por compasso
                note(4, lanes[2])
                if bar % 4 == 3 { note(6, lanes[3]) }
            }
        }
        return notes
    }

    private func tick() {
        guard state == .playing else { return }
        let now = CACurrentMediaTime()
        // Solta as notas que entram na tela nos próximos instantes (a animação começa na hora exata).
        while nextSpawn < notes.count, notes[nextSpawn].time - Self.travel < now + 0.5 {
            spawn(nextSpawn)
            nextSpawn += 1
        }
        for index in notes.indices where !notes[index].done && notes[index].time + Self.good < now {
            notes[index].done = true
            fade(notes[index].layer)
            notes[index].layer = nil
            combo = 0
            judge("Errou", color: 0xFF4F81)
            updateHeader()
        }
        if now > end + 0.3 { finish() }
    }

    private func spawn(_ index: Int) {
        let note = CALayer()
        note.bounds = CGRect(x: 0, y: 0, width: 26, height: 26)
        note.cornerRadius = 13
        note.backgroundColor = Self.color(Self.laneColors[notes[index].lane], alpha: 1)
        note.borderWidth = 2
        note.borderColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85)
        shadow(note)
        // Do alto da tela até o alvo em `travel`; passa do alvo e some atrás do corvo.
        let topY = stage.bounds.height + 16, endY = hitY - 70
        note.position = CGPoint(x: laneX(notes[index].lane), y: endY)
        note.opacity = 0
        let speed = (topY - hitY) / Self.travel
        let fall = CABasicAnimation(keyPath: "position.y")
        fall.fromValue = topY
        fall.toValue = endY
        let fadeOut = CAKeyframeAnimation(keyPath: "opacity")
        fadeOut.values = [1, 1, 0]
        fadeOut.keyTimes = [0, NSNumber(value: Double((topY - hitY) / (topY - endY))), 1]
        let group = CAAnimationGroup()
        group.animations = [fall, fadeOut]
        group.duration = Double((topY - endY) / speed)
        group.beginTime = stage.convertTime(notes[index].time - Self.travel, from: nil)
        group.fillMode = .both
        group.isRemovedOnCompletion = false
        note.add(group, forKey: "fall")
        stage.insertSublayer(note, below: targets.first)
        notes[index].layer = note
    }

    private func key(_ code: UInt16) {
        switch code {
        case 53: quit()                               // Esc
        case 46:                                      // M
            muted.toggle()
            UserDefaults.standard.set(muted, forKey: "sambaGame.muted")
            player?.volume = muted ? 0 : 1
            updateHeader()
        case 49 where state != .playing: begin()      // Espaço
        default:
            let lanes: [UInt16: Int] = [0: 0, 1: 1, 2: 2, 3: 3, 123: 0, 125: 1, 126: 2, 124: 3]
            guard let lane = lanes[code] else { return }
            press(lane)
        }
    }

    private func press(_ lane: Int) {
        flash(targets[lane])
        guard state == .playing else { return }
        let now = CACurrentMediaTime()
        let candidate = notes.indices
            .filter { !notes[$0].done && notes[$0].lane == lane && abs(notes[$0].time - now) <= Self.good }
            .min { abs(notes[$0].time - now) < abs(notes[$1].time - now) }
        guard let index = candidate else { return }
        let perfect = abs(notes[index].time - now) <= Self.perfect
        notes[index].done = true
        pop(notes[index].layer)
        notes[index].layer = nil
        combo += 1
        bestCombo = max(bestCombo, combo)
        score += (perfect ? 100 : 50) * multiplier
        earned += perfect ? 1 : 0.6
        judge(perfect ? "Perfeito!" : "Bom", color: perfect ? 0xF5C542 : 0x4ADE80)
        updateHeader()
    }

    private func finish() {
        state = .ended
        timer?.invalidate()
        timer = nil
        let total = notes.count
        let accuracy = total > 0 ? earned / Double(total) : 0
        let best = UserDefaults.standard.integer(forKey: "sambaGame.best")
        let record = score > best
        if record { UserDefaults.standard.set(score, forKey: "sambaGame.best") }
        let verdict = accuracy >= 0.9 ? "Mestre de bateria!" : accuracy >= 0.6 ? "Que samba!" : "Bora treinar o gingado"
        showMessage("""
        \(verdict)
        \(score.formatted()) pontos · \(Int((accuracy * 100).rounded()))% · combo \(bestCombo)
        \(record ? "Novo recorde!" : "Recorde: \(best.formatted())")
        Espaço: de novo · Esc ou Parar: sair
        """)
        // Sem partida, nada fica ligado: o áudio para e o placar some sozinho em alguns segundos.
        player?.stop()
        engine?.pause()
        let close = DispatchWorkItem { [weak self] in self?.quit() }
        autoClose = close
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: close)
        onEnd?(accuracy)
    }

    /// Partida rolando: até quando o corvo samba (nil fora da partida).
    var danceUntil: Date? {
        state == .playing ? Date().addingTimeInterval(end - CACurrentMediaTime()) : nil
    }

    // MARK: Efeitos (animações do Core Animation, disparadas só no toque)

    private func flash(_ layer: CALayer) {
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 1.2
        animation.toValue = 1
        animation.duration = 0.15
        layer.add(animation, forKey: "flash")
    }

    private func pop(_ layer: CALayer?) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.toValue = 1.9
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.18
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "pop")
        CATransaction.commit()
    }

    private func fade(_ layer: CALayer?) {
        guard let layer else { return }
        // A queda continua até sumir atrás do corvo; depois a camada sai.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { layer.removeFromSuperlayer() }
    }

    private func judge(_ string: String, color: UInt32) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        judgeText.string = string
        judgeText.foregroundColor = Self.color(color, alpha: 1)
        judgeText.opacity = 0
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = 0.5
        judgeText.add(animation, forKey: "judge")
    }

    // MARK: Música (sintetizada uma vez, ao abrir)

    private func startAudio() {
        player?.stop()
        if engine == nil {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let format = AVAudioFormat(standardFormatWithSampleRate: SambaSong.rate, channels: 1)!
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            do {
                try engine.start()
            } catch {
                return  // Sem som, o jogo continua no mesmo relógio.
            }
            self.engine = engine
            self.player = player
        }
        // O macOS desliga o motor quando a saída de som muda (fone, repouso): religa antes de tocar.
        if let engine, !engine.isRunning { try? engine.start() }
        guard let engine, engine.isRunning, let player, let song else { return }
        player.volume = muted ? 0 : 1
        player.scheduleBuffer(song)
    }
}

/// Palco sem borda e transparente: os cliques passam para o que estiver embaixo, mas ele recebe o teclado.
final class SambaGameWindow: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Em todas as mesas (Spaces), como o corvo.
    func joinAllSpaces() {
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    }
}

final class SambaGameView: NSView {
    var onKey: ((UInt16) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }
        onKey?(event.keyCode)
    }
}

/// "■ Parar" num balãozinho escuro (clique sem ativar o app).
final class SambaStopButton: NSView {
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = CGColor(srgbRed: 0.08, green: 0.09, blue: 0.14, alpha: 0.8)
        layer?.cornerRadius = frame.height / 2
        layer?.borderWidth = 1
        layer?.borderColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.25)
        let label = NSTextField(labelWithString: "■ Parar")
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = NSColor(white: 1, alpha: 0.92)
        label.sizeToFit()
        label.frame.origin = NSPoint(x: (frame.width - label.frame.width) / 2, y: (frame.height - label.frame.height) / 2)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
