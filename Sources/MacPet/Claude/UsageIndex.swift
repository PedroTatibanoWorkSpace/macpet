import Foundation

struct DayUsage: Identifiable {
    let day: Date
    let cost: Double
    let tokens: Int
    var id: Date { day }
}

struct ProjectUsage: Identifiable {
    let cwd: String
    let sessions: Int
    let tokens: Int
    let cost: Double
    var id: String { cwd }
    var name: String { URL(fileURLWithPath: cwd).lastPathComponent }
}

struct ModelUsage: Identifiable {
    let model: String
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    var id: String { model }
    var total: Int { input + output + cacheRead + cacheWrite }
}

struct SessionSummary: Identifiable, Hashable {
    let id: String
    let cwd: String
    let title: String?
    let firstPrompt: String?
    let lastPrompt: String?
    let firstActivity: Date
    let lastActivity: Date
    let transcript: String?
    let cost: Double
    let tokens: Int
    let linesAdded: Int
    let linesRemoved: Int

    var projectName: String { URL(fileURLWithPath: cwd).lastPathComponent }
    var displayTitle: String { title ?? firstPrompt ?? lastPrompt ?? "Sessão \(id.prefix(8))" }
}

struct UsageTotals {
    var cost: Double = 0
    var tokens: Int = 0
    var sessions: Int = 0
}

/// Índice incremental dos transcripts do Claude Code (~/.claude/projects/**/*.jsonl) em SQLite.
/// Cada arquivo guarda até onde já foi lido; só linhas completas novas são processadas.
///
/// Fontes:
/// - tokens: linhas "assistant" com `message.usage`, deduplicadas por message.id + requestId
///   (a mesma mensagem aparece uma vez por bloco de conteúdo);
/// - custo: linhas "cost-state" (custo oficial acumulado da sessão, calculado pelo Claude Code);
///   o custo por dia vem da diferença entre registros consecutivos;
/// - título/prompts: "ai-title", "last-prompt" e mensagens "user" digitadas.
@MainActor
final class UsageIndex: ObservableObject {
    @Published private(set) var isIndexing = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastUpdated: Date?

    private let worker = UsageIndexWorker()
    private var pendingRefresh = false
    private var refreshWork: DispatchWorkItem?

    func refresh() {
        guard !isIndexing else {
            pendingRefresh = true
            return
        }
        isIndexing = true
        progress = 0
        worker.queue.async { [worker] in
            worker.index { value in
                DispatchQueue.main.async { self.progress = value }
            }
            DispatchQueue.main.async {
                self.isIndexing = false
                self.lastUpdated = Date()
                if self.pendingRefresh {
                    self.pendingRefresh = false
                    self.refresh()
                }
            }
        }
    }

    /// Reindexa alguns segundos depois (ex.: após um Stop), agrupando eventos próximos.
    func refreshSoon() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Executa uma consulta na fila do índice e entrega o resultado na main.
    func read<T>(_ body: @escaping (UsageIndexWorker) -> T, completion: @escaping (T) -> Void) {
        worker.queue.async { [worker] in
            let result = body(worker)
            DispatchQueue.main.async { completion(result) }
        }
    }
}

final class UsageIndexWorker {
    let queue = DispatchQueue(label: "macpet.usage-index", qos: .utility)
    private static let schemaVersion = 3
    private let root = MacPetPaths.home.appendingPathComponent(".claude/projects")
    private var db: SQLiteDB?
    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init() {
        queue.async { self.open() }
    }

    private func open() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacPet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // MACPET_INDEX_DB permite testar a indexação num banco descartável.
        let path = ProcessInfo.processInfo.environment["MACPET_INDEX_DB"] ?? dir.appendingPathComponent("claude-usage.sqlite").path
        db = SQLiteDB(path: path)
        // Mudou o schema: apaga e reindexa do zero.
        if (db?.query("PRAGMA user_version").first?.int(0) ?? 0) < Self.schemaVersion {
            db?.exec("DROP TABLE IF EXISTS files; DROP TABLE IF EXISTS messages; DROP TABLE IF EXISTS sessions; DROP TABLE IF EXISTS cost_events; DROP TABLE IF EXISTS prompts; DROP TABLE IF EXISTS edits;")
            db?.exec("PRAGMA user_version = \(Self.schemaVersion)")
        }
        db?.exec("""
            CREATE TABLE IF NOT EXISTS files (path TEXT PRIMARY KEY, offset INTEGER NOT NULL, size INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS messages (
                key TEXT PRIMARY KEY, session TEXT, ts REAL, model TEXT,
                input INTEGER, output INTEGER, cache_write INTEGER, cache_read INTEGER
            );
            CREATE INDEX IF NOT EXISTS messages_ts ON messages(ts);
            CREATE INDEX IF NOT EXISTS messages_session ON messages(session);
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY, cwd TEXT, title TEXT, first_prompt TEXT, last_prompt TEXT,
                first_ts REAL, last_ts REAL, transcript TEXT,
                cost REAL NOT NULL DEFAULT 0, cost_raw REAL NOT NULL DEFAULT 0,
                lines_added INTEGER NOT NULL DEFAULT 0, lines_removed INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS cost_events (session TEXT, ts REAL, delta REAL);
            CREATE INDEX IF NOT EXISTS cost_events_ts ON cost_events(ts);
            CREATE TABLE IF NOT EXISTS prompts (session TEXT, ts REAL, text TEXT, UNIQUE(session, ts, text));
            CREATE INDEX IF NOT EXISTS prompts_session ON prompts(session);
            CREATE TABLE IF NOT EXISTS edits (session TEXT, path TEXT, tool TEXT, ts REAL, UNIQUE(session, path, ts));
            CREATE INDEX IF NOT EXISTS edits_session ON edits(session);
            """)
    }

    // MARK: Indexação

    func index(progress: (Double) -> Void) {
        guard let db, let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return }

        var files: [(URL, Int)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            files.append((url, size))
        }

        var known: [String: (offset: Int, size: Int)] = [:]
        for row in db.query("SELECT path, offset, size FROM files") {
            known[row.string(0) ?? ""] = (row.int(1), row.int(2))
        }

        let pending = files.filter { url, size in known[url.path].map { $0.size != size } ?? true }
        let totalBytes = max(1, pending.reduce(0) { $0 + $1.1 - min(known[$1.0.path]?.offset ?? 0, $1.1) })
        var doneBytes = 0
        var lastReported = 0.0

        for (url, size) in pending {
            var offset = known[url.path]?.offset ?? 0
            if size < offset { offset = 0 } // arquivo reescrito
            let start = offset
            db.transaction {
                offset = indexFile(url, from: offset)
                db.run("INSERT OR REPLACE INTO files (path, offset, size) VALUES (?, ?, ?)", url.path, offset, size)
            }
            doneBytes += max(0, size - start)
            let fraction = Double(doneBytes) / Double(totalBytes)
            if fraction - lastReported > 0.01 {
                lastReported = fraction
                progress(fraction)
            }
        }
        progress(1)
    }

    /// Lê o arquivo a partir de `offset` e devolve o novo offset (logo após a última linha completa).
    private func indexFile(_ url: URL, from offset: Int) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return offset }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(offset))

        let isSubagent = url.path.contains("/subagents/")
        var context = FileContext(transcript: isSubagent ? nil : url.path, isSubagent: isSubagent)
        var position = offset
        var carry = Data()
        let newline = UInt8(ascii: "\n")

        while true {
            // Sem o autoreleasepool, os objetos temporários do JSONSerialization se acumulam
            // durante a indexação inteira (centenas de MB na primeira passada).
            let more: Bool = autoreleasepool {
                guard let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty else { return false }
                var buffer = carry
                buffer.append(chunk)
                var lineStart = buffer.startIndex
                while let newlineIndex = buffer[lineStart...].firstIndex(of: newline) {
                    let line = buffer[lineStart..<newlineIndex]
                    if !line.isEmpty { autoreleasepool { process(line, &context) } }
                    position += newlineIndex - lineStart + 1
                    lineStart = buffer.index(after: newlineIndex)
                }
                carry = Data(buffer[lineStart...])
                return true
            }
            if !more { break }
        }
        // Linha final sem "\n" (sessão ainda escrevendo) fica para a próxima leitura.
        return position
    }

    private struct FileContext {
        let transcript: String?
        let isSubagent: Bool
        var lastTimestamp: Double?
    }

    private static let markers: [(Data, String)] = [
        (Data(#""type":"assistant""#.utf8), "assistant"),
        (Data(#""type":"user""#.utf8), "user"),
        (Data(#""type":"cost-state""#.utf8), "cost-state"),
        (Data(#""type":"ai-title""#.utf8), "ai-title"),
        (Data(#""type":"last-prompt""#.utf8), "last-prompt"),
    ]
    private static let usageMarker = Data(#""usage""#.utf8)
    private static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// Mensagens automáticas que não são prompts de verdade.
    private static func isTypedPrompt(_ text: String) -> Bool {
        !text.hasPrefix("<") && !text.hasPrefix("This session is being continued") && !text.hasPrefix("Caveat:")
    }

    private func process(_ line: Data, _ context: inout FileContext) {
        // Filtro barato por substring antes de pagar o parse de JSON.
        guard let kind = Self.markers.first(where: { line.range(of: $0.0) != nil })?.1 else { return }
        if kind == "assistant", line.range(of: Self.usageMarker) == nil { return }
        if kind == "user", line.count > 256 * 1024 { return } // resultados de ferramenta enormes
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              json["type"] as? String == kind,
              let session = json["sessionId"] as? String ?? json["session_id"] as? String,
              let db else { return }

        let ts = (json["timestamp"] as? String).flatMap { isoFormatter.date(from: $0)?.timeIntervalSince1970 }
        if let ts { context.lastTimestamp = ts }
        let cwd = json["cwd"] as? String

        if let ts, let cwd {
            db.run("""
                INSERT INTO sessions (id, cwd, first_ts, last_ts, transcript) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    cwd = COALESCE(sessions.cwd, excluded.cwd),
                    first_ts = MIN(COALESCE(sessions.first_ts, excluded.first_ts), excluded.first_ts),
                    last_ts = MAX(COALESCE(sessions.last_ts, excluded.last_ts), excluded.last_ts),
                    transcript = COALESCE(sessions.transcript, excluded.transcript)
                """, session, cwd, ts, ts, context.transcript)
        }

        switch kind {
        case "assistant":
            guard let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }
            let key = "\(message["id"] as? String ?? UUID().uuidString)|\(json["requestId"] as? String ?? "")"
            db.run("""
                INSERT OR IGNORE INTO messages (key, session, ts, model, input, output, cache_write, cache_read)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                key, session, ts ?? context.lastTimestamp, message["model"] as? String,
                usage["input_tokens"] as? Int ?? 0, usage["output_tokens"] as? Int ?? 0,
                usage["cache_creation_input_tokens"] as? Int ?? 0, usage["cache_read_input_tokens"] as? Int ?? 0)
            for item in message["content"] as? [[String: Any]] ?? [] where item["type"] as? String == "tool_use" {
                guard let tool = item["name"] as? String, Self.editTools.contains(tool),
                      let input = item["input"] as? [String: Any],
                      let path = input["file_path"] as? String ?? input["notebook_path"] as? String else { continue }
                db.run("INSERT OR IGNORE INTO edits (session, path, tool, ts) VALUES (?, ?, ?, ?)",
                       session, path, tool, ts ?? context.lastTimestamp)
            }

        case "user":
            // Só prompts digitados (conteúdo texto), não resultados de ferramenta.
            guard !context.isSubagent, json["isMeta"] as? Bool != true,
                  let message = json["message"] as? [String: Any],
                  let text = Self.promptText(message["content"]) else { return }
            db.run("UPDATE sessions SET first_prompt = COALESCE(first_prompt, ?) WHERE id = ?", Self.clip(text), session)
            db.run("INSERT OR IGNORE INTO prompts (session, ts, text) VALUES (?, ?, ?)",
                   session, ts ?? context.lastTimestamp, Self.clip(text, limit: 2000))

        case "cost-state":
            guard !context.isSubagent, let total = json["totalCostUSD"] as? Double else { return }
            let previous = db.query("SELECT cost_raw FROM sessions WHERE id = ?", session).first?.double(0) ?? 0
            // O acumulado reinicia quando a sessão é retomada em outro processo.
            let delta = total >= previous ? total - previous : total
            db.run("""
                INSERT INTO sessions (id, cost, cost_raw, lines_added, lines_removed) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET cost = sessions.cost + ?, cost_raw = ?,
                    lines_added = MAX(sessions.lines_added, excluded.lines_added),
                    lines_removed = MAX(sessions.lines_removed, excluded.lines_removed)
                """,
                session, delta, total, json["totalLinesAdded"] as? Int ?? 0, json["totalLinesRemoved"] as? Int ?? 0,
                delta, total)
            if delta > 0 {
                db.run("INSERT INTO cost_events (session, ts, delta) VALUES (?, ?, ?)",
                       session, context.lastTimestamp ?? Date().timeIntervalSince1970, delta)
            }

        case "ai-title":
            guard let title = json["aiTitle"] as? String else { return }
            db.run("INSERT INTO sessions (id, title) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET title = excluded.title", session, title)

        case "last-prompt":
            guard let prompt = json["lastPrompt"] as? String, Self.isTypedPrompt(prompt) else { return }
            db.run("INSERT INTO sessions (id, last_prompt) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET last_prompt = excluded.last_prompt", session, Self.clip(prompt))

        default:
            break
        }
    }

    /// Texto digitado de uma mensagem "user": string simples ou blocos de texto (quando há imagem
    /// ou seleção da IDE). Mensagens com resultado de ferramenta não são prompts.
    private static func promptText(_ content: Any?) -> String? {
        if let text = content as? String {
            return isTypedPrompt(text) ? text : nil
        }
        guard let blocks = content as? [[String: Any]],
              !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
        let texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .filter(isTypedPrompt)
        return texts.isEmpty ? nil : texts.joined(separator: " ")
    }

    private static func clip(_ text: String, limit: Int = 300) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    // MARK: Consultas

    func totals(since: Date) -> UsageTotals {
        guard let db else { return UsageTotals() }
        let ts = since.timeIntervalSince1970
        let cost = db.query("SELECT COALESCE(SUM(delta), 0) FROM cost_events WHERE ts >= ?", ts).first?.double(0) ?? 0
        let tokens = db.query("SELECT COALESCE(SUM(input + output + cache_write + cache_read), 0) FROM messages WHERE ts >= ?", ts).first?.int(0) ?? 0
        let sessions = db.query("SELECT COUNT(*) FROM sessions WHERE last_ts >= ?", ts).first?.int(0) ?? 0
        return UsageTotals(cost: cost, tokens: tokens, sessions: sessions)
    }

    func daily(days: Int) -> [DayUsage] {
        guard let db else { return [] }
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: Date()))!
        let ts = start.timeIntervalSince1970
        var costs: [String: Double] = [:]
        for row in db.query("SELECT date(ts, 'unixepoch', 'localtime'), SUM(delta) FROM cost_events WHERE ts >= ? GROUP BY 1", ts) {
            costs[row.string(0) ?? ""] = row.double(1)
        }
        var tokens: [String: Int] = [:]
        for row in db.query("SELECT date(ts, 'unixepoch', 'localtime'), SUM(input + output + cache_write + cache_read) FROM messages WHERE ts >= ? GROUP BY 1", ts) {
            tokens[row.string(0) ?? ""] = row.int(1)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return (0..<days).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            let key = formatter.string(from: day)
            return DayUsage(day: day, cost: costs[key] ?? 0, tokens: tokens[key] ?? 0)
        }
    }

    func projects(since: Date, limit: Int = 8) -> [ProjectUsage] {
        guard let db else { return [] }
        let ts = since.timeIntervalSince1970
        let rows = db.query("""
            SELECT s.cwd, COUNT(DISTINCT s.id),
                   COALESCE((SELECT SUM(m.input + m.output + m.cache_write + m.cache_read) FROM messages m
                             JOIN sessions s2 ON s2.id = m.session WHERE s2.cwd = s.cwd AND m.ts >= ?), 0),
                   COALESCE((SELECT SUM(c.delta) FROM cost_events c
                             JOIN sessions s3 ON s3.id = c.session WHERE s3.cwd = s.cwd AND c.ts >= ?), 0) AS cost
            FROM sessions s WHERE s.cwd IS NOT NULL AND s.last_ts >= ?
            GROUP BY s.cwd ORDER BY cost DESC LIMIT ?
            """, ts, ts, ts, limit)
        return rows.map { ProjectUsage(cwd: $0.string(0) ?? "", sessions: $0.int(1), tokens: $0.int(2), cost: $0.double(3)) }
    }

    func models(since: Date) -> [ModelUsage] {
        guard let db else { return [] }
        let rows = db.query("""
            SELECT model, SUM(input), SUM(output), SUM(cache_read), SUM(cache_write) FROM messages
            WHERE ts >= ? AND model IS NOT NULL AND model NOT LIKE '<%'
            GROUP BY model ORDER BY SUM(output) DESC
            """, since.timeIntervalSince1970)
        return rows.map {
            ModelUsage(model: $0.string(0) ?? "?", input: $0.int(1), output: $0.int(2), cacheRead: $0.int(3), cacheWrite: $0.int(4))
        }
    }

    /// `folder`: só conversas daquela pasta e das subpastas.
    func sessions(search: String, limit: Int = 300, folder: String? = nil) -> [SessionSummary] {
        guard let db else { return [] }
        let pattern = "%\(search)%"
        let folderPattern = (folder ?? "") + "/%"
        let rows = db.query("""
            SELECT s.id, s.cwd, s.title, s.first_prompt, s.last_prompt, s.first_ts, s.last_ts, s.transcript,
                   s.cost, COALESCE((SELECT SUM(input + output + cache_write + cache_read) FROM messages WHERE session = s.id), 0),
                   s.lines_added, s.lines_removed
            FROM sessions s
            WHERE s.last_ts IS NOT NULL AND s.transcript IS NOT NULL AND s.cwd NOT LIKE '%/.%'
              AND (? = '' OR s.title LIKE ? OR s.cwd LIKE ?
                   OR EXISTS (SELECT 1 FROM prompts p WHERE p.session = s.id AND p.text LIKE ?))
              AND (? = '' OR s.cwd = ? OR s.cwd LIKE ?)
            ORDER BY s.last_ts DESC LIMIT ?
            """, search, pattern, pattern, pattern, folder ?? "", folder ?? "", folderPattern, limit)
        return rows.map { row in
            SessionSummary(
                id: row.string(0) ?? "", cwd: row.string(1) ?? "", title: row.string(2),
                firstPrompt: row.string(3), lastPrompt: row.string(4),
                firstActivity: Date(timeIntervalSince1970: row.double(5)),
                lastActivity: Date(timeIntervalSince1970: row.double(6)),
                transcript: row.string(7), cost: row.double(8), tokens: row.int(9),
                linesAdded: row.int(10), linesRemoved: row.int(11)
            )
        }
    }

    /// Pastas de projeto usadas recentemente (para lançar sessões e prompts).
    func recentProjects(limit: Int = 15) -> [String] {
        guard let db else { return [] }
        return db.query("""
            SELECT cwd FROM sessions WHERE cwd IS NOT NULL AND transcript IS NOT NULL AND cwd NOT LIKE '%/.%'
            GROUP BY cwd ORDER BY MAX(last_ts) DESC LIMIT ?
            """, limit)
            .compactMap { $0.string(0) }
            .filter { FileManager.default.fileExists(atPath: $0) && !$0.contains("/private/tmp/") }
    }

    func transcript(session: String) -> String? {
        db?.query("SELECT transcript FROM sessions WHERE id = ?", session).first?.string(0)
    }

    /// Conversas de uma pasta de projeto, da mais recente para a mais antiga.
    func sessions(inProject cwd: String, limit: Int = 100) -> [SessionSummary] {
        // A pasta do projeto e as subpastas dela (conversas abertas em apps/api, por exemplo).
        sessions(search: "", limit: limit, folder: cwd)
    }

    func prompts(session: String) -> [(date: Date, text: String)] {
        db?.query("SELECT ts, text FROM prompts WHERE session = ? ORDER BY ts", session)
            .map { (Date(timeIntervalSince1970: $0.double(0)), $0.string(1) ?? "") } ?? []
    }

    /// Arquivos alterados na sessão, com quantas vezes cada um foi editado.
    func edits(session: String) -> [(path: String, count: Int)] {
        db?.query("SELECT path, COUNT(*) FROM edits WHERE session = ? GROUP BY path ORDER BY MAX(ts) DESC", session)
            .map { ($0.string(0) ?? "", $0.int(1)) } ?? []
    }
}
