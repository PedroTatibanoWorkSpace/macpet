import Foundation
import SQLite3

enum Series: String, CaseIterable {
    case cpu, memory, disk, temperature, netIn, netOut

    func value(in snapshot: SystemSnapshot) -> Double? {
        switch self {
        case .cpu: snapshot.cpu * 100
        case .memory: snapshot.memory.fraction * 100
        case .disk: snapshot.disk.total > 0 ? snapshot.disk.fraction * 100 : nil
        case .temperature: snapshot.temperature
        case .netIn: snapshot.netIn
        case .netOut: snapshot.netOut
        }
    }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case hour = "1h", day = "24h", week = "7d"

    var id: String { rawValue }

    var interval: TimeInterval {
        switch self {
        case .hour: 3600
        case .day: 86_400
        case .week: 7 * 86_400
        }
    }
}

struct HistoryPoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// Última hora em memória (todas as amostras) e médias por minuto em SQLite (7 dias).
final class HistoryStore {
    private var recent: [Series: [HistoryPoint]] = [:]
    private var minuteSums: [Series: (sum: Double, count: Int)] = [:]
    private var currentMinute: Int?
    private var db: OpaquePointer?
    private var lastPrune = Date.distantPast

    init() {
        openDatabase()
    }

    deinit {
        sqlite3_close(db)
    }

    func record(_ snapshot: SystemSnapshot) {
        let minute = Int(snapshot.date.timeIntervalSince1970 / 60)
        if let currentMinute, currentMinute != minute {
            flushMinute(currentMinute)
        }
        currentMinute = minute

        let cutoff = snapshot.date.addingTimeInterval(-HistoryRange.hour.interval)
        for series in Series.allCases {
            guard let value = series.value(in: snapshot) else { continue }
            var points = recent[series, default: []]
            points.append(HistoryPoint(date: snapshot.date, value: value))
            if let first = points.first, first.date < cutoff {
                points.removeAll { $0.date < cutoff }
            }
            recent[series] = points

            let acc = minuteSums[series, default: (0, 0)]
            minuteSums[series] = (acc.sum + value, acc.count + 1)
        }
    }

    func points(_ series: Series, range: HistoryRange) -> [HistoryPoint] {
        if range == .hour {
            return recent[series] ?? []
        }
        let since = Int(Date().addingTimeInterval(-range.interval).timeIntervalSince1970 / 60)
        // Na semana agrega em blocos de 10 minutos para o gráfico não ficar pesado.
        let bucket = range == .week ? 10 : 1
        let sql = """
            SELECT (minute / \(bucket)) * \(bucket) AS m, AVG(value) FROM samples
            WHERE series = ? AND minute >= ? GROUP BY m ORDER BY m
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, series.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, Int64(since))

        var result: [HistoryPoint] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let minute = sqlite3_column_int64(statement, 0)
            let value = sqlite3_column_double(statement, 1)
            result.append(HistoryPoint(date: Date(timeIntervalSince1970: TimeInterval(minute * 60)), value: value))
        }
        return result
    }

    private func flushMinute(_ minute: Int) {
        defer { minuteSums = [:] }
        guard db != nil else { return }
        exec("BEGIN")
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO samples (series, minute, value) VALUES (?, ?, ?)", -1, &statement, nil) == SQLITE_OK {
            for (series, acc) in minuteSums where acc.count > 0 {
                sqlite3_bind_text(statement, 1, series.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(statement, 2, Int64(minute))
                sqlite3_bind_double(statement, 3, acc.sum / Double(acc.count))
                sqlite3_step(statement)
                sqlite3_reset(statement)
            }
            sqlite3_finalize(statement)
        }
        exec("COMMIT")

        if Date().timeIntervalSince(lastPrune) > 3600 {
            let cutoff = Int(Date().addingTimeInterval(-HistoryRange.week.interval).timeIntervalSince1970 / 60)
            exec("DELETE FROM samples WHERE minute < \(cutoff)")
            lastPrune = Date()
        }
    }

    private func openDatabase() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("history.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            db = nil
            return
        }
        exec("PRAGMA journal_mode=WAL")
        exec("""
            CREATE TABLE IF NOT EXISTS samples (
                series TEXT NOT NULL, minute INTEGER NOT NULL, value REAL NOT NULL,
                PRIMARY KEY (series, minute)
            )
            """)
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
