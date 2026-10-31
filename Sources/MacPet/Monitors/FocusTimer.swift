import Foundation

/// Modo foco (pomodoro): 25 min de foco, 5 de pausa, 15 a cada 4 focos (ajustáveis nas Preferências).
/// No foco, o corvo cochila e as notificações que podem esperar ficam guardadas até a pausa; o que é urgente
/// (o Claude pedindo permissão, servidor que caiu) continua chegando. Sobrevive ao MacPet reiniciar.
@MainActor
final class FocusTimer: ObservableObject {
    enum Phase: String { case focus, shortBreak, longBreak }

    /// Notificação segurada durante o foco, entregue em resumo na pausa.
    struct Held: Equatable {
        let title: String
        let body: String
        let finished: Bool
    }

    /// nil: parado.
    @Published private(set) var phase: Phase?
    @Published private(set) var endsAt: Date?
    /// Pausado no meio: quanto faltava.
    @Published private(set) var pausedRemaining: TimeInterval?
    @Published private(set) var completedToday = 0
    @Published private(set) var held: [Held] = []
    /// Atualizado a cada segundo enquanto roda (para as telas redesenharem o relógio).
    @Published private(set) var now = Date()

    /// Mudou de fase (início do foco, da pausa, fim da pausa ou parado): o corvo reage.
    var onPhaseChange: ((_ from: Phase?, _ to: Phase?, _ held: [Held]) -> Void)?

    private let settings: AppSettings
    private let notifier: Notifier
    private let defaults = UserDefaults.standard
    private var timer: Timer?

    init(settings: AppSettings, notifier: Notifier) {
        self.settings = settings
        self.notifier = notifier
        restore()
    }

    var isActive: Bool { phase != nil }
    var isPaused: Bool { pausedRemaining != nil }
    var isFocusing: Bool { phase == .focus && !isPaused }

    var duration: TimeInterval {
        switch phase {
        case .focus: Double(settings.focusMinutes) * 60
        case .shortBreak: Double(settings.breakMinutes) * 60
        case .longBreak: Double(settings.longBreakMinutes) * 60
        case nil: 0
        }
    }

    var remaining: TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        return max(0, (endsAt ?? now).timeIntervalSince(now))
    }

    var progress: Double { duration > 0 ? 1 - remaining / duration : 0 }

    /// "18:42"
    var clock: String {
        let seconds = Int(remaining.rounded(.up))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var phaseLabel: String {
        switch phase {
        case .focus: isPaused ? "Foco pausado" : "Foco"
        case .shortBreak: "Pausa"
        case .longBreak: "Pausa longa"
        case nil: "Modo foco"
        }
    }

    // MARK: Controles

    func startFocus() { begin(.focus) }

    func pause() {
        guard isActive, !isPaused else { return }
        pausedRemaining = remaining
        endsAt = nil
        save()
    }

    func resume() {
        guard let pausedRemaining else { return }
        endsAt = Date().addingTimeInterval(pausedRemaining)
        self.pausedRemaining = nil
        save()
        startTicking()
    }

    /// Termina a fase agora (foco vira pausa; pausa acaba).
    func skip() {
        guard isActive else { return }
        advance(early: true)
    }

    func stop() {
        let previous = phase
        phase = nil
        endsAt = nil
        pausedRemaining = nil
        timer?.invalidate()
        let released = held
        held = []
        save()
        onPhaseChange?(previous, nil, released)
    }

    // MARK: Notificações

    /// Chamado pelo Notifier: true = segura (é foco e a notificação pode esperar).
    func shouldHold(id: String, title: String, body: String) -> Bool {
        guard isFocusing, settings.focusHoldNotifications else { return false }
        let urgent = id.hasSuffix("-waiting") || id.hasPrefix("chat-") || id.hasPrefix("server-")
        guard !urgent else { return false }
        held.append(Held(title: title, body: body, finished: id.hasSuffix("-stop")))
        return true
    }

    // MARK: Fases

    private func begin(_ next: Phase) {
        let previous = phase
        phase = next
        pausedRemaining = nil
        endsAt = Date().addingTimeInterval(duration)
        now = Date()
        save()
        startTicking()
        let released = next == .focus ? [] : held
        if next != .focus { held = [] }
        onPhaseChange?(previous, next, released)
    }

    private func advance(early: Bool = false) {
        switch phase {
        case .focus:
            if !early { completedToday += 1 }
            let long = settings.longBreakEvery > 0 && completedToday > 0 && completedToday % settings.longBreakEvery == 0 && !early
            begin(long ? .longBreak : .shortBreak)
            notifier.post(id: "focus-break", title: long ? "Pausa longa" : "Pausa",
                          body: early ? "Foco encerrado. Respira um pouco." : "\(completedToday)º foco do dia feito. Levanta, bebe uma água.",
                          mood: .celebrating)
        case .shortBreak, .longBreak:
            let previous = phase
            phase = nil
            endsAt = nil
            timer?.invalidate()
            save()
            onPhaseChange?(previous, nil, [])
            if !early {
                notifier.post(id: "focus-back", title: "Pausa acabou", body: "Bora para o próximo foco? Clique no corvo ou no popover para começar.",
                              mood: .waiting)
            }
        case nil:
            break
        }
    }

    private func startTicking() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.now = Date()
                self.resetCountIfNewDay()
                if !self.isPaused, let endsAt = self.endsAt, self.now >= endsAt { self.advance() }
            }
        }
    }

    // MARK: Guardar (o foco continua se o MacPet reiniciar)

    private func save() {
        defaults.set(phase?.rawValue, forKey: "focus.phase")
        defaults.set(endsAt?.timeIntervalSince1970, forKey: "focus.endsAt")
        defaults.set(pausedRemaining, forKey: "focus.paused")
        defaults.set(completedToday, forKey: "focus.count")
        defaults.set(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970, forKey: "focus.countDay")
    }

    private func restore() {
        let day = defaults.double(forKey: "focus.countDay")
        completedToday = day == Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 ? defaults.integer(forKey: "focus.count") : 0
        guard let raw = defaults.string(forKey: "focus.phase"), let saved = Phase(rawValue: raw) else { return }
        phase = saved
        if let paused = defaults.object(forKey: "focus.paused") as? Double {
            pausedRemaining = paused
        } else if let end = defaults.object(forKey: "focus.endsAt") as? Double {
            endsAt = Date(timeIntervalSince1970: end)
        }
        startTicking()
    }

    private func resetCountIfNewDay() {
        let day = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        if defaults.double(forKey: "focus.countDay") != day {
            completedToday = 0
            defaults.set(day, forKey: "focus.countDay")
            defaults.set(0, forKey: "focus.count")
        }
    }
}
