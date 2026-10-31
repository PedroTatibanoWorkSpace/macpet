import AppKit
import SwiftUI

enum ProjectTab: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case changes = "Alterações"
    case agents = "Agentes"
    case terminal = "Terminal"

    var id: String { rawValue }

    init?(debugName: String) {
        guard let tab = Self.allCases.first(where: { "\($0)" == debugName }) else { return nil }
        self = tab
    }
}

/// Tudo de um projeto num lugar: conversa com o Claude, revisão/commits e terminais.
/// O cabeçalho (nome, branch, abas) mora na barra da janela.
struct ProjectView: View {
    let project: Project
    @EnvironmentObject private var store: ProjectStore
    @State private var tab: ProjectTab = .chat
    @State private var focusToolUse: String?

    var body: some View {
        let chat = store.chat(for: project)
        let repo = store.repo(for: project)
        ZStack {
            ChatView(chat: chat).opacity(tab == .chat ? 1 : 0).allowsHitTesting(tab == .chat)
                .environment(\.openAgent, OpenAgentAction { toolUseId in
                    focusToolUse = toolUseId
                    tab = .agents
                })
            if tab == .changes {
                ChangesView(repo: repo, project: project)
            }
            if tab == .agents {
                ProjectAgentsPane(chat: chat, project: project, focusToolUse: $focusToolUse)
            }
            if tab == .terminal {
                TerminalPane(group: store.terminalGroup(for: project), project: project)
            }
        }
        .background(Theme.ink)
        .id(project.id)
        .navigationTitle(project.name)
        .modifier(HideToolbarTitle())
        .modifier(ProjectToolbar(project: currentProject, chat: chat, repo: repo, tab: $tab))
        .onChange(of: store.tabRequest) { _, request in
            if let request { tab = request; store.tabRequest = nil }
        }
        .onAppear {
            if let request = store.tabRequest { tab = request; store.tabRequest = nil }
        }
    }

    private var currentProject: Project {
        store.workspace(id: project.id) ?? project
    }
}

private struct ProjectToolbar: ViewModifier {
    let project: Project
    @ObservedObject var chat: ChatSession
    @ObservedObject var repo: GitRepo
    @Binding var tab: ProjectTab
    @EnvironmentObject private var store: ProjectStore
    @State private var confirmingRemoval = false
    @State private var removalInfo = ""
    @State private var taskMessage: String?
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var editingAppearance = false

    /// Projeto dono (o próprio projeto, ou o dono da tarefa).
    private var owner: Project { project.parentId.flatMap(store.workspace(id:)) ?? project }
    private var task: ProjectTask? { store.task(id: project.id)?.task }

    func body(content: Content) -> some View {
        content
            .toolbar {
                // No macOS 26 cada item da barra ganha uma cápsula de vidro; os nossos já se desenham sozinhos.
                if #available(macOS 26, *) {
                    ToolbarItem(placement: .navigation) { title }.sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .principal) { tabs }.sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .primaryAction) { actions }.sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) { title }
                    ToolbarItem(placement: .principal) { tabs }
                    ToolbarItem(placement: .primaryAction) { actions }
                }
            }
            // "Remover tarefa…" no botão direito da barra lateral: a confirmação é a mesma do menu desta tela.
            .onChange(of: store.removeTaskRequest) { _, request in handleRemovalRequest(request) }
            .onAppear { handleRemovalRequest(store.removeTaskRequest) }
            .mpDialog(isPresented: $confirmingRemoval, title: "Remover a tarefa \(project.name)?", message: removalInfo, actions: [
                MPDialogAction(label: "Cancelar"),
                MPDialogAction(label: "Remover e apagar a branch", variant: .danger) { remove(deleteBranch: true) },
                MPDialogAction(label: "Remover e manter a branch", variant: .primary) { remove(deleteBranch: false) },
            ])
            .mpSheet(isPresented: $renaming) {
                MPDialogCard(title: "Renomear conversa fixada", actions: [
                    MPDialogAction(label: "Cancelar"),
                    MPDialogAction(label: "Renomear", variant: .primary) { store.renamePin(project.id, to: newTitle) },
                ]) {
                    TextField("Nome", text: $newTitle)
                }
            }
            .mpSheet(isPresented: $editingAppearance) {
                ProjectAppearanceSheet(project: owner)
            }
            .mpDialog(isPresented: Binding(get: { taskMessage != nil }, set: { if !$0 { taskMessage = nil } }),
                      title: "Tarefa", message: taskMessage, actions: [MPDialogAction(label: "OK", variant: .primary)])
            .task(id: project.id) { await repo.refresh() }
            // Voltou para o app (ex.: trocou de branch no terminal): atualiza branch e alterações.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await repo.refresh() }
            }
    }

    private var tabs: some View {
        MPTabs(items: ProjectTab.allCases.map { item in
            switch item {
            case .chat: .init(value: item, label: "Chat", count: chat.pendingPermissions, waiting: true)
            case .changes: .init(value: item, label: "Alterações", count: repo.files.count)
            case .agents: .init(value: item, label: "Agentes")
            case .terminal: .init(value: item, label: "Terminal")
            }
        }, selection: $tab)
        .fixedSize()
    }

    private var actions: some View {
        HStack(spacing: 6) {
            MPIconButton(icon: "plus.square.on.square", label: "Nova tarefa em paralelo em \(owner.name)", glass: true) {
                store.newTaskRequest = owner
            }
            MPMenuButton(entries: menuEntries) {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textMuted)
                    .frame(width: 28, height: 28)
                    .background(Theme.plumage, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.quill))
                    .contentShape(Capsule())
            }
            .help("Opções do projeto")
        }
    }

    private func menuEntries() -> [MPMenuEntry] {
        var entries: [MPMenuEntry] = []
        if let task {
            entries += [.header("Tarefa"),
                        .item("Trazer para \(task.baseBranch) (merge)", icon: "arrow.triangle.merge") { merge(task) },
                        .item("Remover tarefa…", icon: "trash", danger: true) { prepareRemoval(task) },
                        .divider]
        }
        if project.isPinned {
            entries += [.header("Conversa fixada"),
                        .item("Renomear…", icon: "pencil") { newTitle = project.name; renaming = true },
                        .item("Desafixar", icon: "pin.slash") { store.unpin(project.id) },
                        .divider]
        }
        entries += [.item("Abrir no Finder", icon: "folder") { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) },
                    .item("Abrir no VS Code", icon: "chevron.left.forwardslash.chevron.right") { openInVSCode() },
                    .divider,
                    .item("Cor e som do projeto…", icon: "paintpalette") { editingAppearance = true }]
        return entries
    }

    private var title: some View {
        HStack(spacing: 10) {
            ProjectMonogram(project: owner, size: 24)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    if project.parentId != nil {
                        Text(owner.name).foregroundStyle(Theme.textMuted)
                        Text("›").foregroundStyle(Theme.textFaint)
                    }
                    if project.isPinned {
                        Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(ProjectColor.for(owner).color)
                    }
                    Text(project.name).truncationMode(.tail)
                }
                .font(Theme.display(15))
                .lineLimit(1)
                .frame(maxWidth: 320, alignment: .leading)
                // Na barra da janela o Menu vira um controle do AppKit; o .id garante o rótulo novo ao trocar de branch.
                if repo.isRepo {
                    BranchMenu(repo: repo, branch: repo.branch, busy: repo.busy).id(repo.branch)
                }
            }
        }
        .padding(.horizontal, 4)
        .help(project.path)
    }

    private func merge(_ task: ProjectTask) {
        Task {
            do {
                taskMessage = try await Worktrees.merge(task, into: owner)
                await store.repo(for: owner).refresh()
            } catch {
                taskMessage = error.localizedDescription
            }
        }
    }

    private func handleRemovalRequest(_ request: UUID?) {
        guard let request, request == project.id, let task else { return }
        store.removeTaskRequest = nil
        prepareRemoval(task)
    }

    /// Conta o que se perderia antes de perguntar.
    private func prepareRemoval(_ task: ProjectTask) {
        Task {
            let changes = await Worktrees.pendingChanges(task)
            let unmerged = await Worktrees.unmergedCommits(task, in: owner)
            var lines = ["A tarefa sai da barra e a pasta dela é apagada (a conversa continua nas Sessões).",
                         "Mantendo a branch, \(task.branch) continua no git com todos os commits: dá para abrir um PR ou retomar depois."]
            if changes > 0 { lines.append("⚠️ \(changes) arquivo(s) com alterações não commitadas serão perdidos.") }
            if unmerged > 0 {
                lines.append("Ela tem \(unmerged) commit(s) fora de \(task.baseBranch): apagar a branch perde esses commits (a menos que já estejam num PR).")
            } else {
                lines.append("A branch \(task.branch) não tem nada fora de \(task.baseBranch).")
            }
            removalInfo = lines.joined(separator: "\n\n")
            confirmingRemoval = true
        }
    }

    private func remove(deleteBranch: Bool) {
        let id = project.id
        Task {
            do { try await store.removeTask(id, deleteBranch: deleteBranch) } catch { taskMessage = error.localizedDescription }
        }
    }

    private func openInVSCode() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: project.path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Cor e som de notificação do projeto (vale para as tarefas e conversas fixadas dele).
private struct ProjectAppearanceSheet: View {
    let project: Project
    @EnvironmentObject private var store: ProjectStore
    @State private var color: String = ""
    @State private var sound: String = "default"

    var body: some View {
        MPDialogCard(title: "Cor e som de \(project.name)", actions: [
            MPDialogAction(label: "Cancelar"),
            MPDialogAction(label: "Salvar", variant: .primary) { save() },
        ]) {
            VStack(alignment: .leading, spacing: 16) {
                MPField(label: "Cor") {
                    HStack(spacing: 10) {
                        ForEach(ProjectColor.allCases) { option in
                            Button {
                                color = option.rawValue
                            } label: {
                                Circle().fill(option.color.gradient)
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().strokeBorder(Theme.text, lineWidth: color == option.rawValue ? 2 : 0).padding(-4))
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help(option.label)
                        }
                    }
                    .padding(.vertical, 4)
                }
                MPField(label: "Som das notificações", hint: "Toca uma prévia ao escolher.") {
                    HStack {
                        MPSelect(icon: "speaker.wave.2", title: soundTitle, options: soundOptions, selection: Binding(get: { sound }, set: { newValue in
                            sound = newValue
                            if newValue == "default" { NSSound.beep() } else if !newValue.isEmpty { NotificationSounds.play(newValue) }
                        }))
                        Spacer()
                    }
                }
            }
        }
        .onAppear {
            color = project.color ?? ProjectColor.for(project).rawValue
            sound = project.sound ?? "default"
        }
    }

    private var soundTitle: String { sound == "default" ? "Padrão do sistema" : sound.isEmpty ? "Sem som" : sound }

    private var soundOptions: [MPSelect<String>.Option] {
        [.init(value: "default", label: "Padrão do sistema"), .init(value: "", label: "Sem som")]
            + NotificationSounds.all.map { .init(value: $0, label: $0) }
    }

    private func save() {
        guard var updated = store.workspace(id: project.id) else { return }
        updated.color = color
        updated.sound = sound == "default" ? nil : sound
        store.update(updated)
    }
}

/// O branch no cabeçalho: um clique troca de branch, cria uma nova ou busca as remotas.
private struct BranchMenu: View {
    let repo: GitRepo
    let branch: String?
    let busy: String?
    @State private var local: [String] = []
    @State private var remote: [String] = []
    @State private var creating = false
    @State private var newName = ""
    /// Branch que não deu para trocar (normalmente por alterações não commitadas).
    @State private var blocked: String?

    var body: some View {
        MPMenuButton(entries: entries) {
            HStack(spacing: 4) {
                if busy == "Trocando de branch" {
                    MPLoaderDots().scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.triangle.branch")
                }
                Text(branch ?? "—")
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .font(Theme.mono(10))
            .foregroundStyle(Theme.textMuted)
            .contentShape(Rectangle())
        }
        .fixedSize()
        .help("Trocar de branch")
        .task(id: branch) { await load() }
        .mpDialog(isPresented: Binding(get: { blocked != nil }, set: { if !$0 { blocked = nil } }),
                  title: "Não deu para trocar de branch",
                  message: (repo.lastError ?? "") + "\n\nPosso guardar suas alterações num stash (git stash) antes de trocar; depois você recupera com git stash pop.",
                  actions: [
                    MPDialogAction(label: "Cancelar"),
                    MPDialogAction(label: "Guardar alterações e trocar", variant: .primary) {
                        if let name = blocked { Task { await repo.switchBranch(name, stash: true) } }
                    },
                  ])
        .mpSheet(isPresented: $creating) {
            MPDialogCard(title: "Nova branch",
                         message: "Sai de \(branch ?? "—") e leva junto as alterações que ainda não foram commitadas.",
                         actions: [MPDialogAction(label: "Cancelar"), MPDialogAction(label: "Criar e trocar", variant: .primary) { create() }]) {
                TextField("feat/my-change", text: $newName)
                    .textFieldStyle(.mpMono)
                    .onSubmit { create(); mpDismissOverlay() }
            }
        }
    }

    private func entries() -> [MPMenuEntry] {
        var entries: [MPMenuEntry] = [.header("Trocar para")]
        entries += local.prefix(20).map { name in
            .item(name, checked: name == branch, disabled: name == branch) { switchTo(name) }
        }
        if !remote.isEmpty {
            entries += [.divider, .header("Remotas")]
            entries += remote.prefix(15).map { name in .item(name) { switchTo(name) } }
        }
        entries += [.divider,
                    .item("Nova branch…", icon: "plus") { newName = ""; creating = true },
                    .item("Buscar branches do remoto", icon: "arrow.down.circle") { Task { await repo.fetch(); await load() } }]
        return entries
    }

    private func load() async {
        let result = await repo.branches()
        local = result.local
        remote = result.remote
    }

    private func switchTo(_ name: String) {
        Task {
            if !(await repo.switchBranch(name)) { blocked = name }
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        guard !name.isEmpty else { return }
        creating = false
        Task { await repo.createBranch(name) }
    }
}

struct TerminalPane: View {
    @ObservedObject var group: TerminalGroup
    let project: Project
    @EnvironmentObject private var store: ProjectStore
    @State private var editingCommands = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(group.tabs) { tab in
                    let selected = group.selectedId == tab.id
                    let status = group.status[tab.id] ?? .idle
                    HStack(spacing: 6) {
                        MPStatusDot(status: Self.dot(status), showsLabel: false)
                        Text(tab.title).lineLimit(1).font(.system(size: 12, weight: selected ? .semibold : .regular))
                        ForEach(status.ports.prefix(2), id: \.self) { port in
                            Button(":\(String(port))") { Self.openInBrowser(port) }
                                .buttonStyle(.plain)
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.sheen)
                                .help("Abrir http://localhost:\(String(port)) no navegador")
                        }
                        if status.isCrashed {
                            Text("caiu").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.danger)
                        }
                        Button {
                            group.close(tab)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textFaint)
                        }
                        .buttonStyle(.plain)
                        .help("Fechar terminal")
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(selected ? AnyShapeStyle(Theme.plumageRaised) : AnyShapeStyle(Color.clear), in: Capsule())
                    .overlay(Capsule().strokeBorder(selected ? AnyShapeStyle(Theme.quill) : AnyShapeStyle(Color.clear)))
                    .contentShape(Capsule())
                    .onTapGesture { group.selectedId = tab.id }
                    .mpContextMenu { tabMenu(tab, status: status) }
                    .help(Self.describe(status, isCommand: tab.command != nil))
                }
                MPIconButton(icon: "plus", label: "Novo terminal") { group.open() }
                Spacer()
                ForEach(currentProject.commands) { command in
                    Button {
                        group.open(title: command.name, command: command.command, autoRestart: command.autoRestart)
                    } label: {
                        Label(command.name, systemImage: "play.fill")
                    }
                    .buttonStyle(.mp(.secondary, size: .sm))
                    .help(command.command)
                }
                MPIconButton(icon: "slider.horizontal.3", label: "Editar comandos salvos") { editingCommands = true }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.plumage)
            Rectangle().fill(Theme.quill).frame(height: 1)

            if let tab = group.selected {
                if case .crashed(let date) = group.status[tab.id] ?? .idle {
                    crashBanner(tab, at: date)
                }
                TerminalHost(tab: tab).id(tab.id)
            } else {
                MPEmptyState(title: "Nenhum terminal aberto",
                             message: "Abra um terminal ou rode um dos comandos salvos do projeto: servidor, testes, migrations.") {
                    MPEmptyIcon(systemName: "terminal")
                }
                .overlay(alignment: .bottom) {
                    Button("Abrir terminal") { group.open() }.buttonStyle(.mp(.primary)).padding(.bottom, 120)
                }
            }
        }
        .mpSheet(isPresented: $editingCommands) {
            CommandsEditor(project: currentProject) { updated in
                store.update(updated)
            }
        }
    }

    private var currentProject: Project {
        store.workspace(id: project.id) ?? project
    }

    private func crashBanner(_ tab: TerminalTab, at date: Date) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
            Text("\(tab.title) caiu às \(date.formatted(date: .omitted, time: .shortened)). O erro está no terminal abaixo.")
                .font(.system(size: 12))
            Spacer()
            if tab.command != nil {
                Toggle("Reiniciar sozinho se cair", isOn: Binding(get: { tab.autoRestart }, set: { setAutoRestart(tab, $0) }))
                    .toggleStyle(.mpCheckbox)
                    .font(.system(size: 12))
                Button("Reiniciar") { group.restart(tab) }.buttonStyle(.mp(.primary, size: .sm))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.danger.opacity(0.12))
    }

    private func tabMenu(_ tab: TerminalTab, status: ServerStatus) -> [MPMenuEntry] {
        var entries: [MPMenuEntry] = []
        if tab.command != nil {
            entries.append(.item("Reiniciar", icon: "arrow.clockwise") { group.restart(tab) })
            entries.append(.item("Reiniciar sozinho se cair", checked: tab.autoRestart) { setAutoRestart(tab, !tab.autoRestart) })
        }
        for port in status.ports {
            entries.append(.item("Abrir localhost:\(String(port))", icon: "safari") { Self.openInBrowser(port) })
            entries.append(.item("Copiar http://localhost:\(String(port))", icon: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("http://localhost:\(String(port))", forType: .string)
            })
        }
        if !entries.isEmpty { entries.append(.divider) }
        entries.append(.item("Fechar terminal", icon: "xmark", danger: true) { group.close(tab) })
        return entries
    }

    /// Vale para esta aba e fica salvo no comando (as próximas abas dele já nascem assim).
    private func setAutoRestart(_ tab: TerminalTab, _ enabled: Bool) {
        tab.autoRestart = enabled
        group.objectWillChange.send()
        var updated = currentProject
        if let index = updated.commands.firstIndex(where: { $0.command == tab.command }) {
            updated.commands[index].autoRestart = enabled
            store.update(updated)
        }
    }

    private static func dot(_ status: ServerStatus) -> MPStatusDot.Status {
        switch status {
        case .idle, .stopped: .idle
        case .starting: .working
        case .up: .ok
        case .crashed: .error
        }
    }

    private static func describe(_ status: ServerStatus, isCommand: Bool) -> String {
        switch status {
        case .idle: "Terminal livre"
        case .starting: isCommand ? "Subindo…" : "Rodando um comando"
        case .up(let ports): "No ar em " + ports.map { "localhost:\(String($0))" }.joined(separator: ", ")
        case .stopped: "Parado"
        case .crashed(let date): "Caiu às \(date.formatted(date: .omitted, time: .shortened))"
        }
    }

    static func openInBrowser(_ port: Int) {
        if let url = URL(string: "http://localhost:\(String(port))") { NSWorkspace.shared.open(url) }
    }
}

private struct CommandsEditor: View {
    @State var project: Project
    let onSave: (Project) -> Void

    var body: some View {
        MPDialogCard(title: "Comandos de \(project.name)",
                     message: "Viram botões na aba Terminal. Cada um abre um terminal novo rodando o comando.",
                     width: 600,
                     actions: [MPDialogAction(label: "Cancelar"), MPDialogAction(label: "Salvar", variant: .primary) { onSave(project) }]) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($project.commands) { $command in
                            HStack(spacing: 8) {
                                TextField("Nome", text: $command.name).frame(width: 120)
                                TextField("Comando", text: $command.command).textFieldStyle(.mpMono)
                                Toggle("Reinicia se cair", isOn: $command.autoRestart)
                                    .toggleStyle(.mpCheckbox)
                                    .font(.system(size: 11))
                                    .fixedSize()
                                    .help("Se o servidor cair sozinho, roda de novo (até 3 vezes em 2 minutos)")
                                MPIconButton(icon: "minus.circle", label: "Remover comando") {
                                    project.commands.removeAll { $0.id == command.id }
                                }
                            }
                        }
                    }
                }
                .frame(height: 200)
                HStack(spacing: 8) {
                    Button("Adicionar") { project.commands.append(SavedCommand(name: "novo", command: "")) }
                        .buttonStyle(.mp(.ghost, size: .sm))
                    Button("Detectar do package.json") {
                        let detected = ProjectStore.detectCommands(project.path)
                        let existing = Set(project.commands.map(\.command))
                        project.commands += detected.filter { !existing.contains($0.command) }
                    }
                    .buttonStyle(.mp(.ghost, size: .sm))
                }
            }
        }
    }
}

/// Agentes da conversa atual do projeto (ou de outra conversa escolhida).
private struct ProjectAgentsPane: View {
    @ObservedObject var chat: ChatSession
    let project: Project
    @Binding var focusToolUse: String?
    @EnvironmentObject private var usage: UsageIndex
    @State private var otherSession: SessionSummary?
    @State private var sessions: [SessionSummary] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                MPSectionLabel("Conversa")
                MPSelect(icon: "bubble.left.and.bubble.right", title: currentTitle,
                         options: [.init(value: nil, label: chat.sessionId == nil ? "Atual (nenhuma ainda)" : "Atual do chat")]
                            + sessions.map { .init(value: $0, label: String($0.displayTitle.prefix(60)), detail: Format.relative($0.lastActivity)) },
                         selection: $otherSession)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.plumage)
            Rectangle().fill(Theme.quill).frame(height: 1)
            AgentsBrowser(transcript: transcript, focusToolUse: $focusToolUse)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            let path = project.path
            usage.read({ $0.sessions(inProject: path, limit: 40) }) { sessions = $0 }
        }
    }

    private var currentTitle: String {
        otherSession.map { String($0.displayTitle.prefix(48)) } ?? (chat.sessionId == nil ? "Atual (nenhuma ainda)" : "Atual do chat")
    }

    private var transcript: String? {
        if let otherSession { return otherSession.transcript }
        return chat.sessionId.map { AgentScanner.transcriptPath(sessionId: $0, cwd: project.claudeDirectory) }
    }
}
