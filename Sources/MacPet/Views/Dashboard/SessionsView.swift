import AppKit
import SwiftUI

struct SessionsView: View {
    @EnvironmentObject private var usage: UsageIndex
    @State private var search = ""
    @State private var sessions: [SessionSummary] = []
    @State private var selection: SessionSummary.ID?
    @State private var recentProjects: [String] = []

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("Buscar em títulos, prompts e pastas", text: $search)
                    .padding(10)
                MPList {
                    ForEach(sessions) { session in
                        SessionListRow(session: session, selected: selection == session.id)
                            .onTapGesture { selection = session.id }
                    }
                }
                .overlay {
                    if sessions.isEmpty {
                        Text(usage.isIndexing ? "Indexando…" : "Nenhuma sessão encontrada")
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
            .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)

            Group {
                if let session = sessions.first(where: { $0.id == selection }) {
                    SessionDetailView(session: session)
                } else {
                    MPEmptyState(title: "Selecione uma sessão", message: "Todas as conversas com o Claude, do terminal e do MacPet.") {
                        MPEmptyIcon(systemName: "bubble.left.and.text.bubble.right")
                    }
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Sessões")
        .toolbar {
            MPMenuButton(entries: {
                [.header("Abrir o Claude Code no terminal")]
                    + recentProjects.map { project in
                        MPMenuEntry.item(URL(fileURLWithPath: project).lastPathComponent, icon: "folder") { ClaudeLauncher.newSession(in: project) }
                    }
                    + [.divider, .item("Escolher pasta…", icon: "folder.badge.plus") {
                        if let folder = FolderPicker.choose() { ClaudeLauncher.newSession(in: folder) }
                    }]
            }) {
                Label("Nova sessão", systemImage: "plus.bubble")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Theme.plumage, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.quill))
            }
            .help("Abrir o Claude Code num projeto")
        }
        .onAppear(perform: load)
        .onChange(of: search) { _, _ in load() }
        .onChange(of: usage.lastUpdated) { _, _ in load() }
    }

    private func load() {
        let query = search.trimmingCharacters(in: .whitespaces)
        usage.read({ ($0.sessions(search: query), $0.recentProjects()) }) { result in
            sessions = result.0
            recentProjects = result.1
            if selection == nil { selection = sessions.first?.id }
        }
    }
}

private struct SessionListRow: View {
    let session: SessionSummary
    let selected: Bool
    @EnvironmentObject private var claude: ClaudeSessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let live = claude.sessions[session.id] {
                    Circle().fill(live.state.color).frame(width: 7, height: 7)
                }
                Text(session.displayTitle).lineLimit(2).fontWeight(.medium)
            }
            HStack {
                Text(session.projectName)
                Text("·")
                Text(Format.relative(session.lastActivity))
                Spacer()
                if session.cost > 0 { Text(Format.usd(session.cost)).monospacedDigit() }
            }
            .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? AnyShapeStyle(Theme.sheenSoft) : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct SessionDetailView: View {
    let session: SessionSummary
    @EnvironmentObject private var usage: UsageIndex
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var claude: ClaudeSessionStore
    @State private var prompts: [(date: Date, text: String)] = []
    @State private var edits: [(path: String, count: Int)] = []
    @State private var showingAgents = false
    @State private var focusToolUse: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.displayTitle).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(session.cwd).font(.callout).foregroundStyle(Theme.textMuted).textSelection(.enabled)
                    Text("\(session.firstActivity.formatted(date: .abbreviated, time: .shortened)) → \(session.lastActivity.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(Theme.textMuted)
                }

                HStack(spacing: 8) {
                    Chip(label: "Custo", value: Format.usd(session.cost))
                    Chip(label: "Tokens", value: Format.tokens(session.tokens))
                    if session.linesAdded + session.linesRemoved > 0 {
                        Chip(label: "Linhas", value: "+\(session.linesAdded) −\(session.linesRemoved)")
                    }
                    if let live = claude.sessions[session.id] {
                        Chip(label: "Agora", value: live.state.label)
                        if let model = live.model { Chip(label: "Modelo", value: model) }
                        if let context = live.contextPercentage { Chip(label: "Contexto", value: "\(Int(context))%") }
                    }
                }

                HStack {
                    Button {
                        ClaudeLauncher.resume(session.id, in: session.cwd)
                    } label: {
                        Label("Retomar no terminal", systemImage: "play.fill")
                    }
                    .buttonStyle(.mp(.primary))
                    .disabled(!FileManager.default.fileExists(atPath: session.cwd))
                    if claude.sessions[session.id] != nil {
                        Button("Ir para a aba") { claude.open(session.id) }
                    }
                    Button("Mostrar transcript") {
                        if let transcript = session.transcript {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: transcript)])
                        }
                    }
                    Button("Agentes e workflows") { showingAgents = true }
                    if let owner = pinOwner {
                        Button("Fixar em \(owner.name)") {
                            if let pinned = projects.pin(sessionId: session.id, title: session.displayTitle, in: owner) {
                                // Se o chat do projeto estava nesta conversa, ele passa a ser só da fixada.
                                if owner.lastSessionId == session.id { projects.chat(for: owner).newConversation() }
                                projects.hubSelection = .project(pinned.id)
                            }
                        }
                        .help("A conversa ganha lugar fixo na barra lateral do projeto e sempre retoma esta sessão")
                    }
                    // Conversa de qualquer pasta num projeto: o chat retoma na pasta original (sem copiar nada).
                    MPMenuButton(entries: {
                        [.header("Fixar no projeto")] + projects.projects
                            .filter { project in !(project.pins ?? []).contains { $0.sessionId == session.id } }
                            .map { project in
                                .item(project.name, detail: project.path == session.cwd ? nil : "roda em \(session.cwd)") {
                                    pinElsewhere(in: project)
                                }
                            }
                    }) {
                        Label("Fixar no projeto…", systemImage: "pin")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(Theme.plumage, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.quill))
                    }
                    .fixedSize()
                    .help("Põe esta conversa na barra lateral de um projeto. O chat continua rodando na pasta onde ela nasceu.")
                    Button("Copiar ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(session.id, forType: .string)
                    }
                }

                if !edits.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Arquivos alterados (\(edits.count))").font(.headline)
                        ForEach(edits.prefix(40), id: \.path) { edit in
                            Button {
                                NSWorkspace.shared.open(URL(fileURLWithPath: edit.path))
                            } label: {
                                HStack {
                                    Image(systemName: "doc.text").foregroundStyle(Theme.textMuted)
                                    Text(relative(edit.path)).lineLimit(1).truncationMode(.head)
                                    Spacer()
                                    if edit.count > 1 { Text("\(edit.count)×").foregroundStyle(Theme.textMuted).monospacedDigit() }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .font(.callout)
                        }
                    }
                    .card()
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Seus prompts (\(prompts.count))").font(.headline)
                    if prompts.isEmpty {
                        Text("Nenhum prompt digitado nesta sessão.").foregroundStyle(Theme.textMuted)
                    }
                    ForEach(Array(prompts.enumerated()), id: \.offset) { _, prompt in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(prompt.date.formatted(date: .omitted, time: .shortened))
                                .font(.caption).foregroundStyle(Theme.textMuted)
                            Text(prompt.text).textSelection(.enabled)
                        }
                        MPDivider()
                    }
                }
                .card()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: load)
        .onChange(of: session.id) { _, _ in load() }
        .mpSheet(isPresented: $showingAgents) {
            VStack(spacing: 0) {
                HStack {
                    Text("Agentes · \(session.displayTitle)").font(Theme.display(17)).lineLimit(1)
                    Spacer()
                    Button("Fechar") { showingAgents = false }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(14)
                MPDivider()
                AgentsBrowser(transcript: session.transcript, focusToolUse: $focusToolUse)
            }
            .frame(width: 980, height: 620)
            .background(Theme.ink)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xl2, style: .continuous).strokeBorder(Theme.quill))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        }
    }

    /// Projeto do painel onde esta conversa aconteceu (nil se a pasta não é de nenhum projeto).
    private func pinElsewhere(in project: Project) {
        guard let pinned = projects.pin(sessionId: session.id, title: session.displayTitle, in: project, cwd: session.cwd) else { return }
        projects.hubSelection = .project(pinned.id)
        projects.tabRequest = .chat
    }

    private var pinOwner: Project? {
        guard let workspace = projects.workspace(atPath: session.cwd), !workspace.isTask else { return nil }
        let owner = workspace.parentId.flatMap(projects.workspace(id:)) ?? workspace
        return owner.pins?.contains { $0.sessionId == session.id } == true ? nil : owner
    }

    private func relative(_ path: String) -> String {
        path.hasPrefix(session.cwd + "/") ? String(path.dropFirst(session.cwd.count + 1)) : path
    }

    private func load() {
        let id = session.id
        usage.read({ ($0.prompts(session: id), $0.edits(session: id)) }) { result in
            prompts = result.0
            edits = result.1
        }
    }
}

struct Chip: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(Theme.textMuted)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.plumageRaised, in: RoundedRectangle(cornerRadius: 7))
    }
}

enum FolderPicker {
    @MainActor
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Escolher"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

extension ClaudeSessionState {
    var color: Color {
        switch self {
        case .waiting: Theme.ember
        case .working: Theme.sheen
        case .finished: Color(hex: 0x5CCF95)
        case .idle: .gray
        }
    }
}
