import AppKit
import Combine
import IOKit.pwr_mgt

/// Um horário em que a tela fica ligada: dias da semana e um intervalo (pode virar a noite, ex.: 22h às 2h).
struct AwakeSchedule: Codable, Identifiable, Equatable {
    var id = UUID()
    var enabled = true
    /// Dias em que o horário começa, como no Calendar: 1 = domingo … 7 = sábado.
    var days: Set<Int> = [2, 3, 4, 5, 6]
    /// Minutos desde a meia-noite. Início igual ao fim vale o dia inteiro.
    var start = 9 * 60
    var end = 18 * 60

    /// Intervalos concretos deste horário perto de `date` (de ontem até a próxima semana).
    func intervals(around date: Date, calendar: Calendar = .current) -> [DateInterval] {
        guard enabled, !days.isEmpty else { return [] }
        let today = calendar.startOfDay(for: date)
        return (-1...7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  days.contains(calendar.component(.weekday, from: day)),
                  let from = calendar.date(byAdding: .minute, value: start, to: day) else { return nil }
            let length = end > start ? end - start : end + 24 * 60 - start
            guard let to = calendar.date(byAdding: .minute, value: length, to: from) else { return nil }
            return DateInterval(start: from, end: to)
        }
    }

    static func time(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
}

/// Mantém a tela ligada (e o Mac acordado) enquanto há um pedido manual ou um horário agendado ativo.
/// Usa a mesma trava de energia de um player de vídeo: a tela não apaga, o descanso de tela não entra e o
/// Mac não bloqueia por inatividade. Fechar a tampa ainda põe o Mac para dormir.
@MainActor
final class KeepAwake: ObservableObject {
    enum Source: Equatable { case manual, schedule, focus }

    @Published private(set) var isActive = false
    @Published private(set) var source: Source?
    /// Quando desliga sozinho (nil: só quando você desligar).
    @Published private(set) var activeUntil: Date?
    /// Próximo horário agendado, quando desligado.
    @Published private(set) var nextStart: Date?
    /// Modo foco pedindo a tela ligada (ver FocusTimer).
    var focusHold = false {
        didSet { if focusHold != oldValue { update() } }
    }
    /// Fim do pedido manual (`.distantFuture` = sem limite).
    @Published private(set) var manualUntil: Date? {
        didSet { defaults.set(manualUntil?.timeIntervalSince1970, forKey: "awake.manualUntil") }
    }

    private let settings: AppSettings
    private let defaults = UserDefaults.standard
    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?
    private var observers: [AnyCancellable] = []
    /// Você desligou no meio de um horário agendado: ele só volta no próximo.
    private var skipUntil: Date? {
        didSet { defaults.set(skipUntil?.timeIntervalSince1970, forKey: "awake.skipUntil") }
    }

    init(settings: AppSettings) {
        self.settings = settings
        manualUntil = (defaults.object(forKey: "awake.manualUntil") as? Double).map(Date.init(timeIntervalSince1970:))
        skipUntil = (defaults.object(forKey: "awake.skipUntil") as? Double).map(Date.init(timeIntervalSince1970:))
    }

    func start() {
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        settings.$awakeSchedules.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }.store(in: &observers)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }.store(in: &observers)
    }

    /// Liga por um tempo (nil: até você desligar).
    func turnOn(for duration: TimeInterval?) {
        manualUntil = duration.map { Date().addingTimeInterval($0) } ?? .distantFuture
        skipUntil = nil
        update()
    }

    /// Desliga agora, inclusive um horário agendado em andamento (que volta no próximo).
    func turnOff() {
        manualUntil = nil
        if let current = activeScheduleWindow(at: Date()) { skipUntil = current.end }
        update()
    }

    private func update() {
        let now = Date()
        if let until = manualUntil, until <= now { manualUntil = nil }
        if let skip = skipUntil, skip <= now { skipUntil = nil }

        let scheduled = skipUntil == nil ? activeScheduleWindow(at: now) : nil
        if let manual = manualUntil {
            source = .manual
            // Manual e agendado ao mesmo tempo: vale o que for até mais tarde.
            let manualEnd: Date? = manual == .distantFuture ? nil : manual
            activeUntil = manualEnd.map { end in max(end, scheduled?.end ?? end) }
        } else if let scheduled {
            source = .schedule
            activeUntil = scheduled.end
        } else if focusHold {
            source = .focus
            activeUntil = nil
        } else {
            source = nil
            activeUntil = nil
        }
        isActive = source != nil
        nextStart = isActive ? nil : allIntervals(around: now).map(\.start).filter { $0 > now && $0 >= (skipUntil ?? now) }.min()
        hold(isActive)
    }

    /// O horário agendado em andamento, emendando horários que se encostam (ex.: 9h–12h e 12h–18h).
    private func activeScheduleWindow(at date: Date) -> DateInterval? {
        let intervals = allIntervals(around: date).sorted { $0.start < $1.start }
        guard var window = intervals.first(where: { $0.contains(date) && $0.end > date }) else { return nil }
        for interval in intervals where interval.start <= window.end && interval.end > window.end {
            window = DateInterval(start: window.start, end: interval.end)
        }
        return window
    }

    private func allIntervals(around date: Date) -> [DateInterval] {
        settings.awakeSchedules.flatMap { $0.intervals(around: date) }
    }

    private func hold(_ on: Bool) {
        if on, assertion == 0 {
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "MacPet: manter a tela ligada" as CFString, &assertion)
            if result != kIOReturnSuccess {
                NSLog("MacPet: falha ao manter a tela ligada (\(result))")
                assertion = 0
            }
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    /// "Tela ligada até 18:00", "Tela ligada sem limite".
    var statusText: String {
        guard isActive else {
            if let nextStart { return "Desligado · liga \(Self.when(nextStart))" }
            return "Desligado"
        }
        if source == .focus { return "Tela ligada durante o foco" }
        guard let activeUntil else { return "Tela ligada até você desligar" }
        return "Tela ligada até \(Self.when(activeUntil))"
    }

    /// "18:00", "amanhã 09:00", "seg 09:00".
    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInTomorrow(date) { return "amanhã \(time)" }
        let weekday = date.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "pt_BR")))
        return "\(weekday.replacingOccurrences(of: ".", with: "")) \(time)"
    }
}
