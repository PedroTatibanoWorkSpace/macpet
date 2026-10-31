import SwiftUI

/// O plano de tarefas que o Claude escreveu na conversa: você escolhe quais lançar.
/// Cada uma vira uma worktree com um agente novo que recebe só o briefing.
struct TaskPlanCard: View {
    let plan: TaskPlan
    let chat: ChatSession
    @EnvironmentObject private var store: ProjectStore
    @ObservedObject private var catalog = ModelCatalog.shared
    @State private var selected: Set<String>
    /// Modelo e esforço de cada tarefa (pela branch): começam com o que o Claude sugeriu e você troca antes de lançar.
    @State private var models: [String: String]
    @State private var efforts: [String: String]
    @State private var expanded: Set<String> = []
    @State private var launching: String?
    @State private var errors: [String] = []

    init(plan: TaskPlan, chat: ChatSession) {
        self.plan = plan
        self.chat = chat
        _selected = State(initialValue: Set(plan.items.map(\.branch)))
        _models = State(initialValue: Dictionary(plan.items.map { ($0.branch, $0.model ?? "default") }, uniquingKeysWith: { first, _ in first }))
        _efforts = State(initialValue: Dictionary(plan.items.compactMap { item in
            item.effort.flatMap { ModelCatalog.effortLevels.contains($0) ? (item.branch, $0) : nil }
        }, uniquingKeysWith: { first, _ in first }))
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
                if toLaunch.count > 1 {
                    MPSelect(icon: "sparkle", title: "Modelo de todas", help: "Usa o mesmo modelo em todas as tarefas que ainda não foram lançadas",
                             options: modelOptions(including: nil), selection: Binding(get: { "" }, set: { value in
                                 for item in toLaunch { setModel(value, for: item) }
                             }))
                }
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
                    if taskId == nil {
                        modelPicker(item)
                    } else {
                        tag(modelName(models[item.branch] ?? "default"))
                        if let effort = efforts[item.branch] { tag(ModelCatalog.effortLabel(effort)) }
                    }
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

    /// Modelo e esforço da tarefa, com as mesmas opções do seletor do chat.
    @ViewBuilder private func modelPicker(_ item: TaskPlan.Item) -> some View {
        let model = models[item.branch] ?? "default"
        MPSelect(icon: "sparkle", title: modelName(model), help: "Modelo do agente desta tarefa",
                 options: modelOptions(including: model),
                 selection: Binding(get: { model }, set: { setModel($0, for: item) }))
        if let levels = option(model)?.efforts, !levels.isEmpty {
            MPSelect(icon: "gauge.with.dots.needle.50percent", title: efforts[item.branch].map(ModelCatalog.effortLabel) ?? "Esforço padrão",
                     help: "Quanto o agente pensa antes de agir",
                     options: [.init(value: nil, label: "Esforço padrão")] + levels.map { .init(value: Optional($0), label: ModelCatalog.effortLabel($0)) },
                     selection: Binding(get: { efforts[item.branch] }, set: { efforts[item.branch] = $0 }))
        }
    }

    private func option(_ value: String) -> ModelOption? { catalog.models.first { $0.value == value } }
    private func modelName(_ value: String) -> String { option(value)?.name ?? value }

    /// Os apelidos do catálogo ("opus", "sonnet"…), mais o que o Claude sugeriu se não estiver nele.
    private func modelOptions(including current: String?) -> [MPSelect<String>.Option] {
        var options = catalog.models.filter { !$0.value.hasPrefix("claude-") }
            .map { MPSelect<String>.Option(value: $0.value, label: $0.name, detail: $0.detail.isEmpty ? nil : $0.detail) }
        if let current, !options.contains(where: { $0.value == current }) { options.append(.init(value: current, label: current)) }
        return options
    }

    /// Troca o modelo e descarta o esforço se o modelo novo não oferece esse nível.
    private func setModel(_ value: String, for item: TaskPlan.Item) {
        models[item.branch] = value
        if let effort = efforts[item.branch], let levels = option(value)?.efforts, !levels.contains(effort) { efforts[item.branch] = nil }
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
        let chosenModels = models, chosenEfforts = efforts
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
                    taskChat.setModel(chosenModels[item.branch] ?? "default")
                    taskChat.setEffort(chosenEfforts[item.branch])
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
