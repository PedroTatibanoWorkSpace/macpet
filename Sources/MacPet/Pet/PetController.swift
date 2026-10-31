import AppKit
import Combine
import SwiftUI

/// Decide o humor do pet a partir das sessões do Claude e da temperatura do Mac.
@MainActor
final class PetModel: ObservableObject {
    @Published private(set) var mood: PetMood = .idle

    private let claude: ClaudeSessionStore
    private let monitor: SystemMonitor
    private let limits: RateLimitStore
    private var cancellables: Set<AnyCancellable> = []
    private var timer: Timer?

    init(claude: ClaudeSessionStore, monitor: SystemMonitor, limits: RateLimitStore) {
        self.claude = claude
        self.monitor = monitor
        self.limits = limits
        claude.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.update() }
        }.store(in: &cancellables)
        // Reavalia periodicamente para sair de "comemorando" e entrar em "dormindo".
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    var moodDescription: String {
        let working = claude.workingCount
        switch mood {
        case .waiting:
            let names = claude.ordered.filter { $0.state == .waiting }.map(\.projectName)
            return "Esperando você em \(names.joined(separator: ", "))"
        case .celebrating:
            return "Tarefa concluída!"
        case .hot:
            return "Está quente aqui… \(Format.temperature(monitor.snapshot.temperature))"
                + (working > 0 ? " · \(working) trabalhando" : "")
        case .working:
            return working == 1 ? "1 sessão trabalhando" : "\(working) sessões trabalhando"
        case .tired:
            let windows = [("5h", limits.fiveHour), ("semana", limits.sevenDay)]
                .compactMap { name, window in window.map { (name, $0) } }
                .filter { !$0.1.isExpired }
                .max { $0.1.fraction < $1.1.fraction }
            guard let (name, window) = windows else { return "Cansado…" }
            return "Cansado… limite de \(name) em \(Int(window.usedPercentage))% (reinicia em \(Format.until(window.resetsAt)))"
        case .sleeping:
            return "Dormindo… nenhuma atividade do Claude"
        case .idle:
            return claude.sessions.isEmpty ? "De boa. Nenhuma sessão ativa." : "Esperando o próximo prompt"
        }
    }

    private func update() {
        let next = computeMood()
        if next != mood { mood = next }
    }

    private func computeMood() -> PetMood {
        let now = Date()
        let snapshot = monitor.snapshot
        if claude.waitingCount > 0 { return .waiting }
        if let finished = claude.lastFinished, now.timeIntervalSince(finished) < 8 { return .celebrating }
        if (snapshot.temperature ?? 0) >= 90 || snapshot.thermal == .serious || snapshot.thermal == .critical { return .hot }
        if limits.isNearLimit { return .tired }
        if claude.workingCount > 0 { return .working }
        if claude.sessions.isEmpty, now.timeIntervalSince(claude.lastActivity) > 10 * 60 { return .sleeping }
        return .idle
    }
}

/// Item da barra com o pet animado e o popover das sessões.
@MainActor
final class PetController: NSObject, NSPopoverDelegate {
    private let env: AppEnvironment
    private var item: NSStatusItem?
    private var popover: NSPopover?
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var started = Date()
    private var lastKey = ""
    private var cache: [String: NSImage] = [:]

    init(env: AppEnvironment) {
        self.env = env
        super.init()
    }

    func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "macpet.pet"
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.imagePosition = .imageOnly
        self.item = item
        lastKey = ""
        tick()
    }

    /// Acorda no ritmo da animação atual (2 a 6 quadros por segundo), não mais que isso.
    private func schedule(fps: Double) {
        let interval = 1 / max(fps, 1)
        guard interval != timerInterval else { return }
        timerInterval = interval
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func remove() {
        timer?.invalidate()
        timer = nil
        timerInterval = 0
        popover?.close()
        popover = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    private func tick() {
        guard let button = item?.button else { return }
        let mood = env.pet.mood
        schedule(fps: mood.fps)
        let frames = mood.frames
        guard !frames.isEmpty else { return }
        let index = Int(Date().timeIntervalSince(started) * mood.fps) % frames.count
        let awake = env.awake.isActive
        updateFocusTitle(button)
        let key = "\(mood.rawValue)-\(index)-\(awake)-\(PetArt.outfit.hashValue)"
        guard key != lastKey else { return }
        lastKey = key
        let image = cache[key] ?? Self.sprite(frames[index], awake: awake)
        cache[key] = image
        button.image = image
        button.toolTip = awake ? "\(env.pet.moodDescription)\n\(env.awake.statusText)" : env.pet.moodDescription
    }

    /// No modo foco, os minutos que faltam ao lado do corvo.
    private func updateFocusTitle(_ button: NSStatusBarButton) {
        let focus = env.focus
        let title = focus.isActive ? "\(Int((focus.remaining / 60).rounded(.up)))m" : ""
        guard button.title != title else { return }
        button.title = title
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeft
    }

    /// Com a tela sendo mantida ligada, um ponto no brilho da pena no canto de cima do corvo.
    private static func sprite(_ frame: [String], awake: Bool) -> NSImage {
        let base = PetSprites.image(frame, scale: 1)
        guard awake else { return base }
        return NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            NSColor(Theme.sheenStrong).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 5, height: 5)).fill()
            return true
        }
    }

    /// Popover fechado é descartado: guardado, o corvo animado dele continuaria rodando escondido.
    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        let popover = self.popover ?? {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            let hosting = NSHostingController(rootView: env.inject(PetView().mpDesignSystem()))
            hosting.sizingOptions = [.preferredContentSize]
            popover.contentViewController = hosting
            popover.delegate = self
            return popover
        }()
        self.popover = popover
        env.hooks.refresh()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
