import AppKit
import Foundation

struct ToolCall: Equatable {
    let id: String
    let name: String
    /// Resumo de uma linha: comando, arquivo, padrão buscado…
    let summary: String
    /// Conteúdo principal (comando completo, conteúdo escrito, plano…).
    let detail: String?
    /// Para Edit/MultiEdit: trechos antigos e novos.
    let edits: [(old: String, new: String)]
    var result: String?
    var isError = false
    /// Progresso ao vivo de um subagente disparado por esta chamada (Agent/Task).
    var childSteps = 0
    var childLast: String?

    var spawnsAgents: Bool { ["Agent", "Task", "Workflow"].contains(name) }

    static func == (lhs: ToolCall, rhs: ToolCall) -> Bool {
        lhs.id == rhs.id && lhs.result == rhs.result && lhs.isError == rhs.isError
            && lhs.childSteps == rhs.childSteps && lhs.childLast == rhs.childLast
    }
}

struct PermissionRequest: Equatable {
    enum Status { case pending, allowed, denied }
    let requestId: String
    let tool: ToolCall
    let input: Data
    let suggestions: Data?
    /// Sugestão do Claude Code, ex.: "aceitar edições nesta sessão".
    let suggestionLabel: String?
    var status: Status = .pending
}

enum ChatItemKind: Equatable {
    case user(String, images: [ChatImage] = [])
    case assistant(String)
    case tool(ToolCall)
    case permission(PermissionRequest)
    case result(cost: Double, seconds: Double, isError: Bool)
    case notice(String)
}

/// Agente ou comando que o Claude deixou rodando em segundo plano. Quando termina, o próprio Claude
/// começa um turno sozinho para contar o resultado — desde que o processo ainda esteja vivo.
struct BackgroundTask: Identifiable, Equatable {
    let id: String
    let description: String
    let isAgent: Bool
}

struct ChatItem: Identifiable, Equatable {
    let id = UUID()
    var kind: ChatItemKind
}

enum PermissionMode: String, CaseIterable, Identifiable {
    case `default`, acceptEdits, auto, plan

    var id: String { rawValue }
    var label: String {
        switch self {
        case .default: "Pedir permissão"
        case .acceptEdits: "Aceitar edições"
        case .auto: "Auto"
        case .plan: "Planejar"
        }
    }

    var icon: String {
        switch self {
        case .default: "hand.raised"
        case .acceptEdits: "pencil.line"
        case .auto: "wand.and.stars"
        case .plan: "list.bullet.clipboard"
        }
    }

    var detail: String {
        switch self {
        case .default: "Pede sua permissão antes de editar ou rodar comandos."
        case .acceptEdits: "Edita arquivos sem perguntar; comandos ainda pedem permissão."
        case .auto: "O Claude decide sozinho o que é seguro e só para no que for arriscado."
        case .plan: "Só investiga e propõe um plano; não altera nada até você aprovar."
        }
    }

    /// Próximo modo no ⇧⇥, na mesma ordem do Claude Code no terminal.
    var next: PermissionMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Uma conversa com o Claude Code num projeto, rodando `claude -p` em modo stream-json.
/// O processo fica vivo entre mensagens (e continua se o MacPet fechar no meio de um turno — ver
/// `DetachedClaude`); as permissões chegam como `control_request` (`--permission-prompt-tool stdio`)
/// e são respondidas pelos botões do chat.
@MainActor
final class ChatSession: ObservableObject {
    @Published private(set) var items: [ChatItem] = []
    @Published private(set) var isRunning = false
    @Published private(set) var sessionId: String?
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var modelName: String?
    @Published private(set) var totalCost: Double = 0
    @Published private(set) var permissionMode: PermissionMode
    /// Valor de `--model` ("default" usa o da configuração do Claude Code).
    @Published private(set) var model: String
    /// Nível de `--effort`; nil usa o da configuração.
    @Published private(set) var effort: String?
    /// Servidores MCP (Notion, ClickUp…). Desligados, a conversa fica bem mais leve: o Sonnet carrega
    /// todas as ferramentas de MCP no contexto (~160 mil tokens a mais por mensagem).
    @Published private(set) var usesMCP: Bool
    @Published var draft = ""
    /// Imagens anexadas que vão junto com a próxima mensagem.
    @Published var attachments: [ChatImage] = []
    @Published private(set) var slashCommands = SlashCommands.cached
    /// Agentes e comandos em segundo plano. Enquanto houver algum, o processo não pode ser encerrado.
    @Published private(set) var backgroundTasks: [BackgroundTask] = []

    /// Sessão atual mudou (nil: conversa nova, ainda sem sessão).
    var onSessionId: ((String?) -> Void)?
    var onAttention: ((String) -> Void)?
    var onState: ((String, ClaudeSessionState) -> Void)?
    /// Limites do plano que chegam a cada resposta (`rate_limit_event`).
    var onRateLimits: (([String: Any]) -> Void)?

    let project: Project
    private var claude: DetachedClaude?
    private var streamingIndex: Int?
    private var turnStarted: Date?
    private var lastProcessCost: Double = 0
    private var historyLoaded = false
    private var historyToken: UUID?
    /// Mudança que só vale num processo novo (esforço): aplica quando o turno atual e os agentes em
    /// segundo plano terminarem.
    private var restartAfterTurn = false
    /// Pediu para parar e o turno ainda não acabou.
    private var stopping = false

    init(project: Project) {
        self.project = project
        sessionId = project.lastSessionId
        model = UserDefaults.standard.string(forKey: "chat.model.\(project.id)") ?? "default"
        permissionMode = UserDefaults.standard.string(forKey: "chat.mode.\(project.id)").flatMap(PermissionMode.init) ?? .default
        effort = UserDefaults.standard.string(forKey: "chat.effort.\(project.id)")
        usesMCP = UserDefaults.standard.object(forKey: "chat.mcp.\(project.id)") as? Bool ?? true
    }

    var pendingPermissions: Int {
        items.filter { if case .permission(let p) = $0.kind { return p.status == .pending } else { return false } }.count
    }

    // MARK: Ações

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = attachments
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        // No modo headless o /clear não tem efeito visível; aqui ele vira uma conversa nova.
        if trimmed == "/clear", images.isEmpty {
            newConversation()
            return
        }
        if claude == nil {
            start()
            // Não deu para iniciar (o motivo já apareceu na conversa): o texto volta para o campo.
            guard claude != nil else {
                if draft.isEmpty { draft = text }
                return
            }
        }
        attachments = []
        items.append(ChatItem(kind: .user(trimmed, images: images)))
        isRunning = true
        turnStarted = Date()
        if let sessionId { onState?(sessionId, .working) }
        let content: Any = images.isEmpty
            ? trimmed
            : images.map(\.contentBlock) + (trimmed.isEmpty ? [] : [["type": "text", "text": trimmed]])
        write(["type": "user", "message": ["role": "user", "content": content]])
    }

    func respond(to requestId: String, allow: Bool, applySuggestion: Bool = false) {
        guard let index = items.firstIndex(where: {
            if case .permission(let p) = $0.kind { return p.requestId == requestId } else { return false }
        }), case .permission(var request) = items[index].kind else { return }

        var response: [String: Any]
        if allow {
            let input = (try? JSONSerialization.jsonObject(with: request.input)) ?? [:]
            response = ["behavior": "allow", "updatedInput": input]
            if applySuggestion, let data = request.suggestions, let suggestions = try? JSONSerialization.jsonObject(with: data) {
                response["updatedPermissions"] = suggestions
                if let mode = (suggestions as? [[String: Any]])?.first(where: { $0["type"] as? String == "setMode" })?["mode"] as? String,
                   let newMode = PermissionMode(rawValue: mode) {
                    permissionMode = newMode
                    UserDefaults.standard.set(newMode.rawValue, forKey: "chat.mode.\(project.id)")
                }
            }
        } else {
            response = ["behavior": "deny", "message": "O usuário negou esta ação. Pergunte como ele prefere seguir."]
        }
        write(["type": "control_response", "response": ["subtype": "success", "request_id": requestId, "response": response]])
        request.status = allow ? .allowed : .denied
        items[index].kind = .permission(request)
        if let sessionId, pendingPermissions == 0 { onState?(sessionId, .working) }
    }

    /// Aviso do MacPet na conversa (não vai para o Claude).
    func notice(_ text: String) {
        items.append(ChatItem(kind: .notice(text)))
    }

    /// Parar: pede para o Claude interromper. Se em 6 s ele não parar (travado, ou sem ler as mensagens),
    /// encerra o processo; a conversa continua na próxima mensagem (o Claude é retomado com --resume).
    func interrupt() {
        guard isRunning else { return }
        guard !stopping else { return forceStop() }
        stopping = true
        control(["subtype": "interrupt"])
        items.append(ChatItem(kind: .notice("Parando…")))
        let turn = turnStarted
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.isRunning, self.stopping, self.turnStarted == turn else { return }
            self.forceStop()
        }
    }

    private func forceStop() {
        stopping = false
        stop()
        items.append(ChatItem(kind: .notice("O Claude não respondeu ao pedido de parar, então encerrei. A conversa continua: é só mandar a próxima mensagem.")))
    }

    func setPermissionMode(_ mode: PermissionMode) {
        permissionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "chat.mode.\(project.id)")
        if claude != nil { control(["subtype": "set_permission_mode", "mode": mode.rawValue]) }
    }

    func setModel(_ value: String) {
        guard value != model else { return }
        model = value
        UserDefaults.standard.set(value, forKey: "chat.model.\(project.id)")
        guard claude != nil else { return }
        if value == "default" { restartForNewSettings() } else { control(["subtype": "set_model", "model": value]) }
    }

    func setEffort(_ level: String?) {
        guard level != effort else { return }
        effort = level
        UserDefaults.standard.set(level, forKey: "chat.effort.\(project.id)")
        restartForNewSettings()
    }

    func setUsesMCP(_ enabled: Bool) {
        guard enabled != usesMCP else { return }
        usesMCP = enabled
        UserDefaults.standard.set(enabled, forKey: "chat.mcp.\(project.id)")
        restartForNewSettings()
    }

    /// O esforço é fixado ao iniciar o processo: reinicia com `--resume` (a conversa continua igual).
    private func restartForNewSettings() {
        guard claude != nil else { return }
        if isBusy { restartAfterTurn = true } else { stop() }
    }

    /// Começa uma conversa do zero (o histórico anterior continua nas Sessões).
    func newConversation() {
        stop()
        historyToken = nil
        isLoadingHistory = false
        items = []
        sessionId = nil
        onSessionId?(nil)
        totalCost = 0
        historyLoaded = true
    }

    /// Continua uma conversa existente, carregando o histórico do transcript.
    func resume(sessionId: String, transcript: String?) {
        stop()
        self.sessionId = sessionId
        items = []
        historyLoaded = true
        onSessionId?(sessionId)
        if let transcript { loadHistoryInBackground(transcript) }
    }

    /// Carrega o histórico da última conversa na primeira vez que a aba é aberta.
    func loadHistoryIfNeeded(transcript: String?) {
        guard !historyLoaded else { return }
        historyLoaded = true
        if let transcript, sessionId != nil { loadHistoryInBackground(transcript) }
    }

    /// Lê o transcript fora da thread principal; o que chegar nesse meio-tempo fica depois do histórico.
    private func loadHistoryInBackground(_ transcript: String) {
        let token = UUID()
        historyToken = token
        isLoadingHistory = true
        Task {
            let history = await Task.detached(priority: .userInitiated) { Self.loadHistory(transcript) }.value
            // Trocou de conversa no meio do caminho: este histórico não vale mais.
            guard historyToken == token else { return }
            items = history + items
            // O texto em streaming (se houver) andou junto: o índice dele também.
            if let index = streamingIndex { streamingIndex = index + history.count }
            isLoadingHistory = false
        }
    }

    /// Encerra o claude desta conversa (e os agentes em segundo plano dele).
    func stop() {
        claude?.terminate()
        claude = nil
        isRunning = false
        streamingIndex = nil
        backgroundTasks = []
        expirePendingPermissions()
    }

    /// Pedidos de permissão que o Claude não espera mais (parou, encerrou ou cancelou o pedido) deixam de
    /// ficar pendentes: senão a conversa parece ocupada para sempre (ver `isBusy`) e o botão responde a nada.
    private func expirePendingPermissions(requestId: String? = nil) {
        for index in items.indices {
            guard case .permission(var request) = items[index].kind, request.status == .pending,
                  requestId == nil || request.requestId == requestId else { continue }
            request.status = .denied
            items[index].kind = .permission(request)
        }
    }

    /// Trabalhando, esperando você, ou com agentes em segundo plano: o processo precisa continuar vivo.
    /// (O turno de quem lança um agente em segundo plano termina na hora; o agente segue no processo,
    /// e é ele que avisa o Claude quando acabar.)
    private var isBusy: Bool { isRunning || pendingPermissions > 0 || !backgroundTasks.isEmpty }

    /// Ao fechar o MacPet: conversa ocupada (ver `isBusy`) continua rodando e é retomada na próxima
    /// abertura; conversa ociosa é encerrada (dá para continuar depois pelo histórico).
    func shutdown() {
        if isBusy {
            claude?.stopFollowing()
            claude = nil
        } else {
            stop()
        }
    }

    /// Reconecta a um claude que continuou rodando enquanto o MacPet estava fechado.
    func attachIfRunning() {
        guard claude == nil, let detached = DetachedClaude.attach(id: project.id) else { return }
        claude = detached
        let offset = detached.outputSize
        let saved = detached.savedLines(upTo: offset)

        if let initEvent = saved.output.first(where: { $0["type"] as? String == "system" && $0["subtype"] as? String == "init" }) {
            modelName = initEvent["model"] as? String
            if let id = initEvent["session_id"] as? String, id != sessionId {
                sessionId = id
                onSessionId?(id)
            }
        }
        if let sessionId {
            historyLoaded = true
            loadHistoryInBackground(AgentScanner.transcriptPath(sessionId: sessionId, cwd: project.claudeDirectory))
        }
        let results = saved.output.filter { $0["type"] as? String == "result" }
        lastProcessCost = results.last?["total_cost_usd"] as? Double ?? 0
        let lastResult = saved.output.lastIndex { $0["type"] as? String == "result" } ?? -1
        if let tasks = saved.output.last(where: { $0["type"] as? String == "system" && $0["subtype"] as? String == "background_tasks_changed" }) {
            backgroundTasks = Self.backgroundTasks(tasks)
        }
        // Turno em andamento: todo turno (seu ou um que o Claude começou sozinho) abre com um init, e há um depois
        // do último resultado. Contar mensagens enviadas não serve: as mandadas no meio de um turno entram nele
        // e não geram resultado próprio. Mensagem sua que o Claude ainda nem começou: o init chega pelo `follow`.
        isRunning = saved.output.indices.contains { $0 > lastResult && saved.output[$0]["type"] as? String == "system"
            && saved.output[$0]["subtype"] as? String == "init" }
        if isRunning {
            turnStarted = Date()
            items.append(ChatItem(kind: .notice("O Claude continuou trabalhando enquanto o MacPet estava fechado.")))
            if let sessionId { onState?(sessionId, .working) }
        }
        // Pedidos de permissão feitos enquanto o MacPet estava fechado (e ainda sem resposta).
        let answered = Set(saved.input.compactMap { $0["request_id"] as? String })
        for (index, event) in saved.output.enumerated() where index > lastResult
            && event["type"] as? String == "control_request" && !answered.contains(event["request_id"] as? String ?? "") {
            handle(event)
        }
        follow(detached, from: offset)
    }

    // MARK: Processo

    private func start() {
        guard let executable = ClaudeCLI.executable else {
            items.append(ChatItem(kind: .notice("Não encontrei o comando `claude` no seu PATH.")))
            return
        }
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--permission-prompt-tool", "stdio",
                    "--permission-mode", permissionMode.rawValue,
                    // Perguntas de múltipla escolha não têm interface aqui; o Claude pergunta em texto.
                    "--disallowedTools", "AskUserQuestion",
                    // Protocolo das tarefas paralelas (ver TaskPlan); curto e fixo, então fica no cache.
                    "--append-system-prompt", TaskPlan.systemPrompt]
        if model != "default" { args += ["--model", model] }
        if let effort { args += ["--effort", effort] }
        if !usesMCP { args.append("--strict-mcp-config") }
        if let sessionId { args += ["--resume", sessionId] }

        do {
            let detached = try DetachedClaude.launch(id: project.id, executable: executable, arguments: args,
                                                     directory: project.claudeDirectory, environment: ShellEnvironment.variables)
            claude = detached
            // Ao retomar, o custo que o Claude informa é o acumulado da sessão inteira: parte daí.
            lastProcessCost = sessionId.map { Self.sessionCost(AgentScanner.transcriptPath(sessionId: $0, cwd: project.claudeDirectory)) } ?? 0
            follow(detached, from: 0)
        } catch {
            items.append(ChatItem(kind: .notice("Falha ao iniciar o Claude: \(error.localizedDescription)")))
        }
    }

    private func follow(_ detached: DetachedClaude, from offset: UInt64) {
        detached.follow(from: offset, onLine: { [weak self, weak detached] line in
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            DispatchQueue.main.async {
                // Linhas já na fila de um processo que foi parado (Nova conversa, outra sessão): não valem mais.
                guard let self, let detached, detached === self.claude else { return }
                self.handle(json)
            }
        }, onExit: { [weak self, weak detached] errors in
            DispatchQueue.main.async { self?.processEnded(detached, errors: errors) }
        })
    }

    private func processEnded(_ finished: DetachedClaude?, errors: String) {
        guard let finished, finished === claude else { return }
        if isRunning {
            let reason = errors.trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(ChatItem(kind: .notice(reason.isEmpty ? "O Claude encerrou." : "O Claude encerrou: \(reason)")))
        }
        claude = nil
        isRunning = false
        stopping = false
        streamingIndex = nil
        backgroundTasks = []
        expirePendingPermissions()
    }

    private func write(_ object: [String: Any]) {
        guard let claude, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        claude.send(data) { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.items.append(ChatItem(kind: .notice("Não consegui falar com o Claude: \(message)")))
                // A mensagem não chegou: não fica "trabalhando" esperando uma resposta que não vem.
                guard self.isRunning else { return }
                self.isRunning = false
                self.streamingIndex = nil
                if let sessionId = self.sessionId { self.onState?(sessionId, .finished) }
            }
        }
    }

    private func control(_ request: [String: Any]) {
        write(["type": "control_request", "request_id": UUID().uuidString, "request": request])
    }

    // MARK: Eventos

    private func handle(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "system":
            switch event["subtype"] as? String {
            case "init":
                if let id = event["session_id"] as? String, id != sessionId {
                    sessionId = id
                    onSessionId?(id)
                }
                // Turno sem mensagem sua: o Claude voltou sozinho (terminou um agente em segundo plano).
                if !isRunning {
                    isRunning = true
                    turnStarted = Date()
                }
                if let sessionId { onState?(sessionId, .working) }
                modelName = event["model"] as? String
                if let commands = event["slash_commands"] as? [String], !commands.isEmpty {
                    slashCommands = commands
                    SlashCommands.cached = commands
                }
            case "background_tasks_changed":
                backgroundTasks = Self.backgroundTasks(event)
            case "task_notification":
                let task = backgroundTasks.first { $0.id == event["task_id"] as? String }
                let what = task.map { "\($0.isAgent ? "Agente" : "Comando") em segundo plano" } ?? "Tarefa em segundo plano"
                let name = task.map { ": \($0.description)" } ?? ""
                let status = event["status"] as? String
                let verb = status == "completed" ? "terminou" : status == "killed" || status == "stopped" ? "foi interrompido" : "falhou"
                items.append(ChatItem(kind: .notice("\(what) \(verb)\(name)")))
            default:
                break
            }

        case "stream_event":
            guard let inner = event["event"] as? [String: Any] else { return }
            switch inner["type"] as? String {
            case "content_block_start":
                if (inner["content_block"] as? [String: Any])?["type"] as? String == "text" {
                    items.append(ChatItem(kind: .assistant("")))
                    streamingIndex = items.count - 1
                }
            case "content_block_delta":
                if let delta = inner["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String, let index = streamingIndex, index < items.count,
                   case .assistant(let current) = items[index].kind {
                    items[index].kind = .assistant(current + text)
                }
            default:
                break
            }

        case "assistant":
            guard let message = event["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            // Mensagens de subagentes viram progresso no card do agente que os disparou.
            if let parent = event["parent_tool_use_id"] as? String {
                recordChildActivity(parent: parent, content: content)
                return
            }
            for block in content {
                switch block["type"] as? String {
                case "text":
                    let text = block["text"] as? String ?? ""
                    if let index = streamingIndex, index < items.count, case .assistant = items[index].kind {
                        items[index].kind = .assistant(text)
                        streamingIndex = nil
                    } else if !text.isEmpty {
                        streamingIndex = nil
                        items.append(ChatItem(kind: .assistant(text)))
                    }
                case "tool_use":
                    let call = Self.toolCall(id: block["id"] as? String ?? UUID().uuidString,
                                             name: block["name"] as? String ?? "?",
                                             input: block["input"] as? [String: Any] ?? [:])
                    if !items.contains(where: { if case .tool(let t) = $0.kind { return t.id == call.id } else { return false } }) {
                        items.append(ChatItem(kind: .tool(call)))
                    }
                default:
                    break
                }
            }

        case "user":
            guard (event["parent_tool_use_id"] as? String) == nil,
                  let message = event["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            for block in content where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String else { continue }
                attachResult(id: id, text: Self.resultText(block["content"]), isError: block["is_error"] as? Bool ?? false)
            }

        case "rate_limit_event":
            if let info = event["rate_limit_info"] as? [String: Any] { onRateLimits?(info) }

        case "control_request":
            guard let requestId = event["request_id"] as? String,
                  let request = event["request"] as? [String: Any],
                  request["subtype"] as? String == "can_use_tool" else { return }
            let input = request["input"] as? [String: Any] ?? [:]
            let tool = Self.toolCall(id: request["tool_use_id"] as? String ?? requestId,
                                     name: request["tool_name"] as? String ?? "?", input: input)
            let suggestions = request["permission_suggestions"] as? [[String: Any]]
            let label = suggestions?.first(where: { $0["type"] as? String == "setMode" && $0["mode"] as? String == "acceptEdits" })
                .map { _ in "Aceitar edições nesta sessão" }
                ?? (suggestions?.isEmpty == false ? "Sempre permitir isto" : nil)
            items.append(ChatItem(kind: .permission(PermissionRequest(
                requestId: requestId, tool: tool,
                input: (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8),
                suggestions: suggestions.flatMap { try? JSONSerialization.data(withJSONObject: $0) },
                suggestionLabel: label
            ))))
            if let sessionId { onState?(sessionId, .waiting) }
            onAttention?(tool.summary.isEmpty ? tool.name : "\(tool.name): \(tool.summary)")

        case "control_cancel_request":
            guard let requestId = event["request_id"] as? String else { return }
            expirePendingPermissions(requestId: requestId)
            if let sessionId, isRunning, pendingPermissions == 0 { onState?(sessionId, .working) }

        case "result":
            isRunning = false
            if stopping {
                items.append(ChatItem(kind: .notice("Parado.")))
                // Interrompido com um pedido de permissão aberto: o Claude não vai mais esperar a resposta.
                expirePendingPermissions()
            }
            stopping = false
            streamingIndex = nil
            let total = event["total_cost_usd"] as? Double ?? 0
            let cost = total >= lastProcessCost ? total - lastProcessCost : total
            lastProcessCost = total
            totalCost += cost
            let seconds = turnStarted.map { Date().timeIntervalSince($0) } ?? 0
            let isError = event["is_error"] as? Bool ?? false
            items.append(ChatItem(kind: .result(cost: cost, seconds: seconds, isError: isError)))
            if isError, let message = event["result"] as? String { items.append(ChatItem(kind: .notice(message))) }
            // O aviso de "terminou" vem do hook Stop (ClaudeSessionStore); aqui só atualizamos o estado.
            if let sessionId { onState?(sessionId, .finished) }
            // Com agentes em segundo plano, espera: o Claude volta sozinho quando eles terminarem.
            if restartAfterTurn, backgroundTasks.isEmpty {
                restartAfterTurn = false
                stop()
            }

        default:
            break
        }
    }

    private static func backgroundTasks(_ event: [String: Any]) -> [BackgroundTask] {
        (event["tasks"] as? [[String: Any]] ?? []).compactMap { task in
            // "ambient" (ex.: o observador de um artefato publicado) nunca termina e não traz resultado:
            // não é trabalho pendente, então não segura a conversa nem aparece como "em segundo plano".
            guard let id = task["task_id"] as? String, task["ambient"] as? Bool != true else { return nil }
            return BackgroundTask(id: id, description: task["description"] as? String ?? "",
                                  isAgent: (task["task_type"] as? String)?.contains("agent") ?? false)
        }
    }

    private func recordChildActivity(parent: String, content: [[String: Any]]) {
        guard let index = items.lastIndex(where: { if case .tool(let t) = $0.kind { return t.id == parent } else { return false } }),
              case .tool(var call) = items[index].kind else { return }
        for block in content {
            if block["type"] as? String == "tool_use" {
                let child = Self.toolCall(id: "", name: block["name"] as? String ?? "?", input: block["input"] as? [String: Any] ?? [:])
                call.childSteps += 1
                call.childLast = "\(child.name) \(child.summary)"
            } else if block["type"] as? String == "text", let text = block["text"] as? String, !text.isEmpty {
                call.childLast = String(text.replacingOccurrences(of: "\n", with: " ").prefix(160))
            }
        }
        items[index].kind = .tool(call)
    }

    private func attachResult(id: String, text: String, isError: Bool) {
        guard let index = items.lastIndex(where: { if case .tool(let t) = $0.kind { return t.id == id } else { return false } }),
              case .tool(var call) = items[index].kind else { return }
        call.result = text
        call.isError = isError
        items[index].kind = .tool(call)
    }

    // MARK: Interpretação das ferramentas

    nonisolated static func toolCall(id: String, name: String, input: [String: Any]) -> ToolCall {
        func string(_ key: String) -> String? { input[key] as? String }
        let file = (string("file_path") ?? string("notebook_path") ?? string("path")).map { URL(fileURLWithPath: $0).lastPathComponent }
        var summary = ""
        var detail: String?
        var edits: [(String, String)] = []
        switch name {
        case "Bash":
            summary = string("description") ?? string("command") ?? ""
            detail = string("command")
        case "Edit":
            summary = file ?? ""
            edits = [(string("old_string") ?? "", string("new_string") ?? "")]
        case "MultiEdit":
            summary = file ?? ""
            edits = (input["edits"] as? [[String: Any]] ?? []).map { ($0["old_string"] as? String ?? "", $0["new_string"] as? String ?? "") }
        case "Write":
            summary = file ?? ""
            detail = string("content")
        case "Read":
            summary = file ?? ""
        case "Grep":
            summary = string("pattern") ?? ""
        case "Glob":
            summary = string("pattern") ?? ""
        case "WebFetch":
            summary = string("url") ?? ""
        case "WebSearch":
            summary = string("query") ?? ""
        case "Task", "Agent":
            summary = string("description") ?? ""
            detail = string("prompt")
        case "TodoWrite":
            let todos = input["todos"] as? [[String: Any]] ?? []
            summary = "\(todos.count) tarefas"
            detail = todos.map { todo in
                let mark = switch todo["status"] as? String {
                case "completed": "✓"
                case "in_progress": "▸"
                default: "○"
                }
                return "\(mark) \(todo["content"] as? String ?? "")"
            }.joined(separator: "\n")
        case "ExitPlanMode":
            summary = "Plano pronto para aprovação"
            detail = string("plan")
        default:
            summary = file ?? input.keys.sorted().first.flatMap { input[$0] as? String } ?? ""
            if let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]) {
                detail = String(decoding: data, as: UTF8.self)
            }
        }
        return ToolCall(id: id, name: name, summary: summary, detail: detail, edits: edits)
    }

    nonisolated static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    /// Reconstrói o chat a partir do transcript JSONL (só a conversa principal, sem subagentes).
    /// `includeSidechain`: transcripts de subagentes são todos "sidechain"; a primeira mensagem é o pedido.
    /// Último custo acumulado gravado no transcript (linhas `cost-state`), lendo só o final do arquivo.
    nonisolated static func sessionCost(_ path: String) -> Double {
        guard let handle = FileHandle(forReadingAtPath: path) else { return 0 }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 4_000_000 ? size - 4_000_000 : 0)
        guard let data = try? handle.readToEnd() else { return 0 }
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard line.count < 200_000, let text = String(data: line, encoding: .utf8), text.contains("\"cost-state\""),
                  let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let cost = json["totalCostUSD"] as? Double else { continue }
            return cost
        }
        return 0
    }

    /// Quanto do fim do transcript é lido. Conversas longas passam de 900 MB; a tela só mostra o final.
    nonisolated static let historyTailBytes: UInt64 = 8_000_000

    nonisolated static func loadHistory(_ path: String, includeSidechain: Bool = false) -> [ChatItem] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > historyTailBytes ? size - historyTailBytes : 0
        try? handle.seek(toOffset: offset)
        guard var data = try? handle.readToEnd() else { return [] }
        // Começou no meio de uma linha: descarta até a próxima.
        if offset > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            data = data[data.index(after: newline)...]
        }
        var items: [ChatItem] = []
        var toolIndex: [String: Int] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            autoreleasepool {
                guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      includeSidechain || json["isSidechain"] as? Bool != true,
                      let message = json["message"] as? [String: Any] else { return }
                switch json["type"] as? String {
                case "user":
                    if json["isMeta"] as? Bool == true { return }
                    if let text = message["content"] as? String {
                        if !text.hasPrefix("<") { items.append(ChatItem(kind: .user(text))) }
                    } else if let blocks = message["content"] as? [[String: Any]] {
                        var texts: [String] = []
                        var images: [ChatImage] = []
                        for block in blocks {
                            if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String,
                               let index = toolIndex[id], case .tool(var call) = items[index].kind {
                                call.result = resultText(block["content"])
                                call.isError = block["is_error"] as? Bool ?? false
                                items[index].kind = .tool(call)
                            } else if block["type"] as? String == "text", let text = block["text"] as? String, !text.hasPrefix("<") {
                                texts.append(text)
                            } else if block["type"] as? String == "image", let image = ChatImage(block: block) {
                                images.append(image)
                            }
                        }
                        if !texts.isEmpty || !images.isEmpty {
                            items.append(ChatItem(kind: .user(texts.joined(separator: "\n\n"), images: images)))
                        }
                    }
                case "assistant":
                    for block in message["content"] as? [[String: Any]] ?? [] {
                        if block["type"] as? String == "text", let text = block["text"] as? String, !text.isEmpty {
                            items.append(ChatItem(kind: .assistant(text)))
                        } else if block["type"] as? String == "tool_use" {
                            let call = toolCall(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "?",
                                                input: block["input"] as? [String: Any] ?? [:])
                            items.append(ChatItem(kind: .tool(call)))
                            toolIndex[call.id] = items.count - 1
                        }
                    }
                default:
                    break
                }
            }
        }
        if offset == 0, includeSidechain, let first = items.first, case .user = first.kind { items.removeFirst() }
        // Conversas longas: mantém o final, que é o que importa para continuar.
        if items.count > 400 {
            items = Array(items.suffix(400))
        }
        if offset > 0 || items.count == 400 {
            items.insert(ChatItem(kind: .notice("Mostrando o final da conversa.")), at: 0)
        }
        return items
    }
}

/// Junta pedaços de stdout em linhas completas (o stream-json é uma linha por evento).
final class LineReader: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let onLine: (Data) -> Void

    init(onLine: @escaping (Data) -> Void) {
        self.onLine = onLine
    }

    func feed(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        lines.forEach(onLine)
    }
}
