import Foundation

/// Um subagente (ferramenta Agent/Task) ou um agente de workflow.
struct AgentRun: Identifiable, Hashable {
    let id: String
    let transcript: String
    let type: String
    /// Descrição dada pelo agente pai ou, sem ela, a primeira linha do pedido.
    let title: String
    let prompt: String
    let toolUseId: String?
    var started: Date?
    var lastActivity: Date?
    var lastAction: String?
    /// Resultado registrado no journal do workflow (quando houver).
    var result: String?
    var isRunning: Bool

    var duration: TimeInterval? {
        guard let started, let lastActivity else { return nil }
        return lastActivity.timeIntervalSince(started)
    }
}

struct WorkflowRun: Identifiable, Hashable {
    let id: String
    var name: String
    var summary: String?
    var toolUseId: String?
    var agents: [AgentRun]
    var launched: Int
    var completed: Int

    var started: Date? { agents.compactMap(\.started).min() }
    var lastActivity: Date? { agents.compactMap(\.lastActivity).max() }
    var isRunning: Bool { agents.contains(where: \.isRunning) }
}

struct AgentTree: Equatable {
    var workflows: [WorkflowRun] = []
    var subagents: [AgentRun] = []

    var isEmpty: Bool { workflows.isEmpty && subagents.isEmpty }
    var runningCount: Int {
        subagents.filter(\.isRunning).count + workflows.reduce(0) { $0 + $1.agents.filter(\.isRunning).count }
    }

    /// Agente disparado por uma chamada específica (para os cards do chat).
    func agent(forToolUse id: String) -> AgentRun? { subagents.first { $0.toolUseId == id } }
    func workflow(forToolUse id: String) -> WorkflowRun? { workflows.first { $0.toolUseId == id } }
}

/// Lê a árvore de agentes de uma sessão do Claude Code a partir do disco:
/// `<sessão>/subagents/agent-*.jsonl` (+ `.meta.json`) e `<sessão>/subagents/workflows/wf_*/`.
/// Para não ler centenas de MB, cada agente só tem o começo (pedido) e o fim (último passo) lidos.
enum AgentScanner {
    /// Transcript de uma sessão a partir da pasta do projeto (mesma codificação do Claude Code).
    static func transcriptPath(sessionId: String, cwd: String) -> String {
        let encoded = String(cwd.map { $0.isLetter && $0.isASCII || $0.isNumber || $0 == "-" ? $0 : "-" })
        return MacPetPaths.home.appendingPathComponent(".claude/projects/\(encoded)/\(sessionId).jsonl").path
    }

    static func scan(transcript: String) -> AgentTree {
        let base = URL(fileURLWithPath: transcript).deletingPathExtension().appendingPathComponent("subagents")
        let fm = FileManager.default
        guard fm.fileExists(atPath: base.path) else { return AgentTree() }

        var tree = AgentTree()
        let files = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        tree.subagents = readAgents(files.filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("agent-") }, journal: nil)
            .sorted { ($0.started ?? .distantPast) > ($1.started ?? .distantPast) }

        let workflowsDir = base.appendingPathComponent("workflows")
        let runs = (try? fm.contentsOfDirectory(at: workflowsDir, includingPropertiesForKeys: nil)) ?? []
        let names = WorkflowNames.load(transcript: transcript)
        tree.workflows = runs.filter { $0.lastPathComponent.hasPrefix("wf_") }.map { dir in
            let journal = readJournal(dir.appendingPathComponent("journal.jsonl"))
            let agentFiles = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("agent-") }
            let agents = readAgents(agentFiles, journal: journal)
                .sorted { ($0.started ?? .distantPast) < ($1.started ?? .distantPast) }
            let info = names[dir.lastPathComponent]
            return WorkflowRun(
                id: dir.lastPathComponent,
                name: info?.name ?? dir.lastPathComponent,
                summary: info?.summary,
                toolUseId: info?.toolUseId,
                agents: agents,
                launched: max(journal.started.count, agents.count),
                completed: journal.results.count
            )
        }
        .sorted { ($0.started ?? .distantPast) > ($1.started ?? .distantPast) }
        return tree
    }

    // MARK: Agente

    /// Cache por arquivo: só relê o agente quando o arquivo mudou (data ou tamanho).
    private static var agentCache: [String: (modified: Date, size: Int, agent: AgentRun)] = [:]
    private static let cacheLock = NSLock()

    private static func readAgents(_ urls: [URL], journal: Journal?) -> [AgentRun] {
        var results = [AgentRun?](repeating: nil, count: urls.count)
        let resultsLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: urls.count) { index in
            let url = urls[index]
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? 0
            cacheLock.lock()
            let cached = agentCache[url.path]
            cacheLock.unlock()
            var agent: AgentRun
            if let cached, cached.modified == modified, cached.size == size {
                agent = cached.agent
            } else {
                agent = autoreleasepool { readAgent(url, modified: modified) }
                cacheLock.lock()
                agentCache[url.path] = (modified, size, agent)
                cacheLock.unlock()
            }
            agent.result = journal?.results[agent.id]
            agent.isRunning = Date().timeIntervalSince(modified) < 90 && agent.result == nil
            resultsLock.lock()
            results[index] = agent
            resultsLock.unlock()
        }
        return results.compactMap { $0 }
    }

    private static func readAgent(_ url: URL, modified: Date) -> AgentRun {
        let id = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "agent-", with: "")
        let metaURL = url.deletingPathExtension().appendingPathExtension("meta.json")
        let meta = (try? Data(contentsOf: metaURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        let head = readLines(url, fromEnd: false, window: 32 * 1024)
        let tail = readLines(url, fromEnd: true)

        var prompt = ""
        var started: Date?
        for line in head {
            guard let json = parse(line) else { continue }
            started = started ?? date(json["timestamp"])
            if json["type"] as? String == "user", let message = json["message"] as? [String: Any] {
                prompt = String(ChatSession.resultText(message["content"]).prefix(4000))
                break
            }
        }

        var lastActivity: Date?
        var lastAction: String?
        for line in tail.reversed() {
            guard let json = parse(line) else { continue }
            lastActivity = lastActivity ?? date(json["timestamp"])
            if lastAction == nil, json["type"] as? String == "assistant",
               let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] {
                for block in content.reversed() {
                    if block["type"] as? String == "tool_use" {
                        let call = ChatSession.toolCall(id: "", name: block["name"] as? String ?? "?", input: block["input"] as? [String: Any] ?? [:])
                        lastAction = "\(call.name) \(call.summary)"
                        break
                    } else if block["type"] as? String == "text", let text = block["text"] as? String, !text.isEmpty {
                        lastAction = text
                        break
                    }
                }
            }
            if lastActivity != nil && lastAction != nil { break }
        }


        let firstLine = prompt.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init) ?? "Agente \(id.prefix(6))"
        return AgentRun(
            id: id,
            transcript: url.path,
            type: meta["agentType"] as? String ?? "agente",
            title: (meta["description"] as? String) ?? String(firstLine.prefix(140)),
            prompt: prompt,
            toolUseId: meta["toolUseId"] as? String,
            started: started,
            lastActivity: lastActivity ?? modified,
            lastAction: lastAction.map { String($0.replacingOccurrences(of: "\n", with: " ").prefix(200)) },
            // Preenchidos em readAgents (dependem do journal e da hora atual).
            result: nil,
            isRunning: false
        )
    }

    private struct Journal {
        var started: Set<String> = []
        var results: [String: String] = [:]
    }

    private static func readJournal(_ url: URL) -> Journal {
        var journal = Journal()
        guard let data = try? Data(contentsOf: url) else { return journal }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let agent = json["agentId"] as? String else { continue }
            if json["type"] as? String == "started" { journal.started.insert(agent) }
            if json["type"] as? String == "result" {
                journal.results[agent] = describe(json["result"])
            }
        }
        return journal
    }

    /// Resultado do journal como texto legível (string direto, objeto como JSON identado).
    private static func describe(_ value: Any?) -> String {
        if let text = value as? String { return text }
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Leitura parcial

    /// Linhas completas dos primeiros/últimos ~96 KB do arquivo.
    private static func readLines(_ url: URL, fromEnd: Bool, window: UInt64 = 96 * 1024) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = fromEnd && size > window ? size - window : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: Int(min(window, size))) else { return [] }
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map { Data($0) }
        // Bordas da janela podem cortar uma linha no meio.
        if fromEnd && start > 0 && !lines.isEmpty { lines.removeFirst() }
        if !fromEnd && UInt64(data.count) < size && !lines.isEmpty { lines.removeLast() }
        return lines
    }

    private static func parse(_ line: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func date(_ value: Any?) -> Date? {
        (value as? String).flatMap { isoFormatter.date(from: $0) }
    }
}

/// Nome e resumo de cada workflow, tirados do "recibo" da ferramenta Workflow na sessão principal
/// (`toolUseResult.runId/workflowName/summary`). Leitura incremental com cache por arquivo.
enum WorkflowNames {
    struct Info {
        let name: String
        let summary: String?
        let toolUseId: String?
    }

    private static var cache: [String: (offset: UInt64, names: [String: Info])] = [:]
    private static let lock = NSLock()
    private static let marker = Data(#""workflowName""#.utf8)

    static func load(transcript: String) -> [String: Info] {
        lock.lock()
        defer { lock.unlock() }
        var entry = cache[transcript] ?? (0, [:])
        guard let handle = FileHandle(forReadingAtPath: transcript) else { return entry.names }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < entry.offset { entry = (0, [:]) }
        try? handle.seek(toOffset: entry.offset)

        var carry = Data()
        var position = entry.offset
        while let chunk = try? handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            autoreleasepool {
                var buffer = carry
                buffer.append(chunk)
                var lineStart = buffer.startIndex
                while let newline = buffer[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[lineStart..<newline]
                    if line.range(of: marker) != nil, let info = parseReceipt(line) {
                        entry.names[info.runId] = info.info
                    }
                    position += UInt64(newline - lineStart + 1)
                    lineStart = buffer.index(after: newline)
                }
                carry = Data(buffer[lineStart...])
            }
        }
        entry.offset = position
        cache[transcript] = entry
        return entry.names
    }

    private static func parseReceipt(_ line: Data) -> (runId: String, info: Info)? {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let receipt = json["toolUseResult"] as? [String: Any],
              let runId = receipt["runId"] as? String,
              let name = receipt["workflowName"] as? String else { return nil }
        let toolUseId = ((json["message"] as? [String: Any])?["content"] as? [[String: Any]])?
            .first { $0["type"] as? String == "tool_result" }?["tool_use_id"] as? String
        return (runId, Info(name: name, summary: receipt["summary"] as? String, toolUseId: toolUseId))
    }
}
