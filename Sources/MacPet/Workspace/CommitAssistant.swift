import Foundation

struct CommitGroup: Identifiable, Hashable {
    let id = UUID()
    var message: String
    var files: [String]
    var include = true
}

/// Ações de IA do painel de git, com chamadas enxutas do Claude Code: sem ferramentas,
/// sem hooks/plugins (setting-sources vazio) e sem salvar sessão. Custam centavos.
enum CommitAssistant {
    enum Failure: LocalizedError {
        case missingClaude, failed(String), unreadable

        var errorDescription: String? {
            switch self {
            case .missingClaude: "Não encontrei o comando `claude` no seu PATH."
            case .failed(let message): message
            case .unreadable: "Não entendi a resposta do Claude. Tente de novo."
            }
        }
    }

    static func commitMessage(diff: String, recentSubjects: [String], in directory: String) async throws -> String {
        let prompt = """
            Escreva a mensagem de commit para as mudanças abaixo.
            Siga EXATAMENTE a convenção e o idioma dos commits recentes deste repositório:
            \(recentSubjects.map { "- \($0)" }.joined(separator: "\n"))

            Responda só com a mensagem: uma linha de assunto e, se ajudar, uma linha em branco e um corpo curto.

            Diff:
            \(diff)
            """
        return try await ask(prompt, system: "Você escreve mensagens de commit. Responda apenas com a mensagem, sem crases nem comentários.",
                             model: "haiku", in: directory)
    }

    static func splitCommits(diff: String, files: [String], recentSubjects: [String], in directory: String) async throws -> [CommitGroup] {
        let prompt = """
            As mudanças abaixo misturam assuntos diferentes. Agrupe os arquivos em commits lógicos e coesos
            (normalmente 1 a 5), na ordem em que deveriam ser commitados. Cada arquivo entra em exatamente um grupo.
            A mensagem de cada commit segue a convenção e o idioma destes commits recentes:
            \(recentSubjects.map { "- \($0)" }.joined(separator: "\n"))

            Arquivos: \(files.joined(separator: ", "))

            Responda SOMENTE com JSON: {"commits":[{"message":"...","files":["caminho", ...]}]}

            Diff:
            \(diff)
            """
        let text = try await ask(prompt, system: "Você organiza mudanças de código em commits. Responda apenas com JSON válido.",
                                 model: "sonnet", in: directory)
        guard let json = extractJSON(text),
              let commits = json["commits"] as? [[String: Any]] else { throw Failure.unreadable }
        let known = Set(files)
        var groups = commits.compactMap { commit -> CommitGroup? in
            guard let message = commit["message"] as? String else { return nil }
            let groupFiles = (commit["files"] as? [String] ?? []).filter(known.contains)
            return groupFiles.isEmpty ? nil : CommitGroup(message: message, files: groupFiles)
        }
        // Arquivos que a IA esqueceu vão para um grupo extra, para nada ficar para trás.
        let covered = Set(groups.flatMap(\.files))
        let missing = files.filter { !covered.contains($0) }
        if !missing.isEmpty { groups.append(CommitGroup(message: "chore: demais alterações", files: missing)) }
        return groups
    }

    static func review(diff: String, in directory: String) async throws -> String {
        let prompt = """
            Revise as mudanças abaixo como um revisor sênior. Procure bugs, regressões, problemas de segurança,
            casos de borda não tratados e erros de lógica. Ignore estilo e preferências.
            Liste só achados relevantes, do mais grave para o menos grave, em Markdown, cada um com arquivo,
            o problema e a correção sugerida. Se não houver nada relevante, diga só "Nenhum problema relevante encontrado."
            Responda em português.

            Diff:
            \(diff)
            """
        return try await ask(prompt, system: "Você é um revisor de código rigoroso e objetivo.", model: "sonnet", in: directory)
    }

    static func branchName(diff: String, in directory: String) async throws -> String {
        let prompt = """
            Sugira um nome de branch git curto para estas mudanças, no formato tipo/descricao-em-kebab-case
            (tipos: feat, fix, refactor, chore, docs), em inglês, até 40 caracteres. Responda só com o nome.

            Diff:
            \(diff.prefix(20_000))
            """
        let name = try await ask(prompt, system: "Responda apenas com o nome da branch.", model: "haiku", in: directory)
        return name.trimmingCharacters(in: CharacterSet(charactersIn: " \n`'\""))
    }

    /// "Corrigir preço do fardo" → "fix/bundle-price"
    static func taskBranch(title: String, in directory: String) async throws -> String {
        let prompt = """
            Crie um nome de branch git para a tarefa abaixo. Traduza as palavras para o inglês: nunca use português.
            Formato tipo/descricao-em-kebab-case (tipos: feat, fix, refactor, chore, docs, test), até 40 caracteres.
            Exemplos: "Corrigir login com Google" → fix/google-login; "Adicionar filtro de data no relatório" → feat/report-date-filter.
            Responda só com o nome.

            Tarefa: \(title)
            """
        let name = try await ask(prompt, system: "Responda apenas com o nome da branch.", model: "haiku", in: directory)
        return sanitizeBranch(name)
    }

    /// Só minúsculas, números, "/" e "-": o que vier do modelo vira um nome de branch válido.
    static func sanitizeBranch(_ text: String) -> String {
        let lowered = text.trimmingCharacters(in: CharacterSet(charactersIn: " \n`'\""))
            .folding(options: .diacriticInsensitive, locale: nil).lowercased()
        let kept = lowered.map { $0.isLetter && $0.isASCII || $0.isNumber || $0 == "/" || $0 == "-" ? $0 : "-" }
        return String(kept).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
    }

    static func pullRequest(commits: String, stat: String, recentSubjects: [String], in directory: String) async throws -> (title: String, body: String) {
        let prompt = """
            Escreva o título e a descrição de um Pull Request para os commits abaixo.
            Use o mesmo idioma dos commits. O título segue a convenção destes commits recentes:
            \(recentSubjects.prefix(6).map { "- \($0)" }.joined(separator: "\n"))
            A descrição em Markdown tem: um resumo de 1-3 frases, uma seção com as mudanças principais em tópicos
            e uma seção de como testar.

            Responda SOMENTE com JSON: {"title":"...","body":"..."}

            Commits:
            \(commits.prefix(20_000))

            Arquivos:
            \(stat.prefix(8_000))
            """
        let text = try await ask(prompt, system: "Você escreve Pull Requests claros. Responda apenas com JSON válido.", model: "haiku", in: directory)
        guard let json = extractJSON(text), let title = json["title"] as? String, let body = json["body"] as? String else {
            throw Failure.unreadable
        }
        return (title, body)
    }

    // MARK: Infra

    private static func ask(_ prompt: String, system: String, model: String, in directory: String) async throws -> String {
        guard let claude = ClaudeCLI.executable else { throw Failure.missingClaude }
        let result = await Shell.run(claude, [
            "-p", "--model", model, "--tools", "", "--setting-sources", "", "--strict-mcp-config",
            "--no-session-persistence", "--disable-slash-commands", "--system-prompt", system,
            "--output-format", "json",
        ], in: directory, input: prompt)
        guard let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.failed(result.stderr.isEmpty ? "O Claude não respondeu." : result.stderr)
        }
        if json["is_error"] as? Bool == true {
            throw Failure.failed(json["result"] as? String ?? "Erro do Claude.")
        }
        return (json["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extrai o primeiro objeto JSON da resposta (às vezes vem cercado de ```json).
    private static func extractJSON(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
    }
}

/// Abre Pull Requests com o GitHub CLI.
enum GitHubCLI {
    static var path: String? { ShellEnvironment.which("gh") }

    static func isAuthenticated() async -> Bool {
        guard let gh = path else { return false }
        return await Shell.run(gh, ["auth", "status"], in: NSHomeDirectory()).ok
    }

    static func createPR(title: String, body: String, base: String, in directory: String) async -> CommandResult {
        guard let gh = path else { return CommandResult(status: -1, stdout: "", stderr: "GitHub CLI (gh) não instalado.") }
        return await Shell.run(gh, ["pr", "create", "--title", title, "--body", body, "--base", base], in: directory)
    }
}
