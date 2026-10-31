import AppKit
import SwiftUI

struct ChangesView: View {
    @ObservedObject var repo: GitRepo
    let project: Project
    @State private var selected: GitFile?
    @State private var selectedStaged = false
    @State private var diff = ""
    @State private var message = ""
    @State private var aiBusy: String?
    /// Revisão do PR aberta no lugar do diff (o resultado fica guardado em `BranchReview` por repositório).
    @State private var showingReview = false
    @State private var groups: [CommitGroup]?
    @State private var newBranch: String?
    @State private var pr: (title: String, body: String, base: String)?
    @State private var discardTarget: GitFile?

    var body: some View {
        Group {
            if !repo.isRepo {
                MPEmptyState(title: "Não é um repositório git", message: project.path) {
                    MPEmptyIcon(systemName: "externaldrive.badge.xmark")
                }
            } else {
                HSplitView {
                    sidebar.frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
                    detail.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { await repo.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await repo.refresh() }
        }
        .mpSheet(isPresented: Binding(get: { groups != nil }, set: { if !$0 { groups = nil } })) {
            SplitCommitsSheet(groups: Binding(get: { groups ?? [] }, set: { groups = $0 }), repo: repo) { groups = nil }
                .mpDialogSurface()
        }
        .mpSheet(isPresented: Binding(get: { newBranch != nil }, set: { if !$0 { newBranch = nil } })) {
            BranchSheet(name: Binding(get: { newBranch ?? "" }, set: { newBranch = $0 }), repo: repo) { newBranch = nil }
                .mpDialogSurface()
        }
        .mpSheet(isPresented: Binding(get: { pr != nil }, set: { if !$0 { pr = nil } })) {
            if let pr {
                PullRequestSheet(title: pr.title, body: pr.body, base: pr.base, repo: repo,
                                 review: BranchReview.for(project.path)) { self.pr = nil } onReview: {
                    self.pr = nil
                    openReview(start: true)
                }
                .mpDialogSurface()
            }
        }
        .mpDialog(isPresented: Binding(get: { discardTarget != nil }, set: { if !$0 { discardTarget = nil } }),
                  title: "Descartar as alterações em \(discardTarget?.name ?? "")?",
                  message: "Arquivos novos vão para a Lixeira; os demais voltam à versão do último commit.",
                  actions: [
                    MPDialogAction(label: "Cancelar"),
                    MPDialogAction(label: "Descartar", variant: .danger) {
                        if let file = discardTarget { Task { await repo.discard(file) } }
                    },
                  ])
    }

    // MARK: Lista de arquivos + commit

    private var sidebar: some View {
        VStack(spacing: 0) {
            branchBar
            MPDivider()
            MPList {
                if !repo.staged.isEmpty {
                    MPListSection("Preparados para o commit (\(repo.staged.count))")
                    ForEach(repo.staged) { file in fileRow(file, staged: true) }
                }
                MPListSection("Alterações (\(repo.unstaged.count))", trailing: repo.unstaged.isEmpty ? nil : AnyView(
                    Button("Preparar tudo") { Task { await repo.stageAll() } }.buttonStyle(.mp(.ghost, size: .sm))))
                ForEach(repo.unstaged) { file in fileRow(file, staged: false) }
                if repo.files.isEmpty {
                    Text("Nada para commitar.").font(.system(size: 12)).foregroundStyle(Theme.textMuted).padding(.horizontal, 10)
                }
                if !repo.log.isEmpty {
                    MPListSection("Commits recentes")
                    ForEach(repo.log.prefix(8)) { commit in
                        MPListRow(title: commit.subject, subtitle: "\(commit.author) · \(Format.relative(commit.date))")
                            .help(commit.subject)
                    }
                }
            }
            MPDivider()
            commitBox
        }
    }

    private var branchBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                Text(repo.branch ?? "—").fontWeight(.semibold).lineLimit(1)
                if repo.ahead > 0 { Text("↑\(repo.ahead)").foregroundStyle(Theme.textMuted) }
                if repo.behind > 0 { Text("↓\(repo.behind)").foregroundStyle(Theme.ember) }
                Spacer()
                if let busy = repo.busy ?? aiBusy {
                    ProgressView { Text(busy) }
                }
            }
            HStack(spacing: 6) {
                Button("Pull") { Task { await repo.pull() } }
                Button("Push") { Task { await repo.push() } }
                Button("Nova branch") { suggestBranch() }
                Button { openReview(start: BranchReview.for(project.path).state == .idle) } label: {
                    Label("Revisar PR", systemImage: "checkmark.shield")
                }
                .help("O Claude revisa tudo o que entra no PR (commits da branch e o que não foi commitado) lendo o código em volta")
                Button("Abrir PR") { preparePR() }
                Spacer()
                MPIconButton(icon: "arrow.clockwise", label: "Atualizar") { Task { await repo.refresh() } }
            }
            .controlSize(.small)
            .disabled(repo.busy != nil || aiBusy != nil)
            if let error = repo.lastError {
                Text(error).font(.caption).foregroundStyle(Theme.danger).lineLimit(4).textSelection(.enabled)
            } else if let info = repo.lastInfo {
                Text(info).font(.caption).foregroundStyle(Theme.success).lineLimit(2)
            }
        }
        .padding(10)
    }

    private func fileRow(_ file: GitFile, staged: Bool) -> some View {
        MPListRow(title: file.name, subtitle: file.directory.isEmpty ? nil : file.directory,
                  selected: selected?.path == file.path && selectedStaged == staged) {
            Text(file.badge)
                .font(Theme.mono(10, weight: .bold))
                .frame(width: 18, height: 18)
                .foregroundStyle(file.badge == "D" ? AnyShapeStyle(Theme.danger) : file.badge == "N" || file.badge == "A" ? AnyShapeStyle(Theme.success) : AnyShapeStyle(Theme.ember))
                .background(Theme.plumageRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.xs))
        } trailing: {
            MPIconButton(icon: staged ? "minus.circle" : "plus.circle", label: staged ? "Tirar do commit" : "Preparar para o commit") {
                Task { staged ? await repo.unstage([file.path]) : await repo.stage([file.path]) }
            }
        }
        .onTapGesture { select(file, staged: staged) }
        .mpContextMenu {[
            .item("Abrir arquivo", icon: "doc") { NSWorkspace.shared.open(URL(fileURLWithPath: project.path).appendingPathComponent(file.path)) },
            .item("Mostrar no Finder", icon: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path).appendingPathComponent(file.path)])
            },
            .divider,
            .item("Descartar alterações…", icon: "arrow.uturn.backward", danger: true) { discardTarget = file },
        ]}
    }

    private var commitBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            MPTextArea(text: $message, placeholder: "Mensagem do commit", mono: true, height: 70)

            HStack(spacing: 6) {
                Button { generateMessage() } label: { Label("Mensagem", systemImage: "sparkles") }
                    .help("O Claude escreve a mensagem no padrão deste repositório")
                Button { splitCommits() } label: { Label("Separar", systemImage: "square.split.2x1") }
                    .help("O Claude divide as alterações em commits lógicos")
            }
            .controlSize(.small)
            .disabled(repo.files.isEmpty || aiBusy != nil)

            Button {
                Task {
                    if repo.staged.isEmpty { await repo.stageAll() }
                    if await repo.commit(message: message) { message = "" }
                }
            } label: {
                Text(repo.staged.isEmpty ? "Commit de tudo" : "Commit (\(repo.staged.count) arquivos)").frame(maxWidth: .infinity)
            }
            .buttonStyle(.mp(.primary))
            .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || repo.files.isEmpty || repo.busy != nil)
            .keyboardShortcut(.return, modifiers: [.command, .shift])
        }
        .padding(10)
    }

    // MARK: Diff / revisão

    @ViewBuilder
    private var detail: some View {
        if showingReview {
            BranchReviewView(review: BranchReview.for(project.path), repo: repo, project: project,
                             onClose: { showingReview = false }, onOpenPR: { preparePR() })
        } else if let selected {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(selected.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Text(selectedStaged ? "preparado" : "não preparado").font(.caption).foregroundStyle(Theme.textMuted)
                }
                .padding(10)
                MPDivider()
                UnifiedDiffView(diff: diff)
            }
        } else {
            MPEmptyState(title: "Selecione um arquivo", message: "O diff dele aparece aqui, com as linhas numeradas.") {
                MPEmptyIcon(systemName: "doc.text.magnifyingglass")
            }
        }
    }

    private func select(_ file: GitFile, staged: Bool) {
        selected = file
        selectedStaged = staged
        showingReview = false
        Task { diff = await repo.diff(for: file, staged: staged) }
    }

    // MARK: IA

    private func withAI(_ label: String, _ work: @escaping () async throws -> Void) {
        aiBusy = label
        repo.lastError = nil
        Task {
            do { try await work() } catch { repo.lastError = error.localizedDescription }
            aiBusy = nil
        }
    }

    private func generateMessage() {
        withAI("Escrevendo mensagem…") {
            let input = await repo.diffForAI()
            message = try await CommitAssistant.commitMessage(diff: input.diff, recentSubjects: repo.recentSubjects(), in: project.path)
        }
    }

    private func openReview(start: Bool) {
        showingReview = true
        if start { BranchReview.for(project.path).start(repo: repo) }
    }

    private func splitCommits() {
        withAI("Separando em commits…") {
            let input = await repo.diffForAI()
            groups = try await CommitAssistant.splitCommits(diff: input.diff, files: input.files,
                                                           recentSubjects: repo.recentSubjects(), in: project.path)
        }
    }

    private func suggestBranch() {
        withAI("Sugerindo nome…") {
            let input = await repo.diffForAI(limit: 20_000)
            let name = repo.files.isEmpty ? "" : (try? await CommitAssistant.branchName(diff: input.diff, in: project.path)) ?? ""
            newBranch = name
        }
    }

    private func preparePR() {
        withAI("Escrevendo PR…") {
            guard await GitHubCLI.isAuthenticated() else {
                repo.lastError = "Para abrir PRs, faça login no GitHub CLI: rode `gh auth login` no terminal do projeto."
                return
            }
            let info = await repo.commitsForPR()
            guard !info.log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                repo.lastError = "Não há commits nesta branch além de origin/\(info.base)."
                return
            }
            let text = try await CommitAssistant.pullRequest(commits: info.log, stat: info.stat,
                                                            recentSubjects: repo.recentSubjects(), in: project.path)
            pr = (text.title, text.body, info.base)
        }
    }
}

/// Diff unificado legível: números das linhas antigas e novas, linhas longas quebrando na largura
/// da tela (sem rolagem lateral) e só o que importa — os cabeçalhos técnicos do git ficam de fora.
struct UnifiedDiffView: View {
    let diff: String

    struct Row: Identifiable {
        enum Kind { case context, added, removed, hunk, note }
        let id: Int
        let kind: Kind
        let old: Int?
        let new: Int?
        let text: String
    }

    var body: some View {
        let rows = Self.rows(diff)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    if row.kind == .hunk {
                        Text(row.text.isEmpty ? "…" : row.text)
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.sheen)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Theme.sheen.opacity(0.08))
                            .padding(.top, row.id == 0 ? 0 : 8)
                    } else if row.kind == .note {
                        Text(row.text).font(.callout).foregroundStyle(Theme.textMuted).padding(12)
                    } else {
                        line(row)
                    }
                }
            }
            .textSelection(.enabled)
            .padding(.bottom, 12)
        }
        .background(Theme.ink)
    }

    private func line(_ row: Row) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(row.old.map(String.init) ?? "").frame(width: 42, alignment: .trailing)
            Text(row.new.map(String.init) ?? "").frame(width: 42, alignment: .trailing)
                .padding(.trailing, 8)
            Text(row.kind == .added ? "+" : row.kind == .removed ? "−" : " ")
                .frame(width: 14)
                .foregroundStyle(row.kind == .added ? AnyShapeStyle(Theme.success) : row.kind == .removed ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(Color.clear))
            Text(row.text.isEmpty ? " " : row.text)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 12)
        }
        .font(Theme.mono(11.5))
        .foregroundStyle(Theme.textFaint)
        .padding(.vertical, 1)
        .background(row.kind == .added ? Theme.diffAdd : row.kind == .removed ? Theme.diffRemove : .clear)
    }

    /// Linhas acima disso são cortadas (ex.: um JSON inteiro numa linha só), para a tela não travar.
    private static let maxLineLength = 2_000

    static func rows(_ diff: String) -> [Row] {
        var rows: [Row] = []
        var old = 0, new = 0
        func add(_ kind: Row.Kind, _ text: String, old: Int? = nil, new: Int? = nil) {
            var text = text
            if text.count > maxLineLength {
                text = String(text.prefix(maxLineLength)) + "  … (+\(text.count - maxLineLength) caracteres)"
            }
            rows.append(Row(id: rows.count, kind: kind, old: old, new: new, text: text))
        }
        for line in diff.components(separatedBy: "\n").prefix(8_000) {
            if line.hasPrefix("@@") {
                // "@@ -10,7 +10,8 @@ func exemplo()" → numeração e o contexto depois do segundo @@.
                if let match = line.firstMatch(of: #/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@ ?(.*)$/#) {
                    old = Int(match.1) ?? 0
                    new = Int(match.2) ?? 0
                    add(.hunk, "linha \(new)" + (match.3.isEmpty ? "" : " · \(match.3)"))
                } else {
                    old = 0
                    new = 1
                    add(.hunk, "arquivo novo")
                }
            } else if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                        || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode") || line.hasPrefix("\\ No newline") {
                continue
            } else if line.hasPrefix("+") {
                add(.added, String(line.dropFirst()), new: new)
                new += 1
            } else if line.hasPrefix("-") {
                add(.removed, String(line.dropFirst()), old: old)
                old += 1
            } else if line.hasPrefix(" ") {
                add(.context, String(line.dropFirst()), old: old, new: new)
                old += 1
                new += 1
            } else if !line.isEmpty, rows.isEmpty {
                add(.note, line)  // "Sem diferenças.", "Arquivo novo (binário)."…
            }
        }
        return rows
    }
}

// MARK: - Folhas

private struct SplitCommitsSheet: View {
    @Binding var groups: [CommitGroup]
    let repo: GitRepo
    let onClose: () -> Void
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Commits sugeridos pelo Claude").font(Theme.display(20))
            Text("Revise as mensagens e desmarque o que não quiser commitar agora. Os commits são feitos na ordem abaixo.")
                .font(.callout).foregroundStyle(Theme.textMuted)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($groups) { $group in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 8) {
                                Toggle("", isOn: $group.include).toggleStyle(.mpCheckbox).labelsHidden().padding(.top, 6)
                                TextField("Mensagem", text: $group.message, axis: .vertical).textFieldStyle(.mpMono)
                            }
                            Text(group.files.joined(separator: "\n"))
                                .font(.caption.monospaced()).foregroundStyle(Theme.textMuted)
                                .padding(.leading, 22)
                        }
                        .padding(10)
                        .background(Theme.plumageRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
                    }
                }
            }
            HStack {
                Button("Cancelar", action: onClose)
                Spacer()
                Button("Fazer \(groups.filter(\.include).count) commits") {
                    running = true
                    Task {
                        for group in groups where group.include {
                            guard await repo.commit(message: group.message, paths: group.files) else { break }
                        }
                        running = false
                        onClose()
                    }
                }
                .buttonStyle(.mp(.primary))
                .disabled(running || !groups.contains(where: \.include))
            }
        }
        .frame(width: 620, height: 500)
    }
}

private struct BranchSheet: View {
    @Binding var name: String
    let repo: GitRepo
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nova branch").font(Theme.display(20))
            Text("Criada a partir de \(repo.branch ?? "HEAD"), levando suas alterações junto.").font(.callout).foregroundStyle(Theme.textMuted)
            TextField("feat/my-change", text: $name).textFieldStyle(.mpMono)
            HStack {
                Button("Cancelar", action: onClose)
                Spacer()
                Button("Criar branch") {
                    Task {
                        await repo.createBranch(name.trimmingCharacters(in: .whitespaces))
                        onClose()
                    }
                }
                .buttonStyle(.mp(.primary))
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(width: 420)
    }
}

private struct PullRequestSheet: View {
    @State var title: String
    @State var body_: String
    let base: String
    let repo: GitRepo
    @ObservedObject var review: BranchReview
    let onClose: () -> Void
    let onReview: () -> Void
    @State private var sending = false
    @State private var error: String?
    @State private var head = ""

    init(title: String, body: String, base: String, repo: GitRepo, review: BranchReview,
         onClose: @escaping () -> Void, onReview: @escaping () -> Void) {
        _title = State(initialValue: title)
        _body_ = State(initialValue: body)
        self.base = base
        self.repo = repo
        self.review = review
        self.onClose = onClose
        self.onReview = onReview
    }

    /// Revisão desta versão da branch: quantos problemas altos ficaram, ou o convite para revisar.
    @ViewBuilder
    private var reviewNote: some View {
        let current = review.state == .done && review.reviewedHead == head
        let high = review.findings.filter { $0.severity == .high }.count
        HStack(spacing: 8) {
            if current, high > 0 {
                MPBadge(text: "\(high) problema\(high == 1 ? "" : "s") alto\(high == 1 ? "" : "s") na revisão", tone: .danger, icon: "exclamationmark.triangle")
            } else if current {
                MPBadge(text: "Revisado: nada alto", tone: .success, icon: "checkmark.shield")
            } else {
                Text("Esta versão da branch ainda não foi revisada.").font(.caption).foregroundStyle(Theme.textMuted)
                Button("Revisar antes", action: onReview).buttonStyle(.mp(.ghost, size: .sm))
            }
            Spacer()
        }
        .task { head = await repo.currentHead() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pull Request: \(repo.branch ?? "") → \(base)").font(Theme.display(20))
            TextField("Título", text: $title).textFieldStyle(.mp)
            MPTextArea(text: $body_, mono: true, height: 280)
            reviewNote
            if let error { Text(error).font(.caption).foregroundStyle(Theme.danger).textSelection(.enabled) }
            HStack {
                Button("Cancelar", action: onClose)
                Spacer()
                Button("Push e abrir PR") {
                    sending = true
                    Task {
                        await repo.push()
                        let result = await GitHubCLI.createPR(title: title, body: body_, base: base, in: repo.path)
                        sending = false
                        if result.ok {
                            let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                            repo.lastInfo = "PR aberto: \(url)"
                            if let link = URL(string: url) { NSWorkspace.shared.open(link) }
                            onClose()
                        } else {
                            error = result.stderr.isEmpty ? result.stdout : result.stderr
                        }
                    }
                }
                .buttonStyle(.mp(.primary))
                .disabled(sending || title.isEmpty)
            }
        }
        .frame(width: 640, height: 500)
    }
}
