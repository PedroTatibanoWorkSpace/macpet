import Foundation

struct RateWindow: Equatable {
    var usedPercentage: Double
    var resetsAt: Date

    init(usedPercentage: Double, resetsAt: Date) {
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    init?(_ json: Any?) {
        guard let json = json as? [String: Any],
              let used = (json["used_percentage"] as? Double) ?? (json["used_percentage"] as? Int).map(Double.init)
        else { return nil }
        usedPercentage = used
        let reset = (json["resets_at"] as? Double) ?? (json["resets_at"] as? Int).map(Double.init) ?? 0
        resetsAt = Date(timeIntervalSince1970: reset)
    }

    /// Depois do reset o percentual antigo não vale mais.
    var isExpired: Bool { resetsAt < Date() }
    var fraction: Double { isExpired ? 0 : min(max(usedPercentage / 100, 0), 1) }
}

/// Limites oficiais do plano (janela de 5h e semanal). Fontes: o `/usage` do Claude Code (consultado
/// periodicamente, sem custo), o `rate_limit_event` de cada resposta nos chats e a statusLine do terminal.
/// A última leitura fica em ~/.macpet/limits.json para sobreviver a reinícios do app.
@MainActor
final class RateLimitStore: ObservableObject {
    @Published private(set) var fiveHour: RateWindow?
    @Published private(set) var sevenDay: RateWindow?
    @Published private(set) var updatedAt: Date?
    /// Semana só do Fable (o `/usage` informa separado).
    @Published private(set) var fableWeek: RateWindow?
    /// "What's contributing to your usage?" do `/usage`: o que mais pesa nas últimas 24h.
    @Published private(set) var usageTips: [String] = []
    private var refreshing = false

    private let fileURL = MacPetPaths.support.appendingPathComponent("limits.json")

    init() {
        load()
    }

    var hasData: Bool { fiveHour != nil || sevenDay != nil }

    /// Perto de estourar: deixa o corvo cansado.
    var isNearLimit: Bool {
        (fiveHour?.fraction ?? 0) >= 0.9 || (sevenDay?.fraction ?? 0) >= 0.95
    }

    func update(fromStatusLine event: [String: Any]) {
        guard let limits = event["rate_limits"] as? [String: Any] else { return }
        apply(limits, at: Date())
    }

    /// `rate_limit_event` do modo stream-json (chats do MacPet, que não passam pela statusLine):
    /// {"unifiedWindows": {"five_hour": {"utilization": 0.02, "resetsAt": 1793276400}, "seven_day": {...}}}
    func update(fromRateLimitEvent info: [String: Any]) {
        guard let windows = info["unifiedWindows"] as? [String: Any] else { return }
        var limits: [String: Any] = [:]
        for key in ["five_hour", "seven_day"] {
            guard let window = windows[key] as? [String: Any],
                  let utilization = (window["utilization"] as? Double) ?? (window["utilization"] as? Int).map(Double.init) else { continue }
            limits[key] = ["used_percentage": utilization * 100, "resets_at": window["resetsAt"] ?? 0]
        }
        guard !limits.isEmpty else { return }
        apply(limits, at: Date())
        save()
    }

    /// Consulta o `/usage` (roda local, não gasta tokens). Ignora se já houver uma consulta recente.
    func refresh(ifOlderThan age: TimeInterval = 0) {
        guard !refreshing, Date().timeIntervalSince(updatedAt ?? .distantPast) >= age, let claude = ClaudeCLI.executable else { return }
        refreshing = true
        Task {
            defer { refreshing = false }
            let input = #"{"type":"user","message":{"role":"user","content":"/usage"}}"# + "\n"
            let result = await Shell.run(claude, ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                                                  "--verbose", "--no-session-persistence"],
                                         in: FileManager.default.homeDirectoryForCurrentUser.path, input: input)
            let text = result.stdout.split(separator: "\n").lazy
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .first { $0["type"] as? String == "result" }?["result"] as? String
            guard let text else { return }
            apply(usage: text)
        }
    }

    /// "Current session: 6% used · resets Oct 29 at 9:19am (America/Sao_Paulo)"
    private func apply(usage text: String) {
        func window(_ prefix: String) -> RateWindow? {
            guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }).map(String.init),
                  let match = line.firstMatch(of: #/: (\d+(?:\.\d+)?)% used(?: · resets (.+?))?(?: \(([^)]+)\))?$/#),
                  let used = Double(match.1) else { return nil }
            return RateWindow(usedPercentage: used, resetsAt: match.2.flatMap { Self.parseReset(String($0), zone: match.3.map(String.init)) } ?? .distantFuture)
        }
        let five = window("Current session")
        let seven = window("Current week (all models)")
        guard five != nil || seven != nil else { return }
        fiveHour = five ?? fiveHour
        sevenDay = seven ?? sevenDay
        fableWeek = window("Current week (Fable)")
        updatedAt = Date()
        // Dicas do bloco das últimas 24h: linhas "89%  Start fresh when you switch tasks · run /clear".
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let start = lines.firstIndex(where: { $0.hasPrefix("Last 24h") }) {
            usageTips = Array(lines[(start + 1)...].prefix(while: { (line: String) in !line.isEmpty && !line.hasPrefix("Last ") }))
        }
        save()
    }

    /// "Oct 29 at 9:19am" ou "9:19am" (hoje), no fuso indicado.
    static func parseReset(_ text: String, zone: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .current
        formatter.defaultDate = Calendar.current.startOfDay(for: Date())
        for format in ["MMM d 'at' h:mma", "MMM d 'at' ha", "h:mma", "ha"] {
            formatter.dateFormat = format
            if var date = formatter.date(from: text) {
                // Sem ano no texto: um reset é sempre no futuro.
                if date < Date().addingTimeInterval(-86_400), let next = Calendar.current.date(byAdding: .year, value: 1, to: date) { date = next }
                return date
            }
        }
        return nil
    }

    private func save() {
        var limits: [String: Any] = [:]
        if let fiveHour { limits["five_hour"] = ["used_percentage": fiveHour.usedPercentage, "resets_at": fiveHour.resetsAt.timeIntervalSince1970] }
        if let sevenDay { limits["seven_day"] = ["used_percentage": sevenDay.usedPercentage, "resets_at": sevenDay.resetsAt.timeIntervalSince1970] }
        let record: [String: Any] = ["updated_at": Date().timeIntervalSince1970, "rate_limits": limits]
        if let data = try? JSONSerialization.data(withJSONObject: record) {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = json["rate_limits"] as? [String: Any] else { return }
        apply(limits, at: (json["updated_at"] as? Double).map { Date(timeIntervalSince1970: $0) })
    }

    private func apply(_ limits: [String: Any], at date: Date?) {
        let five = RateWindow(limits["five_hour"])
        let seven = RateWindow(limits["seven_day"])
        if five != fiveHour { fiveHour = five }
        if seven != sevenDay { sevenDay = seven }
        updatedAt = date
    }
}
