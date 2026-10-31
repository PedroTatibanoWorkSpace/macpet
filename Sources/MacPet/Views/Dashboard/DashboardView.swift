import Charts
import SwiftUI

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview = "Visão geral"
    case sessions = "Sessões"
    case prompts = "Prompts"
    case skills = "Skills"
    case mcp = "MCPs"
    case config = "Configuração"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: "chart.bar.xaxis"
        case .sessions: "bubble.left.and.text.bubble.right"
        case .prompts: "text.badge.star"
        case .skills: "wand.and.stars"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .config: "slider.horizontal.3"
        }
    }
}

enum HubSelection: Hashable {
    case project(UUID)
    case section(DashboardSection)
}

/// Janela principal: projetos (chat, alterações, terminal) e as telas do Claude Code.
struct DashboardView: View {
    @EnvironmentObject private var usage: UsageIndex
    @EnvironmentObject private var store: ProjectStore

    var body: some View {
        NavigationSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    MPListSection("Projetos")
                    ProjectsSidebarSection()
                    MPListSection("Claude Code")
                    ForEach(DashboardSection.allCases) { item in
                        MPSidebarItem(selected: store.hubSelection == .section(item)) {
                            store.hubSelection = .section(item)
                        } content: {
                            Image(systemName: item.icon).font(.system(size: 12)).foregroundStyle(Theme.textMuted).frame(width: 20)
                            Text(item.rawValue)
                        }
                    }
                }
                .padding(8)
            }
            .background(Theme.plumage)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .safeAreaInset(edge: .bottom) {
                if usage.isIndexing {
                    ProgressView(value: usage.progress) { Text("Indexando transcripts…") }
                        .padding(12)
                }
            }
            .background(shortcuts)
        } detail: {
            Group {
            switch store.hubSelection {
            case .project(let id):
                if let project = store.workspace(id: id) {
                    ProjectView(project: project)
                } else {
                    MPEmptyState(title: "Projeto removido") { MPEmptyIcon(systemName: "folder.badge.minus") }
                }
            case .section(.overview): OverviewView()
            case .section(.sessions): SessionsView()
            case .section(.prompts): PromptsView()
            case .section(.skills): SkillsView()
            case .section(.mcp): MCPView()
            case .section(.config): ConfigView()
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.ink)
        }
        .tint(Theme.sheen)
        .mpSheet(isPresented: Binding(get: { store.newTaskRequest != nil }, set: { if !$0 { store.newTaskRequest = nil } })) {
            if let project = store.newTaskRequest { NewTaskSheet(project: project) }
        }
        .frame(minWidth: 1000, minHeight: 660)
    }

    /// ⌘1…⌘9 trocam de projeto.
    private var shortcuts: some View {
        ZStack {
            ForEach(Array(store.activeProjects.prefix(9).enumerated()), id: \.element.id) { index, project in
                Button("") { store.hubSelection = .project(project.id) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
    }
}

/// O título da janela já aparece no cabeçalho de cada tela (ex.: nome do projeto em serifa).
struct HideToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

private struct ProjectSidebarRow: View {
    let project: Project
    let shortcut: Int?
    @EnvironmentObject private var store: ProjectStore

    var body: some View {
        MPSidebarItem(selected: store.hubSelection == .project(project.id)) {
            store.hubSelection = .project(project.id)
        } content: {
            ProjectMonogram(project: project, size: 20)
            Text(project.name).lineLimit(1)
            Spacer(minLength: 4)
            if let chat = store.existingChat(for: project) {
                ChatStatusDot(chat: chat)
            }
            if let shortcut {
                Text("⌘\(shortcut)").font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
            }
        }
    }
}

/// Projetos e, embaixo de cada um, as tarefas paralelas dele; os arquivados ficam recolhidos no fim.
private struct ProjectsSidebarSection: View {
    @EnvironmentObject private var store: ProjectStore
    @AppStorage("sidebar.showArchived") private var showArchived = false

    var body: some View {
        ForEach(Array(store.activeProjects.enumerated()), id: \.element.id) { index, project in
            ProjectSidebarRow(project: project, shortcut: index < 9 ? index + 1 : nil)
                .mpContextMenu {[
                    .item("Nova tarefa…", icon: "plus.square.on.square") { store.newTaskRequest = project },
                    .item("Abrir no Finder", icon: "folder") { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) },
                    .item("Arquivar", detail: "Some da barra; volta em Arquivados", icon: "archivebox") { store.setArchived(project, true) },
                    .divider,
                    .item("Remover do painel", icon: "minus.circle", danger: true) { store.remove(project) },
                ]}
            ForEach(project.pins ?? []) { pin in
                TaskSidebarRow(workspace: store.workspace(pin, in: project), branch: "Conversa fixada", icon: "pin.fill")
                    .mpContextMenu {[.item("Desafixar", icon: "pin.slash") { store.unpin(pin.id) }]}
            }
            ForEach(project.tasks ?? []) { task in
                TaskSidebarRow(workspace: store.workspace(task, in: project), branch: task.branch)
                    .mpContextMenu {[
                        .item("Abrir no Finder", icon: "folder") { NSWorkspace.shared.open(URL(fileURLWithPath: task.path)) },
                        .divider,
                        .item("Remover tarefa…", icon: "trash", danger: true) {
                            store.hubSelection = .project(task.id)
                            store.removeTaskRequest = task.id
                        },
                    ]}
            }
        }
        MPSidebarItem {
            if let folder = FolderPicker.choose() { store.add(path: folder) }
        } content: {
            Image(systemName: "plus").font(.system(size: 12)).foregroundStyle(Theme.textMuted).frame(width: 20)
            Text("Adicionar projeto").foregroundStyle(Theme.textMuted)
        }
        let archived = store.archivedProjects
        if !archived.isEmpty {
            MPSidebarItem { showArchived.toggle() } content: {
                Image(systemName: showArchived ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textFaint).frame(width: 20)
                Text("Arquivados").foregroundStyle(Theme.textMuted)
                Spacer(minLength: 4)
                Text("\(archived.count)").font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
            }
            if showArchived {
                ForEach(archived) { project in
                    ProjectSidebarRow(project: project, shortcut: nil)
                        .opacity(0.6)
                        .mpContextMenu {[
                            .item("Desarquivar", icon: "tray.and.arrow.up") { store.setArchived(project, false) },
                            .item("Abrir no Finder", icon: "folder") { NSWorkspace.shared.open(URL(fileURLWithPath: project.path)) },
                            .divider,
                            .item("Remover do painel", icon: "minus.circle", danger: true) { store.remove(project) },
                        ]}
                }
            }
        }
    }
}

/// Tarefa paralela, recuada embaixo do projeto dono.
private struct TaskSidebarRow: View {
    let workspace: Project
    let branch: String
    var icon = "arrow.triangle.branch"
    @EnvironmentObject private var store: ProjectStore

    var body: some View {
        MPSidebarItem(selected: store.hubSelection == .project(workspace.id), indent: 14) {
            store.hubSelection = .project(workspace.id)
        } content: {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ProjectColor.for(workspace).color)
                .frame(width: 16)
            Text(workspace.name).lineLimit(1).font(.system(size: 12))
            Spacer(minLength: 4)
            if let chat = store.existingChat(for: workspace) {
                ChatStatusDot(chat: chat)
            }
        }
        .help(branch)
    }
}

/// Pulsa no brilho da pena enquanto o Claude trabalha; âmbar quando espera você.
private struct ChatStatusDot: View {
    @ObservedObject var chat: ChatSession

    var body: some View {
        if chat.pendingPermissions > 0 {
            Image(systemName: "hand.raised.fill").foregroundStyle(Theme.ember).font(.caption)
                .help("Esperando sua permissão")
        } else if chat.isRunning {
            MPPulse { Circle().fill(Theme.iridescent) }
                .frame(width: 8, height: 8)
                .help("Claude trabalhando")
        }
    }
}

// MARK: - Visão geral

private struct OverviewData {
    var today = UsageTotals()
    var week = UsageTotals()
    var month = UsageTotals()
    var daily: [DayUsage] = []
    var projects: [ProjectUsage] = []
    var models: [ModelUsage] = []
}

struct OverviewView: View {
    @EnvironmentObject private var usage: UsageIndex
    @EnvironmentObject private var limits: RateLimitStore
    @EnvironmentObject private var peak: PeakMonitor
    @State private var data = OverviewData()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if usage.isIndexing && data.daily.allSatisfy({ $0.tokens == 0 }) {
                    IndexingBanner(progress: usage.progress)
                }

                SectionTitle("Limites do plano")
                PeakBanner(isPeak: peak.isPeak, boundary: peak.boundary)
                HStack(spacing: 12) {
                    LimitCard(title: "Janela de 5 horas", window: limits.fiveHour)
                    LimitCard(title: "Semana", window: limits.sevenDay)
                    if let fable = limits.fableWeek {
                        LimitCard(title: "Semana · Fable", window: fable)
                    }
                }
                HStack {
                    if let updated = limits.updatedAt {
                        Text("Atualizado \(Format.relative(updated)) pelo /usage do Claude Code")
                    } else {
                        Text("Lendo os limites do plano…")
                    }
                    Spacer()
                    Button("Atualizar") { limits.refresh() }.buttonStyle(.mp(.ghost, size: .sm))
                }
                .font(.caption).foregroundStyle(Theme.textMuted)

                if !limits.usageTips.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("O que mais pesa no seu uso · últimas 24h").font(.headline)
                        ForEach(limits.usageTips, id: \.self) { tip in
                            Text(tip).font(Theme.mono(11.5)).foregroundStyle(Theme.textMuted).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }

                SectionTitle("Uso")
                HStack(spacing: 12) {
                    StatCard(title: "Hoje", totals: data.today)
                    StatCard(title: "Últimos 7 dias", totals: data.week)
                    StatCard(title: "Últimos 30 dias", totals: data.month)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Custo por dia · 14 dias").font(.headline)
                    Chart(data.daily) { day in
                        BarMark(x: .value("Dia", day.day, unit: .day), y: .value("Custo", day.cost))
                            .foregroundStyle(Theme.iridescent)
                            .cornerRadius(3)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel { Text(value.as(Double.self).map { Format.usd($0) } ?? "") }
                        }
                    }
                    .frame(height: 180)
                }
                .card()

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Projetos · 7 dias").font(.headline)
                        if data.projects.isEmpty { Text("Sem dados ainda").foregroundStyle(Theme.textMuted) }
                        ForEach(data.projects) { project in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(project.name).fontWeight(.medium)
                                    Text("\(project.sessions) sessões · \(Format.tokens(project.tokens)) tokens")
                                        .font(.caption).foregroundStyle(Theme.textMuted)
                                }
                                Spacer()
                                Text(Format.usd(project.cost)).monospacedDigit()
                            }
                            .help(project.cwd)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Modelos · 7 dias").font(.headline)
                        if data.models.isEmpty { Text("Sem dados ainda").foregroundStyle(Theme.textMuted) }
                        ForEach(data.models) { model in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(model.model).fontWeight(.medium)
                                    Text("\(Format.tokens(model.output)) saída · \(Format.tokens(model.cacheRead)) cache")
                                        .font(.caption).foregroundStyle(Theme.textMuted)
                                }
                                Spacer()
                                Text(Format.tokens(model.total)).monospacedDigit()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }

                Text("Custo calculado pelo próprio Claude Code em preço de API. No plano por assinatura você não paga esse valor: ele mostra quanto de uso você está tirando do plano.")
                    .font(.caption).foregroundStyle(Theme.textMuted)
            }
            .padding(20)
        }
        .navigationTitle("Visão geral")
        .onAppear {
            load()
            limits.refresh(ifOlderThan: 120)
        }
        .onChange(of: usage.lastUpdated) { _, _ in load() }
        .onChange(of: usage.progress) { _, progress in
            // Durante a primeira indexação, atualiza a cada ~10%.
            if Int(progress * 100) % 10 == 0 { load() }
        }
    }

    private func load() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let week = calendar.date(byAdding: .day, value: -6, to: today)!
        let month = calendar.date(byAdding: .day, value: -29, to: today)!
        usage.read({ worker in
            OverviewData(
                today: worker.totals(since: today),
                week: worker.totals(since: week),
                month: worker.totals(since: month),
                daily: worker.daily(days: 14),
                projects: worker.projects(since: week),
                models: worker.models(since: week)
            )
        }) { data = $0 }
    }
}

/// Faixa do horário de pico: em pico, âmbar com o horário de fim; fora, só uma linha com o próximo.
private struct PeakBanner: View {
    let isPeak: Bool
    let boundary: Date?

    var body: some View {
        if isPeak, let end = boundary {
            HStack(spacing: 10) {
                Image(systemName: "flame.fill").foregroundStyle(Theme.ember)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Horário de pico do Claude até \(end.formatted(date: .omitted, time: .shortened))").fontWeight(.semibold)
                    Text("A janela de 5h gasta mais rápido agora (a semanal não muda). Deixe tarefas pesadas e workflows para depois, se der.")
                        .font(.callout).foregroundStyle(Theme.textMuted)
                }
                Spacer()
            }
            .padding(14)
            .background(Theme.ember.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.ember.opacity(0.45)))
        } else if let next = boundary {
            Label("Fora do horário de pico · o próximo começa \(next.formatted(.relative(presentation: .named))) (\(next.formatted(date: .abbreviated, time: .shortened)))",
                  systemImage: "moon.stars")
                .font(.caption).foregroundStyle(Theme.textMuted)
        }
    }
}

struct IndexingBanner: View {
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Lendo o histórico do Claude Code pela primeira vez…").font(.headline)
            ProgressView(value: progress)
            Text("Leva cerca de 1 minuto. Depois disso, só as novidades são lidas.")
                .font(.caption).foregroundStyle(Theme.textMuted)
        }
        .card()
    }
}

struct LimitCard: View {
    let title: String
    let window: RateWindow?

    var body: some View {
        MPMeter(label: title, value: window.flatMap { $0.isExpired ? nil : $0.usedPercentage }, foot: foot)
    }

    private var foot: String {
        guard let window else { return "Sem leitura ainda" }
        if window.isExpired { return "Janela reiniciada" }
        return "Reinicia em \(Format.until(window.resetsAt)) · \(window.resetsAt.formatted(date: .omitted, time: .shortened))"
    }
}

struct StatCard: View {
    let title: String
    let totals: UsageTotals

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(Theme.textMuted)
            Text(Format.usd(totals.cost)).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
            Text("\(Format.tokens(totals.tokens)) tokens · \(totals.sessions) sessões")
                .font(.caption).foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(Theme.display(20))
    }
}

extension View {
    func card() -> some View {
        padding(16)
            .background(Theme.plumage, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.quill))
    }
}
