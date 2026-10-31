import AppKit
import SwiftUI

enum AgentSelection: Hashable {
    case workflow(String)
    case agent(String)
}

/// Agentes e workflows disparados por uma sessão do Claude Code, atualizados ao vivo.
struct AgentsBrowser: View {
    /// Transcript da sessão principal.
    let transcript: String?
    /// Chamada (tool_use) que deve ficar selecionada ao abrir, vinda de um card do chat.
    @Binding var focusToolUse: String?

    @State private var tree = AgentTree()
    @State private var loaded = false
    @State private var selection: AgentSelection?
    @State private var expanded: Set<String> = []

    var body: some View {
        Group {
            if transcript == nil {
                MPEmptyState(title: "Nenhuma conversa ainda", message: "Converse com o Claude neste projeto: os agentes que ele disparar aparecem aqui.") {
                    MPEmptyIcon(systemName: "person.2")
                }
            } else if loaded && tree.isEmpty {
                MPEmptyState(title: "Nenhum agente nesta conversa", message: "Quando o Claude usar subagentes ou workflows, eles aparecem aqui com cada passo.") {
                    MPEmptyIcon(systemName: "person.2")
                }
            } else {
                HSplitView {
                    list.frame(minWidth: 260, idealWidth: 340, maxWidth: 460)
                    detail.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .overlay {
            if !loaded && transcript != nil { ProgressView { Text("Lendo agentes…") } }
        }
        .task(id: transcript) {
            loaded = false
            tree = AgentTree()
            guard let transcript else { return }
            // Atualiza a cada 4s enquanto a aba está aberta (agentes rodando mudam de estado).
            while !Task.isCancelled {
                let path = transcript
                let fresh = await Task.detached(priority: .utility) { AgentScanner.scan(transcript: path) }.value
                if fresh != tree { tree = fresh }
                loaded = true
                applyFocus()
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .onChange(of: focusToolUse) { _, _ in applyFocus() }
    }

    private func applyFocus() {
        guard let id = focusToolUse else { return }
        if let agent = tree.agent(forToolUse: id) {
            selection = .agent(agent.id)
            focusToolUse = nil
        } else if let workflow = tree.workflow(forToolUse: id) {
            selection = .workflow(workflow.id)
            expanded.insert(workflow.id)
            focusToolUse = nil
        }
    }

    // MARK: Lista

    private var list: some View {
        MPList {
            if !tree.workflows.isEmpty {
                MPListSection("Workflows (\(tree.workflows.count))")
                ForEach(tree.workflows) { workflow in
                    selectable(.workflow(workflow.id)) {
                        WorkflowRow(workflow: workflow, expanded: expanded.contains(workflow.id)) {
                            if expanded.contains(workflow.id) { expanded.remove(workflow.id) } else { expanded.insert(workflow.id) }
                        }
                    }
                    if expanded.contains(workflow.id) {
                        ForEach(workflow.agents) { agent in
                            selectable(.agent(agent.id)) { AgentRow(agent: agent).padding(.leading, 18) }
                        }
                    }
                }
            }
            if !tree.subagents.isEmpty {
                MPListSection("Subagentes (\(tree.subagents.count))")
                ForEach(tree.subagents) { agent in
                    selectable(.agent(agent.id)) { AgentRow(agent: agent) }
                }
            }
        }
    }

    /// Linha clicável com o destaque de seleção do design system.
    private func selectable<Row: View>(_ value: AgentSelection, @ViewBuilder row: () -> Row) -> some View {
        row()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selection == value ? AnyShapeStyle(Theme.sheenSoft) : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { selection = value }
    }

    // MARK: Detalhe

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .workflow(let id):
            if let workflow = tree.workflows.first(where: { $0.id == id }) {
                WorkflowDetail(workflow: workflow) { agent in
                    expanded.insert(workflow.id)
                    selection = .agent(agent.id)
                }
            }
        case .agent(let id):
            if let agent = allAgents.first(where: { $0.id == id }) {
                AgentDetail(agent: agent).id(agent.id)
            }
        case nil:
            MPEmptyState(title: "Selecione um agente ou workflow",
                         message: "\(tree.workflows.count) workflows e \(tree.subagents.count) subagentes nesta conversa.") {
                MPEmptyIcon(systemName: "person.2.circle")
            }
        }
    }

    private var allAgents: [AgentRun] {
        tree.subagents + tree.workflows.flatMap(\.agents)
    }
}

private struct StatusIcon: View {
    let running: Bool
    var done = true

    var body: some View {
        if running {
            MPStatusDot(status: .working, showsLabel: false).frame(width: 14)
        } else {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? AnyShapeStyle(Theme.success) : AnyShapeStyle(Theme.textMuted))
                .frame(width: 14)
        }
    }
}

private struct WorkflowRow: View {
    let workflow: WorkflowRun
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: toggle) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption).frame(width: 12)
            }
            .buttonStyle(.plain)
            StatusIcon(running: workflow.isRunning, done: workflow.completed >= workflow.launched)
            VStack(alignment: .leading, spacing: 2) {
                Text(workflow.name).fontWeight(.medium).lineLimit(1)
                Text("\(workflow.completed)/\(workflow.launched) agentes · \(workflow.lastActivity.map(Format.relative) ?? "")")
                    .font(.caption).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AgentRow: View {
    let agent: AgentRun

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusIcon(running: agent.isRunning)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.title).lineLimit(2)
                HStack(spacing: 4) {
                    Text(agent.type == "workflow-subagent" ? "workflow" : agent.type)
                    if let duration = agent.duration { Text("· \(AgentFormat.duration(duration))") }
                    if let last = agent.lastActivity { Text("· \(Format.relative(last))") }
                }
                .font(.caption).foregroundStyle(Theme.textMuted)
                if agent.isRunning, let action = agent.lastAction {
                    Text(action).font(.caption).foregroundStyle(Theme.ember).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

enum AgentFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60) min" }
        return "\(total / 3600)h\(String(format: "%02d", (total % 3600) / 60))"
    }
}

private struct WorkflowDetail: View {
    let workflow: WorkflowRun
    let open: (AgentRun) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workflow.name).font(.title2.weight(.semibold))
                    Text("\(workflow.completed) de \(workflow.launched) agentes concluídos"
                         + (workflow.started.map { " · começou \(Format.relative($0))" } ?? ""))
                        .foregroundStyle(Theme.textMuted)
                }
                if let summary = workflow.summary {
                    Text(summary).lineSpacing(3).textSelection(.enabled)
                }
                ForEach(workflow.agents) { agent in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            StatusIcon(running: agent.isRunning, done: agent.result != nil)
                            Text(agent.title).fontWeight(.semibold).lineLimit(2)
                            Spacer()
                            Button("Abrir") { open(agent) }
                        }
                        if let result = agent.result {
                            Text(String(result.prefix(600)) + (result.count > 600 ? "…" : ""))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(8)
                                .textSelection(.enabled)
                        } else if let action = agent.lastAction {
                            Text(action).font(.caption).foregroundStyle(Theme.textMuted).lineLimit(2)
                        }
                    }
                    .card()
                }
            }
            .padding(20)
        }
    }
}

struct AgentDetail: View {
    let agent: AgentRun
    @State private var items: [ChatItem] = []
    @State private var loading = true
    @State private var showPrompt = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        StatusIcon(running: agent.isRunning)
                        Text(agent.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    }
                    HStack(spacing: 8) {
                        Text(agent.type)
                        if let started = agent.started { Text("· começou \(started.formatted(date: .abbreviated, time: .shortened))") }
                        if let duration = agent.duration { Text("· \(AgentFormat.duration(duration))") }
                        Text("· \(items.filter { if case .tool = $0.kind { return true } else { return false } }.count) ações")
                    }
                    .font(.caption).foregroundStyle(Theme.textMuted)
                    HStack {
                        Button(showPrompt ? "Esconder pedido" : "Ver o pedido que ele recebeu") { showPrompt.toggle() }
                        Button("Mostrar transcript") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: agent.transcript)])
                        }
                    }
                    .controlSize(.small)
                }

                if showPrompt {
                    MarkdownText(text: agent.prompt).padding(12)
                        .background(Theme.plumage, in: RoundedRectangle(cornerRadius: 8))
                }

                if let result = agent.result {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Resultado entregue", systemImage: "checkmark.seal").font(.headline)
                        if result.hasPrefix("{") || result.hasPrefix("[") {
                            CodeBox(text: result, maxLines: 80)
                        } else {
                            MarkdownText(text: result)
                        }
                    }
                    .card()
                }

                Text("Execução").font(.headline).padding(.top, 4)
                if loading && items.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(items) { item in
                    ChatItemView(item: item, chat: nil)
                }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .task(id: agent.id) {
            // Agente rodando: recarrega a execução a cada 4s.
            repeat {
                let path = agent.transcript
                let fresh = await Task.detached(priority: .utility) { ChatSession.loadHistory(path, includeSidechain: true) }.value
                if fresh.count != items.count { items = fresh }
                loading = false
                if !agent.isRunning { break }
                try? await Task.sleep(for: .seconds(4))
            } while !Task.isCancelled
        }
    }
}
