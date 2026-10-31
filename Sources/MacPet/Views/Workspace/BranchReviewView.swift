import SwiftUI

/// Revisão do PR no painel de alterações: o que o Claude está lendo enquanto revisa e, no fim,
/// os achados por gravidade, cada um com "Corrigir no chat" e "Ver no diff".
struct BranchReviewView: View {
    @ObservedObject var review: BranchReview
    @ObservedObject var repo: GitRepo
    let project: Project
    let onClose: () -> Void
    let onOpenPR: () -> Void
    @EnvironmentObject private var store: ProjectStore
    @State private var currentHead = ""
    @State private var diffFile: (finding: ReviewFinding, diff: String)?
    @State private var sent: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            MPDivider()
            if let diffFile {
                diffView(diffFile.finding, diff: diffFile.diff)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) { content }
                        .padding(16)
                        .frame(maxWidth: 760, alignment: .leading)
                }
            }
        }
        .task(id: review.state) { currentHead = await repo.currentHead() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield").foregroundStyle(Theme.sheen)
            VStack(alignment: .leading, spacing: 1) {
                Text("Revisão do PR").font(.headline)
                Text("\(repo.branch ?? "HEAD") → \(review.base.isEmpty ? "base" : review.base)")
                    .font(Theme.mono(11)).foregroundStyle(Theme.textMuted)
            }
            if isOutdated {
                MPBadge(text: "desatualizada", tone: .ember, icon: "clock.arrow.circlepath")
                    .help("A branch mudou depois desta revisão.")
            }
            Spacer()
            if review.state == .done, review.cost > 0 {
                Text(Format.usd(review.cost)).font(Theme.mono(11)).foregroundStyle(Theme.textFaint)
            }
            if review.isRunning {
                Button("Cancelar") { review.cancel() }.buttonStyle(.mp(.secondary, size: .sm))
            } else {
                Button(review.state == .idle ? "Revisar" : "Revisar de novo") { start() }.buttonStyle(.mp(.secondary, size: .sm))
            }
            MPIconButton(icon: "xmark", label: "Fechar revisão", action: onClose)
        }
        .padding(12)
    }

    private var isOutdated: Bool {
        review.state == .done && !currentHead.isEmpty && !review.reviewedHead.isEmpty && currentHead != review.reviewedHead
    }

    @ViewBuilder
    private var content: some View {
        switch review.state {
        case .idle:
            MPEmptyState(title: "Revise antes de abrir o PR",
                         message: "O Claude lê tudo o que entra no PR (commits da branch e o que ainda não foi commitado) e o código em volta, procurando bugs, regressões e falhas de segurança. Só leitura: ele não muda nada.") {
                MPEmptyIcon(systemName: "checkmark.shield")
            }
            Button("Revisar agora", action: start).buttonStyle(.mp(.primary)).frame(maxWidth: .infinity)
        case .running:
            HStack(alignment: .top, spacing: 12) {
                CrowView(mood: .working, scale: 1.5)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Revisando…").font(.callout.weight(.semibold))
                    ForEach(Array(review.steps.enumerated()), id: \.offset) { index, step in
                        Text(step).font(Theme.mono(11.5))
                            .foregroundStyle(index == 0 ? AnyShapeStyle(Theme.text) : AnyShapeStyle(Theme.textFaint))
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        case .failed(let message):
            MPBanner(tone: .danger, title: "A revisão não terminou", message: message)
        case .done:
            results
        }
    }

    @ViewBuilder
    private var results: some View {
        if let raw = review.rawText {
            MarkdownText(text: raw)
        } else {
            if !review.summary.isEmpty {
                Self.inline(review.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if review.findings.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success).font(.title3)
                    Text("Nada relevante. Pode abrir o PR.").font(.callout.weight(.semibold))
                    Spacer()
                    Button("Abrir PR", action: onOpenPR).buttonStyle(.mp(.primary, size: .sm))
                }
                .padding(12)
                .background(Theme.plumage, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            } else {
                HStack(spacing: 6) {
                    ForEach(ReviewFinding.Severity.allCases, id: \.self) { severity in
                        let count = review.findings.filter { $0.severity == severity }.count
                        if count > 0 { MPBadge(text: "\(count) \(severity.label(count))", tone: severity.tone) }
                    }
                    Spacer()
                    let pending = review.findings.filter { !sent.contains($0.id) }
                    if pending.count > 1 {
                        Button("Corrigir todos no chat") { fix(pending) }.buttonStyle(.mp(.primary, size: .sm))
                    }
                }
                ForEach(review.findings) { finding in card(finding) }
            }
        }
    }

    private func card(_ finding: ReviewFinding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MPBadge(text: finding.severity.title, tone: finding.severity.tone)
                Self.inline(finding.title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if !finding.file.isEmpty {
                Text(finding.location).font(Theme.mono(11)).foregroundStyle(Theme.sheen).textSelection(.enabled)
            }
            Self.inline(finding.problem).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if !finding.fix.isEmpty {
                (Text("Correção: ").fontWeight(.semibold) + Self.inline(finding.fix))
                    .font(.callout).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if sent.contains(finding.id) {
                    Label("Enviado ao chat", systemImage: "checkmark").font(.caption).foregroundStyle(Theme.success)
                } else {
                    Button("Corrigir no chat") { fix([finding]) }.buttonStyle(.mp(.secondary, size: .sm))
                }
                if !finding.file.isEmpty {
                    Button("Ver no diff") { showDiff(finding) }.buttonStyle(.mp(.ghost, size: .sm))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.plumage, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(finding.severity.color).frame(width: 3).padding(.vertical, 10)
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.quill))
    }

    private func diffView(_ finding: ReviewFinding, diff: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { diffFile = nil } label: { Label("Voltar à revisão", systemImage: "chevron.left") }
                    .buttonStyle(.mp(.ghost, size: .sm))
                Text(finding.location).font(Theme.mono(11)).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.head)
                Spacer()
            }
            .padding(8)
            MPDivider()
            if diff.isEmpty {
                MPEmptyState(title: "Sem diff para este arquivo", message: "Ele não mudou nesta branch; o problema está no código em volta.") {
                    MPEmptyIcon(systemName: "doc.text")
                }
            } else {
                UnifiedDiffView(diff: diff)
            }
        }
    }

    /// `código` e **negrito** do texto do Claude, sem virar bloco de Markdown.
    private static func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var attributed = (try? AttributedString(markdown: text, options: options)).map(MarkdownText.safeLinks) else { return Text(text) }
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = Theme.mono(12)
        }
        return Text(attributed)
    }

    private func start() {
        diffFile = nil
        sent = []
        review.start(repo: repo)
    }

    private func showDiff(_ finding: ReviewFinding) {
        Task { diffFile = (finding, await repo.reviewDiff(file: finding.file, base: review.base)) }
    }

    /// Manda para o chat deste projeto (o mesmo que fez as mudanças) e abre a aba do chat.
    private func fix(_ findings: [ReviewFinding]) {
        store.chat(for: project).send(BranchReview.fixRequest(findings))
        findings.forEach { sent.insert($0.id) }
        store.tabRequest = .chat
    }
}

extension ReviewFinding.Severity {
    var title: String {
        switch self {
        case .high: "Alta"
        case .medium: "Média"
        case .low: "Baixa"
        }
    }

    func label(_ count: Int) -> String {
        switch self {
        case .high: count == 1 ? "alta" : "altas"
        case .medium: count == 1 ? "média" : "médias"
        case .low: count == 1 ? "baixa" : "baixas"
        }
    }

    var tone: MPBadge.Tone {
        switch self {
        case .high: .danger
        case .medium: .ember
        case .low: .neutral
        }
    }

    var color: AnyShapeStyle {
        switch self {
        case .high: AnyShapeStyle(Theme.danger)
        case .medium: AnyShapeStyle(Theme.ember)
        case .low: AnyShapeStyle(Theme.textFaint)
        }
    }
}
