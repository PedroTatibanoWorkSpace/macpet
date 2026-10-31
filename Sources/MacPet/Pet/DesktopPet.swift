import AppKit
import Combine
import SwiftUI

/// O corvo solto na tela: anda pelo chão (acima do Dock) e por cima das janelas, voa entre elas, cai quando
/// a janela sai de baixo e anda junto quando você arrasta a janela. Você pode arrastá-lo, fazer carinho,
/// dar petisco e brincar; ele reage ao Claude (laptop trabalhando, "!" esperando você, comemora ao terminar)
/// e dorme quando você sai do Mac.
@MainActor
final class DesktopPet {
    private enum Activity {
        case idle(until: Date)
        case walk(until: Date)
        case fly(from: CGPoint, to: CGPoint, control: CGPoint, duration: TimeInterval)
        case falling(velocity: CGFloat)
        case held
        case landing, hop, peck, petted
        /// Sambando até `until` (sozinho uns segundos, ou a partida inteira do minijogo).
        case samba(until: Date)
        /// Terminou uma tarefa: pula girando, pousa, tira o chapéu e mostra o ✓.
        case finish
        case sleeping
        case chase(until: Date)
    }

    /// Janela onde ele está pousado, para andar junto quando ela se move.
    private struct Perch {
        let windowID: Int
        var offset: CGFloat
    }

    /// Janela de outro app (ou do MacPet), em coordenadas de tela do Cocoa.
    private struct ScreenWindow {
        let id: Int
        let frame: CGRect
        let isNormal: Bool
    }

    private let env: AppEnvironment
    private var panel: DesktopPetPanel?
    private var sprite: DesktopPetView?
    private let bubble = SpeechBubbleController()
    private var game: SambaGame?
    private var timer: Timer?
    private var tickInterval: TimeInterval = 0
    private var lastTick = Date()
    private var placedOrigin: CGPoint?
    private var cancellables = Set<AnyCancellable>()

    /// Centro dos pés, em coordenadas de tela.
    private var position = CGPoint.zero
    private var facingRight = true
    private var activity: Activity = .idle(until: .distantPast)
    private var activityStarted = Date()
    private var perch: Perch?
    private var windows: [ScreenWindow] = []
    private var windowsRefreshed = Date.distantPast
    private var sleepingByChoice = false
    private var chaseMoving = false
    /// O Claude terminou enquanto ele voava ou era arrastado: comemora quando pousar.
    private var pendingFinish = false
    private var lastMood: PetMood = .idle
    private var shownFrame: [String] = []
    private var shownKey = ""
    private var drag: (mouse: CGPoint, position: CGPoint, moved: Bool)?
    /// Brincando: um clique em qualquer lugar da tela encerra (ele segue o cursor e não dá para clicar nele).
    private var playMonitors: [Any] = []
    private var savedPosition = CGPoint.zero

    private var settings: AppSettings { env.settings }
    var window: NSWindow? { panel }
    var bubbleWindow: NSWindow? { bubble.window }
    private var scale: CGFloat { CGFloat(settings.desktopPetScale) }
    private var size: CGSize { CGSize(width: CGFloat(PetArt.width) * scale, height: CGFloat(PetArt.height) * scale) }

    init(env: AppEnvironment) {
        self.env = env
    }

    // MARK: Mostrar e ocultar

    func install() {
        guard panel == nil else { return }
        let panel = DesktopPetPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = DesktopPetView(frame: CGRect(origin: .zero, size: size))
        view.owner = self
        panel.contentView = view
        self.panel = panel
        sprite = view

        bubble.environment = { [env] view in AnyView(env.inject(view.mpDesignSystem())) }
        position = restoredPosition()
        savedPosition = position
        activity = .falling(velocity: 0)
        place()
        panel.orderFrontRegardless()
        refreshWindows()
        lastTick = Date()
        schedule(1.0 / 30)
        settings.$desktopPetScale.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.resize() }
        }.store(in: &cancellables)
    }

    func remove() {
        savePosition(force: true)
        timer?.invalidate()
        timer = nil
        tickInterval = 0
        placedOrigin = nil
        cancellables = []
        MPOverlayPresenter.shared.dismissMenu()
        bubble.hide()
        panel?.orderOut(nil)
        panel = nil
        sprite = nil
    }

    private func resize() {
        guard let panel, let sprite else { return }
        sprite.frame = CGRect(origin: .zero, size: size)
        panel.setContentSize(size)
        placedOrigin = nil
        place()
    }

    // MARK: Ciclo

    private func tick() {
        // Sem tela nenhuma não há onde andar: espera ela voltar.
        guard !NSScreen.screens.isEmpty else { return }
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick), 0.1)
        lastTick = now
        // A lista de janelas custa ao WindowServer: pousado numa janela, olha com frequência (para andar junto
        // quando você a arrasta); andando, de vez em quando; parado no chão, quase nunca.
        let refreshEvery: TimeInterval = perch != nil ? 0.2 : isMoving ? 1 : 5
        if now.timeIntervalSince(windowsRefreshed) > refreshEvery { refreshWindows() }
        followPerch()
        reactToMood(now)
        updateSleep(now)
        step(dt, now)
        keepOnScreen()
        place()
        render(now)
        updateClickThrough()
        savePosition(force: false)
        // Em movimento, 20 quadros por segundo (visualmente igual a 30); parado, as animações não passam de
        // 6 quadros: 8 bastam.
        schedule(isMoving ? 1.0 / 20 : 1.0 / 8)
    }

    private var isMoving: Bool {
        switch activity {
        case .walk, .fly, .falling, .held, .chase, .finish: true
        default: false
        }
    }

    private func schedule(_ interval: TimeInterval) {
        guard interval != tickInterval else { return }
        tickInterval = interval
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func set(_ next: Activity) {
        activity = next
        activityStarted = Date()
        shownKey = ""
        if case .chase = next {} else { stopWatchingClicks() }
    }

    private var elapsed: TimeInterval { Date().timeIntervalSince(activityStarted) }

    private func step(_ dt: TimeInterval, _ now: Date) {
        switch activity {
        case .held:
            return

        case .falling(var velocity):
            velocity += 2400 * dt
            let next = position.y - velocity * dt
            if let landing = landingY(x: position.x, from: position.y, to: next) {
                position.y = landing
                perch = perchAt(position)
                set(.landing)
            } else {
                position.y = next
                activity = .falling(velocity: velocity)
            }

        case let .fly(from, to, control, duration):
            let t = min(1, elapsed / duration)
            let u = 1 - t
            position = CGPoint(x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
                               y: u * u * from.y + 2 * u * t * control.y + t * t * to.y)
            if t >= 1 {
                perch = perchAt(position)
                set(.landing)
            }

        case let .walk(until):
            walk(speed: 9 * scale, dt: dt)
            if now >= until { chooseNext() }

        case let .chase(until):
            // Voa atrás do cursor, logo abaixo e ao lado da seta (sem cobri-la); longe, acelera.
            let mouse = NSEvent.mouseLocation
            let side: CGFloat = mouse.x >= position.x ? -1 : 1
            let target = CGPoint(x: mouse.x + side * size.width * 0.45, y: mouse.y - size.height * 0.9)
            let dx = target.x - position.x, dy = target.y - position.y
            let distance = hypot(dx, dy)
            chaseMoving = distance > 8
            if chaseMoving {
                let stepLength = min(distance, max(140, distance * 3) * dt)
                position.x += dx / distance * stepLength
                position.y += dy / distance * stepLength
            }
            if abs(mouse.x - position.x) > 6 { facingRight = mouse.x > position.x }
            let bounds = visibleFrame(at: mouse)
            position.x = min(max(position.x, bounds.minX + size.width / 2), bounds.maxX - size.width / 2)
            position.y = min(max(position.y, bounds.minY), bounds.maxY - size.height)
            perch = nil
            // Acabou a brincadeira: cai e pousa no que estiver embaixo.
            if now >= until { set(.falling(velocity: 0)) }

        case let .idle(until):
            if now >= until { chooseNext() }
        case .finish:
            if elapsed > 3.4 { chooseNext() }
        case .landing:
            if elapsed > 0.35 {
                if pendingFinish {
                    pendingFinish = false
                    set(.finish)
                } else {
                    chooseNext()
                }
            }
        case .hop:
            if elapsed > 0.6 { chooseNext() }
        case .peck:
            if elapsed > 2.1 { chooseNext() }
        case .petted:
            if elapsed > 2.0 { chooseNext() }
        case let .samba(until):
            if now >= until { chooseNext() }
        case .sleeping:
            break
        }

        // Em pé sem nada embaixo (a janela fechou ou saiu): cai.
        if settings.desktopPetRoams, isStanding, !isSupported(position) {
            perch = nil
            set(.falling(velocity: 0))
        }
    }

    /// Anda na superfície atual; na beirada vira (ou, às vezes, pula).
    private func walk(speed: CGFloat, dt: TimeInterval, turnAtEdges: Bool = true) {
        let next = CGPoint(x: position.x + (facingRight ? speed : -speed) * dt, y: position.y)
        let bounds = visibleFrame(at: position)
        let inside = next.x > bounds.minX + size.width / 2 && next.x < bounds.maxX - size.width / 2
        if inside, isSupported(next) {
            position = next
            if let perch, let window = windows.first(where: { $0.id == perch.windowID }) {
                self.perch?.offset = position.x - window.frame.minX
            }
        } else if inside, turnAtEdges, Double.random(in: 0..<1) < 0.3 {
            position = next  // pula da beirada
            perch = nil
            set(.falling(velocity: 0))
        } else if turnAtEdges {
            facingRight.toggle()
        }
    }

    private var isStanding: Bool {
        switch activity {
        case .held, .falling, .fly, .chase: false
        default: true
        }
    }

    /// O que fazer depois: anda, fica parado, pula, bica o chão, samba ou voa para outro lugar.
    private func chooseNext() {
        let now = Date()
        // Partida do samba rolando: depois de comemorar ou de um carinho, volta a sambar no lugar.
        if let until = game?.danceUntil {
            set(.samba(until: until))
            return
        }
        // No foco ele cochila quieto (e não acorda quando você mexe no Mac).
        if env.focus.isFocusing {
            sleepingByChoice = true
            set(.sleeping)
            return
        }
        guard settings.desktopPetRoams, env.pet.mood != .waiting else {
            set(.idle(until: now.addingTimeInterval(4)))
            return
        }
        switch Double.random(in: 0..<1) {
        case ..<0.38:
            facingRight = Bool.random()
            set(.walk(until: now.addingTimeInterval(.random(in: 2...6))))
        case ..<0.72:
            set(.idle(until: now.addingTimeInterval(.random(in: 3...9))))
        case ..<0.80:
            set(.hop)
        case ..<0.86:
            set(.peck)
        case ..<0.89:
            set(.samba(until: now.addingTimeInterval(4)))
        default:
            if let target = randomSpot() { fly(to: target) } else { set(.idle(until: now.addingTimeInterval(4))) }
        }
    }

    private func fly(to target: CGPoint) {
        let from = position
        let distance = hypot(target.x - from.x, target.y - from.y)
        let control = CGPoint(x: (from.x + target.x) / 2, y: max(from.y, target.y) + min(220, distance * 0.35) + 30)
        facingRight = target.x >= from.x
        perch = nil
        set(.fly(from: from, to: target, control: control, duration: 0.35 + Double(distance) / 380))
    }

    // MARK: Claude e você

    private func reactToMood(_ now: Date) {
        let mood = env.pet.mood
        defer { lastMood = mood }
        guard mood != lastMood else { return }
        if mood == .celebrating, !env.focus.isFocusing {
            celebrate()
        } else if mood == .waiting, case .sleeping = activity {
            set(.hop)  // o Claude precisa de você: acorda
        }
    }

    /// Dorme quando você está longe do Mac (5 min sem teclado/mouse) e acorda quando volta.
    private func updateSleep(_ now: Date) {
        guard Int(now.timeIntervalSince1970 * 2) % 4 == 0 else { return }  // a cada ~2 s basta
        let away = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0) ?? .null)
        if case .sleeping = activity {
            if !sleepingByChoice, away < 2 { set(.hop) }
        } else if away > 300, isStanding, env.pet.mood != .waiting {
            sleepingByChoice = false
            set(.sleeping)
        }
    }

    // MARK: Ações (menu e cliques)

    /// Balão em cima do corvo (o Claude terminou ou precisa de você). Acorda e para quieto para "falar".
    func say(_ speech: Speech) {
        guard let panel else { return }
        wakeIfNeeded()
        if case .sleeping = activity { set(.hop) }
        if case .walk = activity { set(.idle(until: Date().addingTimeInterval(4))) }
        bubble.show(speech, near: panel.frame)
    }

    /// Modo foco mudou de fase: avisa no balão e cochila (foco) ou acorda e conta o que perdeu (pausa).
    func focusChanged(from previous: FocusTimer.Phase?, to next: FocusTimer.Phase?, held: [FocusTimer.Held]) {
        let focus = env.focus
        switch next {
        case .focus:
            say(Speech(kind: .focus, project: "Foco de \(settings.focusMinutes) min", color: ProjectColor.violet.color,
                       text: settings.focusHoldNotifications ? "Bora! Seguro as notificações até a pausa. Só te chamo se for urgente."
                                                            : "Bora! Te aviso quando der a pausa.", open: {}))
            set(.idle(until: Date().addingTimeInterval(3)))  // fala e depois cochila (ver chooseNext)
        case .shortBreak, .longBreak:
            sleepingByChoice = false
            celebrate()
            let finished = Array(Set(held.filter(\.finished).map(\.title))).sorted()
            let others = held.filter { !$0.finished }.count
            var text = next == .longBreak ? "Pausa longa! \(focus.completedToday) focos hoje. " : "Pausa! "
            if finished.isEmpty {
                text += "Levanta, alonga, bebe uma água."
            } else {
                text += "Enquanto você focava, terminou: \(finished.joined(separator: ", "))."
            }
            if others > 0 { text += " (+\(others) aviso\(others == 1 ? "" : "s"))" }
            say(Speech(kind: .focus, project: "\(next == .longBreak ? settings.longBreakMinutes : settings.breakMinutes) min de pausa",
                       color: ProjectColor.sage.color, text: text) { [weak self] in self?.env.openDashboard() })
        case nil:
            sleepingByChoice = false
            if case .sleeping = activity { set(.hop) }
            if previous == .shortBreak || previous == .longBreak {
                say(Speech(kind: .focus, project: "Pausa acabou", color: ProjectColor.ember.color,
                           text: "Bora para o próximo foco? Clique aqui para começar.") { [weak self] in self?.env.focus.startFocus() })
            }
        }
    }

    /// Comemoração de tarefa concluída (agora, ou quando pousar).
    func celebrate() {
        wakeIfNeeded()
        if isStanding { set(.finish) } else { pendingFinish = true }
    }

    func pet() {
        wakeIfNeeded()
        set(.petted)
    }

    func feed() {
        wakeIfNeeded()
        guard isStanding else { return }
        set(.peck)
    }

    func samba() {
        dance(until: Date().addingTimeInterval(4))
    }

    /// Samba até `until` (o minijogo segura a dança pela partida inteira).
    func dance(until: Date) {
        wakeIfNeeded()
        guard isStanding else { return }
        set(.samba(until: until))
    }

    func stopDancing() {
        if case .samba = activity { chooseNext() }
    }

    func stopSamba() {
        game?.quit()
    }

    /// Minijogo do samba: as notas descem até o corvo; ele dança enquanto você toca.
    func playSamba(autoplay: Bool = false) {
        if let game {
            if game.danceUntil != nil { game.focus() }
            return
        }
        let game = SambaGame(crow: settings.desktopPetEnabled ? panel : nil)
        game.autoplay = autoplay
        game.onStart = { [weak self] until in self?.dance(until: until) }
        game.onEnd = { [weak self] accuracy in
            if accuracy >= 0.6 { self?.celebrate() } else { self?.stopDancing() }
        }
        game.onClose = { [weak self] in
            self?.stopDancing()
            self?.game = nil
        }
        self.game = game
        game.show()
    }

    func play() {
        wakeIfNeeded()
        set(.chase(until: Date().addingTimeInterval(20)))
        watchClicksToStopPlaying()
    }

    /// Clique em outro app (monitor global; para mouse não precisa de permissão) ou no próprio MacPet: para de brincar.
    private func watchClicksToStopPlaying() {
        stopWatchingClicks()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.stopPlaying() }
        }) { playMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.stopPlaying() }
            return event
        }) { playMonitors.append(local) }
    }

    private func stopWatchingClicks() {
        playMonitors.forEach(NSEvent.removeMonitor)
        playMonitors.removeAll()
    }

    private func stopPlaying() {
        guard case .chase = activity else { return }
        set(.falling(velocity: 0))  // para onde está e cai até o chão ou a janela embaixo
    }

    func flySomewhere() {
        wakeIfNeeded()
        if let target = randomSpot() { fly(to: target) }
    }

    func toggleSleep() {
        if case .sleeping = activity {
            set(.hop)
        } else {
            sleepingByChoice = true
            set(.sleeping)
        }
    }

    private func wakeIfNeeded() {
        if case .sleeping = activity { sleepingByChoice = false }
    }

    private var isSleeping: Bool {
        if case .sleeping = activity { return true }
        return false
    }

    fileprivate func mouseDown(_ event: NSEvent) {
        if game?.danceUntil != nil { game?.focus() }  // tocando o samba: clicar no corvo devolve o teclado ao jogo
        drag = (NSEvent.mouseLocation, position, false)
    }

    fileprivate func mouseDragged(_ event: NSEvent) {
        guard var drag else { return }
        let mouse = NSEvent.mouseLocation
        let delta = CGPoint(x: mouse.x - drag.mouse.x, y: mouse.y - drag.mouse.y)
        if !drag.moved, hypot(delta.x, delta.y) < 3 { return }
        if !drag.moved {
            drag.moved = true
            perch = nil
            sleepingByChoice = false
            set(.held)
        }
        if abs(event.deltaX) > 1 { facingRight = event.deltaX > 0 }
        position = CGPoint(x: drag.position.x + delta.x, y: drag.position.y + delta.y)
        self.drag = drag
        place()
    }

    fileprivate func mouseUp(_ event: NSEvent) {
        defer { drag = nil }
        guard let drag else { return }
        if drag.moved {
            refreshWindows()  // solto sobre uma janela recém-aberta: ela precisa estar na lista para ele pousar
            if settings.desktopPetRoams { set(.falling(velocity: 0)) } else { set(.landing) }
            savePosition(force: true)
        } else if event.clickCount >= 2 || env.pet.mood == .waiting {
            env.openDashboard()
        } else if isSleeping {
            sleepingByChoice = false
            set(.hop)
        } else {
            pet()
        }
    }

    fileprivate func rightMouseDown(_ event: NSEvent) {
        guard let panel else { return }
        let entries = menuEntries()
        MPOverlayPresenter.shared.showMenu(at: panel.frame, in: panel) {
            MPMenuPanel(entries: entries) { MPOverlayPresenter.shared.dismissMenu() }
        } onDismiss: {}
    }

    private func menuEntries() -> [MPMenuEntry] {
        let play: [MPMenuEntry] = [
            .header(env.pet.moodDescription),
            .item("Fazer carinho", icon: "heart") { [weak self] in self?.pet() },
            .item("Dar um petisco", icon: "fork.knife") { [weak self] in self?.feed() },
            .item("Sambar", icon: "music.note") { [weak self] in self?.samba() },
            game == nil
                ? .item("Tocar samba", detail: "Minijogo: A S D F no ritmo", icon: "music.quarternote.3") { [weak self] in self?.playSamba() }
                : .item("Parar o samba", icon: "stop.fill") { [weak self] in self?.stopSamba() },
            .item("Brincar", detail: "Voa atrás do cursor por 20 s. Clique para parar", icon: "cursorarrow.motionlines") { [weak self] in self?.play() },
            .item("Voar para outro lugar", icon: "bird", disabled: !settings.desktopPetRoams) { [weak self] in self?.flySomewhere() },
            .item(isSleeping ? "Acordar" : "Dormir", icon: isSleeping ? "sun.max" : "moon.zzz") { [weak self] in self?.toggleSleep() },
            .item("Trocar roupa…", icon: "tshirt") { [weak self] in self?.env.openSettings(.crow) },
        ]
        let focus = env.focus
        var focusEntries: [MPMenuEntry] = [.divider]
        if !focus.isActive {
            focusEntries.append(.item("Começar foco (\(settings.focusMinutes) min)", icon: "timer") { focus.startFocus() })
        } else if focus.isPaused {
            focusEntries.append(.item("Continuar foco", detail: "Faltam \(focus.clock)", icon: "play.fill") { focus.resume() })
            focusEntries.append(.item("Encerrar foco", icon: "stop.fill") { focus.stop() })
        } else if focus.phase == .focus {
            focusEntries.append(.item("Pausar foco", detail: "Faltam \(focus.clock)", icon: "pause.fill") { focus.pause() })
            focusEntries.append(.item("Encerrar foco", icon: "stop.fill") { focus.stop() })
        } else {
            focusEntries.append(.item("Pular pausa", detail: "Faltam \(focus.clock)", icon: "forward.fill") { focus.skip() })
        }
        let roam: MPMenuEntry = .item("Andar pela tela", detail: "Desligado, ele fica onde você deixar",
                                      checked: settings.desktopPetRoams) { [weak self] in self?.toggleRoaming() }
        let sizes: [MPMenuEntry] = [("Pequeno", 3), ("Médio", 4), ("Grande", 5)].map { label, value in
            .item(label, checked: settings.desktopPetScale == value) { [weak self] in self?.settings.desktopPetScale = value }
        }
        let app: [MPMenuEntry] = [
            .item("Abrir MacPet", icon: "macwindow") { [weak self] in self?.env.openDashboard() },
            .item("Ocultar o corvo", detail: "Volte a mostrar pelo corvo da barra de menu", icon: "eye.slash") { [weak self] in
                self?.settings.desktopPetEnabled = false
            },
        ]
        return play + focusEntries + [.divider, roam, .header("Tamanho")] + sizes + [.divider] + app
    }

    private func toggleRoaming() {
        settings.desktopPetRoams.toggle()
        if settings.desktopPetRoams { set(.falling(velocity: 0)) } else { set(.idle(until: .distantFuture)) }
    }

    // MARK: Superfícies (chão e topo das janelas)

    private func refreshWindows() {
        windowsRefreshed = Date()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ownWindow = panel?.windowNumber ?? -1
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        windows = list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? Int, id != ownWindow,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let layer = info[kCGWindowLayer as String] as? Int, layer >= 0, layer < 25 else { return nil }
            let frame = CGRect(x: bounds["X"] ?? 0, y: primaryHeight - (bounds["Y"] ?? 0) - (bounds["Height"] ?? 0),
                               width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            // Camadas de sistema que cobrem a tela inteira (no macOS 26, o Dock tem uma assim, transparente): não
            // escondem nada; contadas, "cobriam" o topo de todas as janelas e o corvo nunca pousava em nenhuma.
            if layer > 0, NSScreen.screens.contains(where: { frame.contains($0.frame.insetBy(dx: 1, dy: 1)) }) { return nil }
            return ScreenWindow(id: id, frame: frame, isNormal: layer == 0 && frame.width >= 140 && frame.height >= 60)
        }
    }

    /// Janela pousada mudou de lugar: vai junto. Sumiu: o próximo passo faz cair.
    /// O corvo nunca fica onde não dá para ver: monitor desconectado, janela levada para fora da tela ou solto além
    /// da borda. Fora de todas as telas, volta para o canto da tela principal e cai até o chão.
    private func keepOnScreen() {
        switch activity {
        case .fly, .held: return  // no meio do voo (ou na sua mão) ele pode passar um pouco da borda
        default: break
        }
        let body = CGPoint(x: position.x, y: position.y + size.height / 2)
        guard !NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -4, dy: -4).contains(body) }) else { return }
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? Self.fallbackFrame
        position = CGPoint(x: frame.maxX - 160, y: frame.minY + 200)
        perch = nil
        set(.falling(velocity: 0))
    }

    private func followPerch() {
        guard let perch, isStanding, drag == nil else { return }
        guard let window = windows.first(where: { $0.id == perch.windowID }) else { return }
        position = CGPoint(x: window.frame.minX + perch.offset, y: window.frame.maxY)
    }

    /// Área útil da tela onde está o ponto. Sem nenhuma tela (Mac mini com o monitor desligado, troca de
    /// monitores), NSScreen.screens fica vazio: usa uma área padrão em vez de derrubar o app.
    private func visibleFrame(at point: CGPoint) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.visibleFrame ?? Self.fallbackFrame
    }

    private static let fallbackFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func groundY(at point: CGPoint) -> CGFloat { visibleFrame(at: point).minY }

    /// Topo de uma janela visível naquele ponto (não coberto por outra janela na frente).
    private func surfaceWindow(at point: CGPoint) -> ScreenWindow? {
        for (index, window) in windows.enumerated() where window.isNormal {
            guard abs(window.frame.maxY - point.y) < 2, point.x > window.frame.minX + 6, point.x < window.frame.maxX - 6,
                  window.frame.maxY < visibleFrame(at: point).maxY - 4 else { continue }
            let above = CGPoint(x: point.x, y: window.frame.maxY + 2)
            if !windows[..<index].contains(where: { $0.frame.contains(above) }) { return window }
        }
        return nil
    }

    private func isSupported(_ point: CGPoint) -> Bool {
        abs(point.y - groundY(at: point)) < 2 || surfaceWindow(at: point) != nil
    }

    private func perchAt(_ point: CGPoint) -> Perch? {
        surfaceWindow(at: point).map { Perch(windowID: $0.id, offset: point.x - $0.frame.minX) }
    }

    /// Caindo de `from` até `to`: a superfície mais alta que ele cruza naquele x.
    private func landingY(x: CGFloat, from: CGFloat, to: CGFloat) -> CGFloat? {
        let ground = groundY(at: CGPoint(x: x, y: from))
        var best: CGFloat? = to <= ground ? ground : nil
        for window in windows where window.isNormal && window.frame.maxY <= from && window.frame.maxY >= to {
            let top = CGPoint(x: x, y: window.frame.maxY)
            if surfaceWindow(at: top) != nil, window.frame.maxY > (best ?? -.infinity) { best = window.frame.maxY }
        }
        return best
    }

    /// Um lugar para pousar: topo de alguma janela visível ou o chão, na tela onde ele está.
    private func randomSpot() -> CGPoint? {
        refreshWindows()
        let bounds = visibleFrame(at: position)
        let margin = size.width / 2 + 8
        var spots: [CGPoint] = (0..<2).map { _ in
            CGPoint(x: .random(in: bounds.minX + margin...max(bounds.minX + margin + 1, bounds.maxX - margin)), y: bounds.minY)
        }
        for window in windows where window.isNormal && window.frame.width > margin * 2 + 20 {
            let point = CGPoint(x: .random(in: window.frame.minX + margin...window.frame.maxX - margin), y: window.frame.maxY)
            if bounds.contains(CGPoint(x: point.x, y: point.y - 1)), surfaceWindow(at: point) != nil { spots.append(point) }
        }
        return spots.filter { hypot($0.x - position.x, $0.y - position.y) > 120 }.randomElement()
    }

    // MARK: Desenho

    /// Altura do pulo da comemoração (só visual: o corvo continua apoiado onde estava).
    private var lift: CGFloat {
        guard case .finish = activity else { return 0 }
        let t = elapsed
        guard t > 0.17, t < 0.83 else { return 0 }
        return sin(.pi * (t - 0.17) / 0.66) * 14 * scale
    }

    private func place() {
        let origin = CGPoint(x: (position.x - size.width / 2).rounded(), y: (position.y + lift).rounded())
        guard origin != placedOrigin else { return }
        placedOrigin = origin
        panel?.setFrameOrigin(origin)
        if let panel { bubble.follow(panel.frame) }
    }

    private func animation() -> (name: String, fps: Double, loops: Bool) {
        switch activity {
        case .walk: return ("walk", 7, true)
        case .chase: return ("fly", chaseMoving ? 12 : 6, true)
        case .fly: return ("fly", 12, true)
        case .falling: return ("fall", 1, true)
        case .held: return ("held", 8, true)
        case .landing: return ("land", 6, false)
        case .hop: return ("hop", 4, false)
        case .peck: return ("peck", 3, false)
        case .petted: return ("petted", 4, true)
        case .samba: return ("samba", 8, true)
        case .finish: return ("finish", 6, false)
        case .sleeping: return ("sleeping", 1, true)
        case .idle where bubble.isTyping:
            return ("talk", 8, true)
        case .idle:
            let mood = env.pet.mood
            switch mood {
            case .waiting, .working, .hot, .tired: return (mood.rawValue, mood.fps, true)
            default: return ("idle", 2, true)
            }
        }
    }

    private func render(_ now: Date) {
        let (name, fps, loops) = animation()
        let frames = PetArt.desktopFrames[name] ?? PetArt.frames[name] ?? []
        guard !frames.isEmpty else { return }
        let raw = Int(elapsed * fps)
        let index = loops ? raw % frames.count : min(raw, frames.count - 1)
        let key = "\(name)-\(index)-\(facingRight)-\(PetArt.outfit.hashValue)"
        guard key != shownKey else { return }
        shownKey = key
        shownFrame = frames[index]
        sprite?.show(frames[index], facingRight: facingRight)
    }

    /// Clique só pega no corvo: nas partes transparentes da janela ele passa para o que está embaixo.
    private func updateClickThrough() {
        guard let panel else { return }
        if drag != nil { setIgnoresMouse(false); return }
        let mouse = NSEvent.mouseLocation
        guard panel.frame.contains(mouse) else { setIgnoresMouse(true); return }
        let col = Int((mouse.x - panel.frame.minX) / scale), row = Int((panel.frame.maxY - mouse.y) / scale)
        var opaque = false
        for r in (row - 1)...(row + 1) where shownFrame.indices.contains(r) {
            let line = Array(shownFrame[r])
            for c in (col - 1)...(col + 1) {
                let x = facingRight ? c : PetArt.width - 1 - c
                if line.indices.contains(x), line[x] != "." { opaque = true }
            }
        }
        setIgnoresMouse(!opaque)
    }

    /// Só mexe quando muda (cada mudança é uma mensagem para o WindowServer).
    private func setIgnoresMouse(_ ignores: Bool) {
        guard let panel, panel.ignoresMouseEvents != ignores else { return }
        panel.ignoresMouseEvents = ignores
    }

    // MARK: Posição salva

    private func restoredPosition() -> CGPoint {
        let defaults = UserDefaults.standard
        if let x = defaults.object(forKey: "desktopPet.x") as? Double, let y = defaults.object(forKey: "desktopPet.y") as? Double {
            let point = CGPoint(x: x, y: y)
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -2, dy: -2).contains(point) }) { return point }
        }
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? Self.fallbackFrame
        return CGPoint(x: frame.maxX - 160, y: frame.minY + 200)
    }

    private func savePosition(force: Bool) {
        guard force || hypot(position.x - savedPosition.x, position.y - savedPosition.y) > 40, isStanding else { return }
        savedPosition = position
        UserDefaults.standard.set(Double(position.x), forKey: "desktopPet.x")
        UserDefaults.standard.set(Double(position.y), forKey: "desktopPet.y")
    }
}

/// Painel sem borda que nunca vira a janela ativa (não rouba o foco do app em que você está).
final class DesktopPetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Desenha o quadro atual (grade 24×18, pixels nítidos) e repassa os cliques ao `DesktopPet`.
final class DesktopPetView: NSView {
    weak var owner: DesktopPet?
    private static var cache: [String: CGImage] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.magnificationFilter = .nearest
        layer?.contentsGravity = .resize
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ frame: [String], facingRight: Bool) {
        let key = frame.joined() + (facingRight ? ">" : "<")
        let image = Self.cache[key] ?? PetSprites.cgImage(frame, flipped: !facingRight)
        Self.cache[key] = image
        if Self.cache.count > 400 { Self.cache.removeAll() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) { owner?.mouseDown(event) }
    override func mouseDragged(with event: NSEvent) { owner?.mouseDragged(event) }
    override func mouseUp(with event: NSEvent) { owner?.mouseUp(event) }
    override func rightMouseDown(with event: NSEvent) { owner?.rightMouseDown(event) }
}
