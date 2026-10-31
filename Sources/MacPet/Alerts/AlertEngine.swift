import Foundation

enum AlertMetric: String, Codable, CaseIterable, Identifiable {
    case cpu, memory, disk, temperature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memória"
        case .disk: "Disco"
        case .temperature: "Temperatura"
        }
    }

    var unit: String { self == .temperature ? "°C" : "%" }

    var range: ClosedRange<Double> { self == .temperature ? 50...110 : 10...100 }

    /// Item da barra que fica vermelho quando a regra dispara.
    var menuMetric: Metric {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .disk: .disk
        case .temperature: .temperature
        }
    }

    func value(in snapshot: SystemSnapshot) -> Double? {
        switch self {
        case .cpu: snapshot.cpu * 100
        case .memory: snapshot.memory.fraction * 100
        case .disk: snapshot.disk.total > 0 ? snapshot.disk.fraction * 100 : nil
        case .temperature: snapshot.temperature
        }
    }
}

struct AlertRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var metric: AlertMetric
    var threshold: Double
    /// Quanto tempo o valor precisa ficar acima do limite para disparar (segundos).
    var duration: TimeInterval
    var enabled = true

    static let defaults: [AlertRule] = [
        AlertRule(metric: .temperature, threshold: 90, duration: 60),
        AlertRule(metric: .memory, threshold: 90, duration: 120),
        AlertRule(metric: .disk, threshold: 95, duration: 0),
        AlertRule(metric: .cpu, threshold: 90, duration: 300, enabled: false),
    ]
}

/// Avalia as regras a cada amostra. Uma regra só volta a notificar depois do cooldown.
@MainActor
final class AlertEngine: ObservableObject {
    @Published private(set) var breached: Set<Metric> = []

    private let settings: AppSettings
    private let notifier: Notifier
    private var breachSince: [UUID: Date] = [:]
    private var lastFired: [UUID: Date] = [:]
    private let cooldown: TimeInterval = 15 * 60

    init(settings: AppSettings, notifier: Notifier) {
        self.settings = settings
        self.notifier = notifier
    }

    func evaluate(_ snapshot: SystemSnapshot) {
        var nowBreached: Set<Metric> = []
        for rule in settings.alertRules where rule.enabled {
            guard let value = rule.metric.value(in: snapshot), value >= rule.threshold else {
                breachSince[rule.id] = nil
                continue
            }
            let since = breachSince[rule.id] ?? snapshot.date
            breachSince[rule.id] = since
            guard snapshot.date.timeIntervalSince(since) >= rule.duration else { continue }

            nowBreached.insert(rule.metric.menuMetric)
            if let last = lastFired[rule.id], snapshot.date.timeIntervalSince(last) < cooldown { continue }
            lastFired[rule.id] = snapshot.date
            notify(rule, value: value)
        }
        if nowBreached != breached {
            breached = nowBreached
        }
    }

    private func notify(_ rule: AlertRule, value: Double) {
        let current = "\(Int(value.rounded()))\(rule.metric.unit)"
        let limit = "\(Int(rule.threshold))\(rule.metric.unit)"
        notifier.post(
            id: "alert-\(rule.id)",
            title: "\(rule.metric.title) em \(current)",
            body: "Acima do limite de \(limit)" + (rule.duration > 0 ? " há mais de \(Int(rule.duration / 60)) min." : ".")
        )
    }
}
