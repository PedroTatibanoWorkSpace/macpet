import Foundation

struct SavedCommand: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var command: String
    /// Servidor que caiu sozinho volta a rodar (até 3 vezes em 2 minutos).
    var autoRestart = false

    init(name: String, command: String, autoRestart: Bool = false) {
        self.name = name
        self.command = command
        self.autoRestart = autoRestart
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        autoRestart = try container.decodeIfPresent(Bool.self, forKey: .autoRestart) ?? false
    }
}

/// Conversa fixada no projeto: fica na barra lateral e sempre retoma a mesma sessão do Claude.
struct PinnedChat: Codable, Identifiable, Hashable {
    var id = UUID()
    var sessionId: String
    var title: String
    var pinned = Date()
    /// Pasta onde a conversa nasceu, quando não é a do projeto (o Claude Code só retoma uma conversa a partir
    /// da pasta dela). nil: a pasta do projeto.
    var cwd: String?

    /// Títulos vêm do primeiro prompt às vezes: primeira linha, até ~48 caracteres, cortando em palavra.
    static func shortTitle(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? text
        guard line.count > 48 else { return line }
        let cut = line.prefix(48)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }
}

struct Project: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var name: String
    var commands: [SavedCommand] = []
    /// Última conversa com o Claude, retomada ao reabrir o app.
    var lastSessionId: String?
    /// `ProjectColor` escolhida (nil: derivada do nome).
    var color: String?
    /// Som das notificações deste projeto: nil usa o padrão do sistema, "" deixa sem som.
    var sound: String?
    /// Tarefas paralelas (worktrees). Opcional para ler projetos salvos antes delas existirem.
    var tasks: [ProjectTask]?
    var pins: [PinnedChat]?
    /// Só nos espaços montados em memória (tarefa ou conversa fixada): o projeto dono.
    var parentId: UUID?
    var isPinnedChat: Bool?
    /// Só em conversa fixada de outra pasta: onde o chat roda o Claude. Git e terminais seguem em `path`.
    var chatDirectory: String?

    /// Pasta em que o Claude deste chat roda (e onde está o transcript da conversa).
    var claudeDirectory: String { chatDirectory ?? path }

    var isPinned: Bool { isPinnedChat == true }
    var isTask: Bool { parentId != nil && !isPinned }
}

/// Projetos do hub e os objetos vivos de cada um (chat, git, terminais).
@MainActor
final class ProjectStore: ObservableObject {
    @Published var projects: [Project] = [] {
        didSet { save() }
    }
    @Published var selectedProjectId: UUID?
    /// O que está aberto na janela principal (um projeto ou uma tela do Claude Code).
    @Published var hubSelection: HubSelection = .section(.overview)
    /// Pedido para trocar a aba do projeto aberto (atalhos e depuração).
    @Published var tabRequest: ProjectTab?

    private var chats: [UUID: ChatSession] = [:]
    private var repos: [UUID: GitRepo] = [:]
    private var terminals: [UUID: TerminalGroup] = [:]
    var onAttention: ((Project, String) -> Void)?
    var onRateLimits: (([String: Any]) -> Void)?
    var onSessionState: ((String, String, ClaudeSessionState) -> Void)?

    private let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacPet/projects.json")

    init() {
        // Na primeira abertura começa vazio: os projetos entram pelo botão de adicionar no painel.
        if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode([Project].self, from: data) {
            projects = stored
        }
        assignMissingColors()
        // Conversas fixadas antes do título curto.
        for index in projects.indices {
            for pinIndex in (projects[index].pins ?? []).indices where (projects[index].pins?[pinIndex].title.count ?? 0) > 50 {
                projects[index].pins?[pinIndex].title = PinnedChat.shortTitle(projects[index].pins![pinIndex].title)
            }
        }
        selectedProjectId = projects.first?.id
        if let first = projects.first { hubSelection = .project(first.id) }
    }

    /// Projetos sem cor ganham a próxima livre da paleta, para não repetirem.
    private func assignMissingColors() {
        guard projects.contains(where: { $0.color == nil }) else { return }
        var used = Set(projects.compactMap(\.color))
        for index in projects.indices where projects[index].color == nil {
            let next = ProjectColor.allCases.first { !used.contains($0.rawValue) } ?? ProjectColor.allCases[index % ProjectColor.allCases.count]
            projects[index].color = next.rawValue
            used.insert(next.rawValue)
        }
    }

    var selected: Project? { projects.first { $0.id == selectedProjectId } }

    func add(path: String) {
        if let existing = projects.first(where: { $0.path == path }) {
            selectedProjectId = existing.id
            return
        }
        let project = Self.makeProject(path)
        projects.append(project)
        assignMissingColors()
        selectedProjectId = project.id
        hubSelection = .project(project.id)
    }

    func remove(_ project: Project) {
        for id in (project.tasks ?? []).map(\.id) + (project.pins ?? []).map(\.id) {
            chats[id]?.stop()
            terminals[id]?.closeAll()
        }
        chats[project.id]?.stop()
        terminals[project.id]?.closeAll()
        chats[project.id] = nil
        repos[project.id] = nil
        terminals[project.id] = nil
        projects.removeAll { $0.id == project.id }
        if selectedProjectId == project.id { selectedProjectId = projects.first?.id }
        if hubSelection == .project(project.id) { hubSelection = projects.first.map { .project($0.id) } ?? .section(.overview) }
    }

    func select(path: String) {
        if let workspace = workspace(atPath: path) {
            selectedProjectId = workspace.parentId ?? workspace.id
            hubSelection = .project(workspace.id)
        }
    }

    // MARK: Espaços de trabalho (projeto ou tarefa)

    /// Projeto, ou a tarefa vista como um projeto (pasta da worktree, mesmos comandos, cor e som do dono).
    func workspace(id: UUID) -> Project? {
        if let project = projects.first(where: { $0.id == id }) { return project }
        for project in projects {
            if let task = project.tasks?.first(where: { $0.id == id }) { return workspace(task, in: project) }
            if let pin = project.pins?.first(where: { $0.id == id }) { return workspace(pin, in: project) }
        }
        return nil
    }

    /// Conversa fixada: mesma pasta do projeto, sessão própria.
    func workspace(_ pin: PinnedChat, in project: Project) -> Project {
        Project(id: pin.id, path: project.path, name: pin.title, commands: project.commands,
                lastSessionId: pin.sessionId, color: project.color, sound: project.sound,
                parentId: project.id, isPinnedChat: true, chatDirectory: pin.cwd)
    }

    /// Fixa uma conversa no projeto (ou devolve a já fixada).
    @discardableResult
    func pin(sessionId: String, title: String, in project: Project, cwd: String? = nil) -> Project? {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return nil }
        if let existing = projects[index].pins?.first(where: { $0.sessionId == sessionId }) {
            return workspace(existing, in: projects[index])
        }
        let pin = PinnedChat(sessionId: sessionId, title: PinnedChat.shortTitle(title),
                             cwd: cwd == project.path ? nil : cwd)
        projects[index].pins = (projects[index].pins ?? []) + [pin]
        // Mesmo modo, modelo e esforço do projeto.
        for key in ["chat.mode", "chat.model", "chat.effort", "chat.mcp"] {
            if let value = UserDefaults.standard.object(forKey: "\(key).\(project.id)") {
                UserDefaults.standard.set(value, forKey: "\(key).\(pin.id)")
            }
        }
        return workspace(pin, in: projects[index])
    }

    func renamePin(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = projects.firstIndex(where: { $0.pins?.contains { $0.id == id } == true }),
              let pinIndex = projects[index].pins?.firstIndex(where: { $0.id == id }) else { return }
        projects[index].pins?[pinIndex].title = trimmed
    }

    func unpin(_ id: UUID) {
        guard let index = projects.firstIndex(where: { $0.pins?.contains { $0.id == id } == true }) else { return }
        chats[id]?.stop()
        chats[id] = nil
        repos[id] = nil
        terminals[id]?.closeAll()
        terminals[id] = nil
        projects[index].pins?.removeAll { $0.id == id }
        if hubSelection == .project(id) { hubSelection = .project(projects[index].id) }
    }

    func workspace(_ task: ProjectTask, in project: Project) -> Project {
        Project(id: task.id, path: task.path, name: task.name, commands: project.commands,
                lastSessionId: task.lastSessionId, color: project.color, sound: project.sound, parentId: project.id)
    }

    /// Tarefas são mais específicas que o projeto: a pasta delas vence.
    func workspace(atPath path: String) -> Project? {
        func contains(_ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        for project in projects {
            if let task = project.tasks?.first(where: { contains($0.path) }) { return workspace(task, in: project) }
        }
        return projects.first { contains($0.path) }
    }

    func task(id: UUID) -> (task: ProjectTask, project: Project)? {
        for project in projects {
            if let task = project.tasks?.first(where: { $0.id == id }) { return (task, project) }
        }
        return nil
    }

    /// Salva um projeto ou, para um espaço de tarefa, a conversa na tarefa e cor/som/comandos no dono.
    func update(_ project: Project) {
        if let parentId = project.parentId {
            guard let index = projects.firstIndex(where: { $0.id == parentId }) else { return }
            projects[index].color = project.color
            projects[index].sound = project.sound
            projects[index].commands = project.commands
            if let taskIndex = projects[index].tasks?.firstIndex(where: { $0.id == project.id }) {
                projects[index].tasks?[taskIndex].lastSessionId = project.lastSessionId
            }
            // A conversa fixada acompanha a sessão (o Claude pode trocar o id ao retomar).
            if let pinIndex = projects[index].pins?.firstIndex(where: { $0.id == project.id }), let session = project.lastSessionId {
                projects[index].pins?[pinIndex].sessionId = session
            }
            return
        }
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        var updated = project
        updated.tasks = projects[index].tasks
        updated.pins = projects[index].pins
        projects[index] = updated
    }

    // MARK: Tarefas

    /// Pedido para abrir a folha de nova tarefa (barra lateral, cabeçalho).
    @Published var newTaskRequest: Project?

    func createTask(in project: Project, name: String, branch: String, base: String) async throws -> (Project, Worktrees.Preparation) {
        let (task, preparation) = try await Worktrees.create(in: project, name: name, branch: branch, base: base)
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { throw Worktrees.Failure(message: "Projeto removido.") }
        projects[index].tasks = (projects[index].tasks ?? []) + [task]
        // Tarefas trabalham no código: sem MCPs por padrão, o contexto de cada agente fica bem menor.
        UserDefaults.standard.set(false, forKey: "chat.mcp.\(task.id)")
        // A tarefa começa com o mesmo modo, modelo e esforço do projeto.
        for key in ["chat.mode", "chat.model", "chat.effort"] {
            if let value = UserDefaults.standard.string(forKey: "\(key).\(project.id)") {
                UserDefaults.standard.set(value, forKey: "\(key).\(task.id)")
            }
        }
        return (workspace(task, in: projects[index]), preparation)
    }

    func removeTask(_ taskId: UUID, deleteBranch: Bool) async throws {
        guard let (task, project) = task(id: taskId) else { return }
        chats[task.id]?.stop()
        terminals[task.id]?.closeAll()
        try await Worktrees.remove(task, from: project, deleteBranch: deleteBranch)
        chats[task.id] = nil
        repos[task.id] = nil
        terminals[task.id] = nil
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index].tasks?.removeAll { $0.id == task.id }
        }
        if hubSelection == .project(task.id) { hubSelection = .project(project.id) }
    }

    func chat(for project: Project) -> ChatSession {
        if let chat = chats[project.id] { return chat }
        let chat = ChatSession(project: project)
        chat.onSessionId = { [weak self] id in
            guard let self, var current = self.workspace(id: project.id) else { return }
            current.lastSessionId = id
            self.update(current)
        }
        chat.onAttention = { [weak self] message in self?.onAttention?(project, message) }
        chat.onRateLimits = { [weak self] info in self?.onRateLimits?(info) }
        chat.onState = { [weak self] sessionId, state in self?.onSessionState?(sessionId, project.path, state) }
        chats[project.id] = chat
        return chat
    }

    /// Chat já criado (sem criar um novo), para indicadores na barra lateral.
    func existingChat(for project: Project) -> ChatSession? { chats[project.id] }

    func repo(for project: Project) -> GitRepo {
        if let repo = repos[project.id] { return repo }
        let repo = GitRepo(path: project.path)
        repos[project.id] = repo
        return repo
    }

    /// Terminais abertos de todos os projetos (para o monitor de servidores).
    var openTerminalGroups: [(projectId: UUID, group: TerminalGroup)] {
        terminals.map { ($0.key, $0.value) }
    }

    func terminalGroup(for project: Project) -> TerminalGroup {
        if let group = terminals[project.id] { return group }
        let group = TerminalGroup(directory: project.path, projectName: project.name)
        terminals[project.id] = group
        return group
    }

    /// Ao fechar o app: turnos em andamento continuam rodando (ver `ChatSession.shutdown`).
    func stopAll() {
        chats.values.forEach { $0.shutdown() }
        terminals.values.forEach { $0.closeAll() }
    }

    /// Reconecta às conversas que continuaram rodando enquanto o MacPet estava fechado.
    func attachRunningChats() {
        let workspaces = projects.flatMap { project in
            [project] + (project.pins ?? []).map { workspace($0, in: project) } + (project.tasks ?? []).map { workspace($0, in: project) }
        }
        for workspace in workspaces where FileManager.default.fileExists(atPath: DetachedClaude.directory(for: workspace.id).path) {
            chat(for: workspace).attachIfRunning()
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(projects) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func makeProject(_ path: String) -> Project {
        Project(path: path, name: URL(fileURLWithPath: path).lastPathComponent, commands: detectCommands(path))
    }

    /// Sugere comandos a partir dos scripts do package.json (dev/start/test/build…).
    static func detectCommands(_ path: String) -> [SavedCommand] {
        let packageURL = URL(fileURLWithPath: path).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any] else { return [] }
        let fm = FileManager.default
        let runner = fm.fileExists(atPath: "\(path)/pnpm-lock.yaml") ? "pnpm"
            : fm.fileExists(atPath: "\(path)/yarn.lock") ? "yarn"
            : fm.fileExists(atPath: "\(path)/bun.lockb") || fm.fileExists(atPath: "\(path)/bun.lock") ? "bun run"
            : "npm run"
        let preferred = ["dev", "start:dev", "start", "test", "test:watch", "build", "lint", "migrate", "prisma:migrate"]
        return preferred.filter { scripts[$0] != nil }.prefix(5).map {
            SavedCommand(name: $0, command: "\(runner) \($0)")
        }
    }
}
