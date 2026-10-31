import Foundation

/// Horário de pico do Claude: em dias úteis, de manhã no horário do Pacífico, a janela de 5h do plano
/// é consumida mais rápido (a semanal não muda). A Anthropic anunciou em mar/2026 o intervalo 5h–11h PT;
/// como a regra já mudou antes, o intervalo é ajustável nas Preferências.
@MainActor
final class PeakMonitor: ObservableObject {
    @Published private(set) var isPeak = false
    /// Fim do pico atual, ou começo do próximo.
    @Published private(set) var boundary: Date?

    private let settings: AppSettings
    private let notifier: Notifier
    private var timer: Timer?
    private nonisolated static let pacific = TimeZone(identifier: "America/Los_Angeles")!

    init(settings: AppSettings, notifier: Notifier) {
        self.settings = settings
        self.notifier = notifier
    }

    func start() {
        update(notify: false)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(notify: true) }
        }
    }

    /// Recalcula agora (ex.: depois de mudar o intervalo nas Preferências).
    func refresh() { update(notify: false) }

    private func update(notify: Bool) {
        guard settings.peakEnabled else {
            isPeak = false
            boundary = nil
            return
        }
        let state = Self.state(at: Date(), start: settings.peakStartHour, end: settings.peakEndHour)
        let started = state.isPeak && !isPeak
        isPeak = state.isPeak
        boundary = state.boundary
        if started, notify, settings.peakNotify, let end = state.boundary {
            notifier.post(id: "peak-\(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)",
                          title: "Começou o horário de pico do Claude",
                          subtitle: "Até \(end.formatted(date: .omitted, time: .shortened))",
                          body: "A janela de 5h do plano gasta mais rápido agora. Tarefas pesadas e workflows rendem mais depois desse horário.",
                          mood: .hot)
        }
    }

    /// Em pico agora? E quando isso muda (fim do pico atual ou começo do próximo).
    nonisolated static func state(at date: Date, start: Int, end: Int) -> (isPeak: Bool, boundary: Date?) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacific
        func window(on day: Date) -> (Date, Date)? {
            let weekday = calendar.component(.weekday, from: day)
            guard (2...6).contains(weekday),  // segunda a sexta, no horário do Pacífico
                  let from = calendar.date(bySettingHour: start, minute: 0, second: 0, of: day),
                  let to = calendar.date(bySettingHour: end, minute: 0, second: 0, of: day) else { return nil }
            return (from, to)
        }
        let today = calendar.startOfDay(for: date)
        if let (from, to) = window(on: today), date >= from, date < to { return (true, to) }
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today), let (from, _) = window(on: day) else { continue }
            if from > date { return (false, from) }
        }
        return (false, nil)
    }

    /// "9:00–15:00" no fuso do Mac, para mostrar nas Preferências.
    nonisolated static func localRange(start: Int, end: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacific
        let day = calendar.startOfDay(for: Date())
        guard let from = calendar.date(bySettingHour: start, minute: 0, second: 0, of: day),
              let to = calendar.date(bySettingHour: end, minute: 0, second: 0, of: day) else { return "" }
        return "\(from.formatted(date: .omitted, time: .shortened))–\(to.formatted(date: .omitted, time: .shortened))"
    }
}
