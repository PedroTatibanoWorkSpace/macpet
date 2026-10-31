import AppKit
import Foundation

enum ClaudeSessionState: String {
    case idle, working, waiting, finished

    var label: String {
        switch self {
        case .idle: "Parada"
        case .working: "Trabalhando"
        case .waiting: "Esperando você"
        case .finished: "Terminou"
        }
    }
}

struct ClaudeSession: Identifiable {
    let id: String
    var cwd: String
    var state: ClaudeSessionState = .idle
    var lastEvent = Date()
    var workStarted: Date?
    var message: String?
    var transcriptPath: String?
    var terminalBundleId: String?
    var itermSessionId: String?
    var pid: pid_t?
    var model: String?
    var contextPercentage: Double?

    var projectName: String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}

/// Estado das sessões do Claude Code, alimentado pelos eventos dos hooks.
@MainActor
final class ClaudeSessionStore: ObservableObject {
    @Published private(set) var sessions: [String: ClaudeSession] = [:]
    @Published private(set) var lastFinished: Date?
    @Published private(set) var lastActivity = Date()

    private let notifier: Notifier
    private let settings: AppSettings
    private var pruneTimer: Timer?

    init(notifier: Notifier, settings: AppSettings) {
        self.notifier = notifier
        self.settings = settings
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
    }

    var ordered: [ClaudeSession] {
        sessions.values.sorted { lhs, rhs in
            if lhs.state == .waiting, rhs.state != .waiting { return true }
            if rhs.state == .waiting, lhs.state != .waiting { return false }
            return lhs.lastEvent > rhs.lastEvent
        }
    }

    var waitingCount: Int { sessions.values.filter { $0.state == .waiting }.count }
    var workingCount: Int { sessions.values.filter { $0.state == .working }.count }

    func handle(_ event: [String: Any]) {
        guard let name = event["hook_event_name"] as? String,
              let id = event["session_id"] as? String else { return }

        // A statusLine dispara várias vezes por resposta: só atualiza modelo e contexto.
        if name == "StatusLine" {
            guard var session = sessions[id] else { return }
            session.model = (event["model"] as? [String: Any])?["display_name"] as? String ?? session.model
            if let context = (event["context_window"] as? [String: Any])?["used_percentage"] as? Double {
                session.contextPercentage = context
            }
            sessions[id] = session
            return
        }

        lastActivity = Date()
        if name == "SessionEnd" {
            sessions[id] = nil
            return
        }

        var session = sessions[id] ?? ClaudeSession(id: id, cwd: event["cwd"] as? String ?? "")
        session.lastEvent = Date()
        if let cwd = event["cwd"] as? String, !cwd.isEmpty { session.cwd = cwd }
        if let path = event["transcript_path"] as? String { session.transcriptPath = path }
        if let meta = event["_macpet"] as? [String: Any] {
            session.terminalBundleId = meta["bundle_id"] as? String ?? session.terminalBundleId
            session.itermSessionId = meta["iterm_session_id"] as? String ?? session.itermSessionId
            if let pid = meta["claude_pid"] as? Int { session.pid = pid_t(pid) }
        }

        switch name {
        case "SessionStart":
            session.state = .idle
        case "UserPromptSubmit":
            session.state = .working
            session.workStarted = Date()
            session.message = (event["prompt"] as? String).map { Self.truncate($0, 140) }
        case "PostToolUse", "PreToolUse":
            session.state = .working
            if session.workStarted == nil { session.workStarted = Date() }
        case "Notification":
            let message = event["message"] as? String ?? ""
            let type = event["notification_type"] as? String
            // "idle_prompt" chega ~60s depois do Stop; já notificamos no Stop.
            let isIdle = type == "idle_prompt" || message.localizedCaseInsensitiveContains("waiting for your input")
            if !isIdle {
                session.state = .waiting
                session.message = message
                notify(session, subtitle: "Precisa de você", body: message.isEmpty ? "O Claude está esperando sua resposta." : message,
                       kind: "waiting", mood: .waiting)
                onSpeech?(session, .waiting, message.isEmpty ? "O Claude está esperando sua resposta." : message)
            }
        case "Stop":
            session.state = .finished
            lastFinished = Date()
            let summary = (event["last_assistant_message"] as? String)
                ?? session.transcriptPath.flatMap(TranscriptReader.lastAssistantText)
            if let summary { session.message = Self.truncate(summary, 200) }
            let duration = session.workStarted.map { Self.duration(Date().timeIntervalSince($0)) }
            session.workStarted = nil
            notify(session, subtitle: "Terminou" + (duration.map { " em \($0)" } ?? ""), body: session.message ?? "O Claude finalizou a tarefa.",
                   kind: "stop", mood: .celebrating)
            onSpeech?(session, .finished, summary.map(Speech.headline) ?? "Terminei a tarefa.")
        default:
            break
        }
        sessions[id] = session
    }

    /// O corvo da tela fala: a sessão terminou (com o texto final do Claude) ou precisa de você.
    var onSpeech: ((ClaudeSession, Speech.Kind, String) -> Void)?

    /// Abre o painel do MacPet num projeto (sessões que rodam dentro do próprio app).
    var openInApp: ((String) -> Void)?

    func open(_ sessionId: String) {
        guard let session = sessions[sessionId] else { return }
        if session.terminalBundleId == Bundle.main.bundleIdentifier {
            openInApp?(session.cwd)
        } else {
            TerminalFocuser.focus(session)
        }
    }

    /// Estado vindo dos chats do painel (pedidos de permissão não passam pelos hooks).
    func setExternalState(_ sessionId: String, cwd: String, state: ClaudeSessionState) {
        var session = sessions[sessionId] ?? ClaudeSession(id: sessionId, cwd: cwd)
        session.state = state
        session.lastEvent = Date()
        session.terminalBundleId = Bundle.main.bundleIdentifier
        if state == .working, session.workStarted == nil { session.workStarted = Date() }
        sessions[sessionId] = session
        lastActivity = Date()
    }

    func dismiss(_ sessionId: String) {
        sessions[sessionId] = nil
    }

    /// Nome que aparece nas notificações: o projeto do painel (com a tarefa ou conversa fixada), ou a pasta.
    var displayName: ((String) -> String?)?

    private func notify(_ session: ClaudeSession, subtitle: String, body: String, kind: String, mood: PetMood) {
        let title = displayName?(session.cwd) ?? session.projectName
        if !settings.notifyWhenTerminalFocused,
           let bundle = session.terminalBundleId,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle {
            return
        }
        notifier.post(id: "claude-\(session.id)-\(kind)", title: title, subtitle: subtitle, body: body,
                      sessionId: session.id, cwd: session.cwd, mood: mood)
    }

    /// Remove sessões cujo processo do Claude morreu sem mandar SessionEnd (ex.: terminal fechado).
    private func prune() {
        let stale = sessions.values.filter { session in
            if let pid = session.pid, kill(pid, 0) != 0, errno == ESRCH { return true }
            return Date().timeIntervalSince(session.lastEvent) > 12 * 3600
        }
        stale.forEach { sessions[$0.id] = nil }
    }

    private static func truncate(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60) min" }
        return "\(total / 3600)h\(String(format: "%02d", (total % 3600) / 60))"
    }
}

enum TranscriptReader {
    /// Lê o final do transcript JSONL e devolve o último texto do assistente.
    static func lastAssistantText(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 256 * 1024
        try? handle.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n").reversed() {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  json["type"] as? String == "assistant",
                  let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            if let last = texts.last(where: { !$0.isEmpty }) { return last }
        }
        return nil
    }
}

enum TerminalFocuser {
    static func focus(_ session: ClaudeSession) {
        // ITERM_SESSION_ID tem o formato "w0t1p0:UUID"; com ele dá para selecionar a aba exata.
        if let iterm = session.itermSessionId, let uuid = iterm.split(separator: ":").last {
            let script = """
                tell application "iTerm2"
                    activate
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if unique id of s is "\(uuid)" then
                                    select w
                                    select t
                                    select s
                                    return
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                """
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if error == nil { return }
            NSLog("MacPet: AppleScript do iTerm falhou: \(error!)")
        }
        if let bundle = session.terminalBundleId,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
