import SwiftUI

/// O plano de tarefas que o Claude escreveu na conversa: você escolhe quais lançar.
/// Cada uma vira uma worktree com um agente novo que recebe só o briefing.
struct TaskPlanCard: View {
    let plan: TaskPlan
    let chat: ChatSession
    @EnvironmentObject private var store: ProjectStore
    @State private var selected: Set<String>
    @State private var expanded: Set<String> = []
    @State private var launching: String?
    @State private var errors: [String] = []

    init(plan: TaskPlan, chat: ChatSession) {
        self.plan = plan
        self.chat = chat
        _selected = State(initialValue: Set(plan.items.map(\.branch)))
    }

    /// Projeto que recebe as tarefas: o dono, se esta conversa já for uma tarefa ou conversa fixada.
    private var owner: Project? { store.workspace(id: chat.project.parentId ?? chat.project.id) }
    private var launched: [String: UUID] {
        Dictionary((owner?.tasks ?? []).map { ($0.branch, $0.id) }, uniquingKeysWith: { first, _ in first })
    }
    private var toLaunch: [TaskPlan.Item] {
        plan.items.filter { selected.contains($0.branch) && launched[branchName($0)] == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "square.split.2x2").foregroundStyle(Theme.sheen)
                Text("Plano: \(plan.items.count) tarefa\(plan.items.count == 1 ? "" : "s") em paralelo").font(Theme.display(15))
                Spacer()
                Text("briefings ≈ \(Format.tokens(plan.briefTokens)) tokens")
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.textMuted)
                    .help("Cada agente novo começa só com o briefing dele, não com esta conversa.")
            }

            ForEach(plan.items) { item in
                row(item)
                if item.id != plan.items.last?.id { MPDivider() }
            }

            ForEach(errors, id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Theme.danger)
            }

            HStack {
                Text("Cada tarefa ganha branch, worktree e conversa próprias; o agente começa só com o briefing.")
                    .font(.caption).foregroundStyle(Theme.textMuted)
                Spacer()
                if let launching {
                    ProgressView().controlSize(.small)
                    Text(launching).font(.caption).foregroundStyle(Theme.textMuted)
                }
                Button(toLaunch.isEmpty ? "Lançadas" : "Lançar \(toLaunch.count) tarefa\(toLaunch.count == 1 ? "" : "s")", action: launch)
                    .buttonStyle(.mp(.primary))
                    .disabled(toLaunch.isEmpty || launching != nil || owner == nil)
            }
        }
        .padding(16)
        .background(Theme.plumage, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.sheen.opacity(0.35)))
    }

    private func row(_ item: TaskPlan.Item) -> some View {
        let taskId = launched[branchName(item)]
        return HStack(alignment: .top, spacing: 10) {
            if taskId != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success).frame(width: 18)
            } else {
                Toggle("", isOn: Binding(get: { selected.contains(item.branch) }, set: { on in
                    if on { selected.insert(item.branch) } else { selected.remove(item.branch) }
                }))
                .toggleStyle(.mpCheckbox)
                .labelsHidden()
                .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.title).fontWeight(.semibold)
                    Spacer()
                    if let model = item.model { tag(model) }
                    if let effort = item.effort { tag(effort) }
                }
                Text(branchName(item) + (item.base.map { " ← \($0)" } ?? ""))
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.textMuted)
                Text(item.brief)
                    .font(.callout).foregroundStyle(Theme.textMuted)
                    .lineLimit(expanded.contains(item.id) ? nil : 3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button(expanded.contains(item.id) ? "Ver menos" : "Ver briefing completo") {
                        if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
                    }
                    if let taskId {
                        Button("Abrir tarefa") { store.hubSelection = .project(taskId) }
                    }
                }
                .buttonStyle(.mp(.ghost, size: .sm))
                .font(.caption)
            }
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(Theme.mono(10)).foregroundStyle(Theme.textMuted)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.plumageRaised, in: Capsule())
    }

    private func branchName(_ item: TaskPlan.Item) -> String {
        CommitAssistant.sanitizeBranch(item.branch)
    }

    /// Cria as worktrees uma por vez (o git trava o repositório a cada `worktree add`) e já manda o briefing.
    private func launch() {
        guard let ownerId = owner?.id else { return }
        let items = toLaunch
        let origin = chat.project.name
        errors = []
        Task {
            let base = store.repo(for: chat.project).branch ?? "main"
            for item in items {
                guard let current = store.workspace(id: ownerId) else { break }
                launching = "Criando \(item.title)…"
                do {
                    let (workspace, _) = try await store.createTask(in: current, name: item.title,
                                                                    branch: branchName(item), base: item.base ?? base)
                    let taskChat = store.chat(for: workspace)
                    if let model = item.model { taskChat.setModel(model) }
                    if let effort = item.effort, ModelCatalog.effortLevels.contains(effort) { taskChat.setEffort(effort) }
                    taskChat.notice("Lançada a partir da conversa em \(origin).")
                    let footer = store.task(id: workspace.id).map { TaskPlan.footer(task: $0.task, origin: origin, project: current.name) } ?? ""
                    taskChat.send(item.brief + footer)
                } catch {
                    errors.append("\(item.title): \(error.localizedDescription)")
                }
            }
            launching = nil
        }
    }
}
