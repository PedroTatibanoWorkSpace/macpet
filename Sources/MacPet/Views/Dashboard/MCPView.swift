import SwiftUI

/// Um servidor MCP como o `claude mcp list` mostra, com o status do teste de conexão.
struct MCPEntry: Identifiable, Hashable {
    enum Status { case connected, failed, needsAuth, pending, unknown }

    let name: String
    let target: String
    let status: Status
    let statusText: String

    var id: String { name }
    /// Conectores do claude.ai e servidores de plugins não são configurados por aqui.
    var managedElsewhere: Bool { name.hasPrefix("claude.ai ") || name.hasPrefix("plugin:") }
    var origin: String {
        if name.hasPrefix("claude.ai ") { return "conector do claude.ai" }
        if name.hasPrefix("plugin:") { return "plugin \(name.split(separator: ":").dropFirst().first ?? "")" }
        return "configurado por você"
    }
}

enum MCPCommands {
    private static var claude: String? { ClaudeCLI.executable }

    /// `claude mcp list` testa a conexão de cada servidor (alguns segundos).
    static func list(in directory: String) async -> (entries: [MCPEntry], error: String?) {
        guard let claude else { return ([], "Não encontrei o comando claude.") }
        let result = await Shell.run(claude, ["mcp", "list"], in: directory)
        let entries = result.stdout.split(separator: "\n").compactMap { parse(String($0)) }
        return (entries, result.ok ? nil : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// "nome: alvo - ✔ Connected". O nome pode ter ":" (plugin:x:y), mas sem espaço depois.
    static func parse(_ line: String) -> MCPEntry? {
        guard let colon = line.range(of: ": "), let dash = line.range(of: " - ", options: .backwards),
              colon.upperBound <= dash.lowerBound else { return nil }
        let name = String(line[..<colon.lowerBound])
        let target = String(line[colon.upperBound..<dash.lowerBound])
        let statusText = String(line[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
        let lower = statusText.lowercased()
        let status: MCPEntry.Status = lower.contains("connected") ? .connected
            : lower.contains("auth") ? .needsAuth
            : lower.contains("pending") ? .pending
            : lower.contains("fail") || statusText.contains("✗") ? .failed : .unknown
        return MCPEntry(name: name, target: target, status: status, statusText: statusText)
    }

    static func details(_ name: String, in directory: String) async -> String {
        guard let claude else { return "" }
        let result = await Shell.run(claude, ["mcp", "get", name], in: directory)
        return (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove do escopo onde o servidor está (lido do `claude mcp get`).
    static func remove(_ name: String, in directory: String) async -> String? {
        guard let claude else { return "Não encontrei o comando claude." }
        let info = await details(name, in: directory)
        let scope = info.contains("User config") ? "user" : info.contains("Project config") ? "project" : "local"
        let result = await Shell.run(claude, ["mcp", "remove", name, "-s", scope], in: directory)
        return result.ok ? nil : (result.stderr.isEmpty ? result.stdout : result.stderr)
    }

    static func add(name: String, transport: String, target: String, pairs: [String], scope: String, in directory: String) async -> String? {
        guard let claude else { return "Não encontrei o comando claude." }
        var args = ["mcp", "add", "-s", scope]
        if transport == "stdio" {
            args += pairs.flatMap { ["-e", $0] } + [name, "--"] + target.split(separator: " ").map(String.init)
        } else {
            args += ["--transport", transport] + pairs.flatMap { ["--header", $0] } + [name, target]
        }
        let result = await Shell.run(claude, args, in: directory)
        return result.ok ? nil : (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MCPView: View {
    @EnvironmentObject private var store: ProjectStore
    /// Pasta de onde a lista é vista: a home (servidores seus) ou um projeto (inclui os dele).
    @State private var directory = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var entries: [MCPEntry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var selection: MCPEntry.ID?
    @State private var details = ""
    @State private var adding = false
    @State private var confirmingRemoval = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    MPSectionLabel("Ver como em")
                    MPSelect(icon: "folder", title: directoryTitle,
                             options: [.init(value: FileManager.default.homeDirectoryForCurrentUser.path, label: "Todas as pastas (seus)")]
                                + store.projects.map { .init(value: $0.path, label: "Projeto \($0.name)") },
                             selection: $directory)
                    Spacer()
                }
                .padding(10)
                MPDivider()
                MPList {
                    ForEach(groups, id: \.title) { group in
                        MPListSection(group.title)
                        ForEach(group.entries) { entry in
                            MPListRow(title: entry.name.replacingOccurrences(of: "claude.ai ", with: ""), subtitle: entry.target,
                                      selected: selection == entry.id) {
                                StatusDot(status: entry.status)
                            }
                            .onTapGesture { selection = entry.id }
                        }
                    }
                }
                .overlay {
                    if loading && entries.isEmpty { ProgressView { Text("Testando a conexão de cada servidor…") } }
                }
            }
            .background(Theme.plumage)
            .frame(minWidth: 250, idealWidth: 300, maxWidth: 420)

            Group {
                if let entry = entries.first(where: { $0.id == selection }) {
                    detail(entry)
                } else {
                    MPEmptyState(title: "Servidores MCP",
                                 message: error ?? "Ferramentas externas que o Claude pode usar: Notion, ClickUp, bancos, APIs. Selecione um para ver os detalhes.") {
                        MPEmptyIcon(systemName: "point.3.connected.trianglepath.dotted")
                    }
                }
            }
            .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.ink)
        }
        .navigationTitle("MCPs")
        .toolbar {
            HStack(spacing: 6) {
                MPIconButton(icon: "arrow.clockwise", label: "Testar de novo", glass: true) { Task { await load() } }
                    .disabled(loading)
                Button { adding = true } label: { Label("Adicionar servidor", systemImage: "plus") }
                    .buttonStyle(.mp(.primary, size: .sm))
            }
        }
        .mpSheet(isPresented: $adding) {
            AddMCPSheet(projects: store.projects) { Task { await load() } }
        }
        .task(id: directory) { await load() }
        .onChange(of: selection) { _, name in
            details = ""
            guard let name else { return }
            let directory = directory
            Task { details = await MCPCommands.details(name, in: directory) }
        }
    }

    private var directoryTitle: String {
        store.projects.first { $0.path == directory }.map { "Projeto \($0.name)" } ?? "Todas as pastas (seus)"
    }

    private var groups: [(title: String, entries: [MCPEntry])] {
        let mine = entries.filter { !$0.managedElsewhere }
        let plugins = entries.filter { $0.name.hasPrefix("plugin:") }
        let connectors = entries.filter { $0.name.hasPrefix("claude.ai ") }
        return [("Configurados por você", mine), ("De plugins", plugins), ("Conectores do claude.ai", connectors)]
            .filter { !$0.1.isEmpty }
    }

    private func detail(_ entry: MCPEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(entry.name).font(Theme.display(24))
                HStack(spacing: 8) {
                    StatusDot(status: entry.status)
                    Text(entry.statusText)
                    Text("·").foregroundStyle(Theme.textFaint)
                    Text(entry.origin).foregroundStyle(Theme.textMuted)
                }
                .font(.callout)
                Text(entry.target).font(Theme.mono(11.5)).textSelection(.enabled).foregroundStyle(Theme.textMuted)
                    .lineLimit(6)
                if !details.isEmpty {
                    Text(details).font(Theme.mono(11.5)).textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.plumage, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if entry.managedElsewhere {
                    Text(entry.name.hasPrefix("claude.ai ")
                         ? "Conector da sua conta do claude.ai: liga, desliga e autoriza em claude.ai › Configurações › Conectores."
                         : "Vem de um plugin: liga e desliga junto com o plugin (aba Configuração).")
                        .font(.callout).foregroundStyle(Theme.textMuted)
                } else {
                    Button("Remover servidor…") { confirmingRemoval = true }
                        .buttonStyle(.mp(.danger))
                        .mpDialog(isPresented: $confirmingRemoval, title: "Remover \(entry.name)?",
                                  message: "O Claude deixa de ter as ferramentas dele nas próximas conversas.", actions: [
                                    MPDialogAction(label: "Cancelar"),
                                    MPDialogAction(label: "Remover", variant: .danger) {
                                        let directory = directory
                                        Task {
                                            error = await MCPCommands.remove(entry.name, in: directory)
                                            selection = nil
                                            await load()
                                        }
                                    },
                                  ])
                }
                if entry.status == .connected, entry.name.hasPrefix("claude.ai ") == false {
                    Text("Dica: no Sonnet, cada servidor ligado entra inteiro no contexto de todas as mensagens. Nas tarefas paralelas os MCPs vêm desligados por isso.")
                        .font(.caption).foregroundStyle(Theme.textFaint)
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
    }

    private func load() async {
        loading = true
        let result = await MCPCommands.list(in: directory)
        entries = result.entries
        error = result.error
        loading = false
    }
}

private struct StatusDot: View {
    let status: MCPEntry.Status

    var body: some View {
        Circle()
            .fill(status == .connected ? AnyShapeStyle(Theme.success) : status == .failed ? AnyShapeStyle(Theme.danger) : status == .unknown ? AnyShapeStyle(Theme.textFaint) : AnyShapeStyle(Theme.ember))
            .frame(width: 8, height: 8)
    }
}

private struct MCPRow: View {
    let entry: MCPEntry

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: entry.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name.replacingOccurrences(of: "claude.ai ", with: "")).lineLimit(1)
                Text(entry.target).font(Theme.mono(10)).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AddMCPSheet: View {
    let projects: [Project]
    let added: () -> Void
    @State private var name = ""
    @State private var transport = "http"
    @State private var target = ""
    @State private var pairs = ""
    @State private var scope = "user"
    @State private var project: String = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Adicionar servidor MCP").font(Theme.display(20))
            TextField("nome (ex.: sentry)", text: $name).textFieldStyle(.mpMono)
            MPTabs(items: [.init(value: "http", label: "URL (HTTP)"), .init(value: "sse", label: "URL (SSE)"),
                           .init(value: "stdio", label: "Comando local")], selection: $transport)
                .fixedSize()
            TextField(transport == "stdio" ? "npx -y @modelcontextprotocol/server-postgres postgres://…" : "https://mcp.exemplo.com/mcp",
                      text: $target)
                .textFieldStyle(.mpMono)
            VStack(alignment: .leading, spacing: 4) {
                Text(transport == "stdio" ? "Variáveis de ambiente (uma por linha, CHAVE=valor)" : "Cabeçalhos (um por linha, Nome: valor)")
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.textMuted)
                MPTextArea(text: $pairs, mono: true, height: 70)
            }
            HStack(spacing: 8) {
                MPSectionLabel("Disponível em")
                MPSelect(icon: "person.2", title: scopeLabel, options: [
                    .init(value: "user", label: "Todas as pastas (só você)"),
                    .init(value: "local", label: "Um projeto, só você"),
                    .init(value: "project", label: "Um projeto, para o time", detail: "Fica no .mcp.json do repositório"),
                ], selection: $scope)
                if scope != "user" {
                    MPSelect(icon: "folder", title: projects.first { $0.path == project }?.name ?? "Projeto",
                             options: projects.map { .init(value: $0.path, label: $0.name) }, selection: $project)
                }
                Spacer()
            }
            if let error { Text(error).font(.callout).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancelar") { mpDismissOverlay() }.keyboardShortcut(.cancelAction)
                Button("Adicionar", action: save)
                    .buttonStyle(.mp(.primary))
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty || target.trimmingCharacters(in: .whitespaces).isEmpty
                              || (scope != "user" && project.isEmpty))
            }
        }
        .mpDialogSurface(width: 560)
        .onAppear { project = projects.first?.path ?? "" }
    }

    private var scopeLabel: String {
        switch scope {
        case "local": "Um projeto, só você"
        case "project": "Um projeto, para o time"
        default: "Todas as pastas (só você)"
        }
    }

    private func save() {
        saving = true
        error = nil
        let directory = scope == "user" ? FileManager.default.homeDirectoryForCurrentUser.path : project
        let lines = pairs.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Task {
            error = await MCPCommands.add(name: name.trimmingCharacters(in: .whitespaces), transport: transport,
                                          target: target.trimmingCharacters(in: .whitespaces), pairs: lines,
                                          scope: scope, in: directory)
            saving = false
            if error == nil {
                added()
                mpDismissOverlay()
            }
        }
    }
}
