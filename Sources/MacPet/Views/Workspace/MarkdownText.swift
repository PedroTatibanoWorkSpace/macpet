import AppKit
import SwiftUI

/// Markdown das respostas do Claude: parágrafos, títulos, listas, citações, divisórias,
/// blocos de código e tabelas. Feito para leitura confortável (largura e entrelinha generosas).
struct MarkdownText: View {
    let text: String

    enum Block: Hashable {
        case paragraph(String)
        case heading(String, level: Int)
        case code(String, language: String)
        case table(header: [String], rows: [[String]])
        case quote(String)
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .paragraph(let content):
            Text(Self.inline(content))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let content, let level):
            Text(Self.inline(content))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
                .textSelection(.enabled)
        case .quote(let content):
            Text(Self.inline(content))
                .lineSpacing(3)
                .foregroundStyle(Theme.textMuted)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.quillStrong).frame(width: 3) }
                .textSelection(.enabled)
        case .rule:
            MPDivider().padding(.vertical, 2)
        case .code(let content, let language):
            CodeBlock(content: content, language: language)
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows)
        }
    }

    static func inline(_ string: String) -> AttributedString {
        safeLinks((try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(string))
    }

    /// Só links da web continuam clicáveis. O texto vem do Claude (que pode ter lido instruções plantadas num
    /// repositório) ou de um SKILL.md do projeto, e um `file://` escondido atrás do texto abriria um .app ou
    /// .command que veio pelo git clone, sem quarentena.
    static func safeLinks(_ string: AttributedString) -> AttributedString {
        var result = string
        for run in string.runs {
            guard let url = run.link, !["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { continue }
            result[run.range].link = nil
        }
        return result
    }

    // MARK: Parser

    static func parse(_ text: String) -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var table: [String] = []
        var code: [String]?
        var language = ""

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { result.append(.paragraph(joined)) }
            paragraph = []
        }
        func flushQuote() {
            if !quote.isEmpty { result.append(.quote(quote.joined(separator: "\n"))) }
            quote = []
        }
        func flushTable() {
            defer { table = [] }
            let rows = table.map(cells)
            // Precisa de cabeçalho + linha separadora (|---|---|) para ser tabela.
            guard rows.count >= 2, rows[1].allSatisfy(isSeparatorCell) else {
                paragraph += table
                return
            }
            let width = rows[0].count
            let body = rows.dropFirst(2).map { row in
                Array((row + Array(repeating: "", count: max(0, width - row.count))).prefix(width))
            }
            result.append(.table(header: rows[0], rows: Array(body)))
        }
        func flushAll() {
            flushParagraph()
            flushQuote()
            if !table.isEmpty { flushTable() }
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if let current = code {
                    result.append(.code(current.joined(separator: "\n"), language: language))
                    code = nil
                } else {
                    flushAll()
                    language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }

            if trimmed.hasPrefix("|"), trimmed.dropFirst().contains("|") {
                flushParagraph()
                flushQuote()
                table.append(trimmed)
                continue
            } else if !table.isEmpty {
                flushTable()
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            } else {
                flushQuote()
            }

            if let match = line.firstMatch(of: #/^(#{1,6})\s+(.*)$/#) {
                flushParagraph()
                result.append(.heading(String(match.2), level: match.1.count))
            } else if trimmed.isEmpty {
                flushParagraph()
            } else if trimmed.firstMatch(of: #/^([-*_])(\s*\1){2,}$/#) != nil {
                flushParagraph()
                result.append(.rule)
            } else if let bullet = line.firstMatch(of: #/^(\s*)[-*+]\s+(.*)$/#) {
                // Lista com marcador: "•" mantendo o recuo dos subitens.
                paragraph.append("\(bullet.1)• \(bullet.2)")
            } else {
                paragraph.append(line)
            }
        }
        if let current = code { result.append(.code(current.joined(separator: "\n"), language: language)) }
        flushAll()
        return result
    }

    private static func cells(_ line: String) -> [String] {
        var content = line.trimmingCharacters(in: .whitespaces)
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|") { content.removeLast() }
        // "\|" é uma barra literal dentro da célula.
        let placeholder = "\u{0}"
        return content.replacingOccurrences(of: "\\|", with: placeholder)
            .components(separatedBy: "|")
            .map { $0.replacingOccurrences(of: placeholder, with: "|").trimmingCharacters(in: .whitespaces) }
    }

    private static func isSeparatorCell(_ cell: String) -> Bool {
        !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " } && cell.contains("-")
    }
}

/// Tabela com cabeçalho, divisórias entre linhas e quebra de texto nas células.
/// Sem rolagem horizontal: colunas de conteúdo curto (números, "Sim/Não") ficam do tamanho do
/// conteúdo e as demais dividem o resto da largura.
struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        let compact = compactColumns
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                    cellView(cell, compact: compact.contains(column))
                        .font(.callout.weight(.semibold))
                        .background(Theme.plumageRaised)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                MPDivider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        cellView(cell, compact: compact.contains(column))
                            .font(.callout)
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.quill))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var compactColumns: Set<Int> {
        Set(header.indices.filter { column in
            ([header] + rows).allSatisfy { row in column >= row.count || row[column].count <= 14 }
        })
    }

    @ViewBuilder
    private func cellView(_ text: String, compact: Bool) -> some View {
        let content = Text(MarkdownText.inline(text))
            .lineSpacing(2)
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        if compact {
            content
                .fixedSize()
                .frame(maxHeight: .infinity, alignment: .topLeading)
        } else {
            content
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 60, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct CodeBlock: View {
    let content: String
    let language: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "código" : language).font(.caption2).foregroundStyle(Theme.textMuted)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copiar")
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            ScrollView(.horizontal) {
                Text(content)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Theme.ink.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.quill))
    }
}
