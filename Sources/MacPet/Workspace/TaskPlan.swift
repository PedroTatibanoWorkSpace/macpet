import Foundation

/// Plano de tarefas paralelas escrito pelo próprio Claude na conversa, num bloco ```macpet-tasks```.
/// Cada tarefa vira uma worktree com um agente novo que começa só com o briefing — não com o
/// histórico da conversa, que pode ter centenas de MB.
struct TaskPlan: Equatable {
    struct Item: Decodable, Hashable, Identifiable {
        let title: String
        let branch: String
        let base: String?
        let model: String?
        let effort: String?
        let brief: String

        var id: String { branch }
    }

    let items: [Item]

    /// Tokens aproximados de todos os briefings (≈ 4 caracteres por token).
    var briefTokens: Int { items.reduce(0) { $0 + $1.brief.count } / 4 }

    static let fence = "```macpet-tasks"

    /// Texto antes do bloco, o plano (nil se ainda chegando ou inválido) e o texto depois.
    static func split(_ text: String) -> (before: String, plan: TaskPlan?, pending: Bool, after: String)? {
        guard let start = text.range(of: fence) else { return nil }
        let before = String(text[..<start.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = text[start.upperBound...]
        guard let end = rest.range(of: "```") else { return (before, nil, true, "") }
        let json = rest[..<end.lowerBound]
        let after = String(rest[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        struct Envelope: Decodable { let tasks: [Item] }
        let plan = (try? JSONDecoder().decode(Envelope.self, from: Data(json.utf8))).map { TaskPlan(items: $0.tasks) }
        return (before, plan.flatMap { $0.items.isEmpty ? nil : $0 }, false, after)
    }

    /// Pedido do botão "Dividir em tarefas paralelas".
    static let request = "Divida o que conversamos em tarefas paralelas independentes e responda com o bloco macpet-tasks."

    /// Vai no `--append-system-prompt` de toda conversa do MacPet.
    static let systemPrompt = """
        Você está rodando dentro do MacPet, um painel que cria tarefas paralelas: cada tarefa é uma git worktree \
        com branch própria e um NOVO agente Claude que começa SEM o histórico desta conversa.
        Quando o usuário pedir para dividir o trabalho em tarefas paralelas, ou para lançar/disparar agentes ou tarefas, \
        explique a divisão em 1 a 3 frases e responda com UM bloco exatamente assim:
        ```macpet-tasks
        {"tasks":[{"title":"...","branch":"feat/...","model":"sonnet","effort":"medium","brief":"..."}]}
        ```
        Regras:
        - Só tarefas independentes, que não editem os mesmos arquivos. Se houver ordem obrigatória, diga e inclua só a primeira leva.
        - title em português, curto. branch sempre em inglês, kebab-case, com prefixo feat/, fix/, refactor/, chore/ ou test/.
        - "base" é opcional: omita para sair da branch atual.
        - model: "sonnet" para trabalho mecânico e bem especificado; "opus" só quando exigir julgamento difícil. effort: low, medium ou high.
        - brief é tudo o que o novo agente vai saber. Inclua objetivo, contexto e decisões já tomadas nesta conversa, \
        arquivos e funções relevantes com caminhos exatos, restrições, o que NÃO fazer, critério de pronto e como testar. \
        Seja completo mas enxuto (até ~400 palavras): aponte arquivos em vez de colar código e não peça para reexplorar o repositório inteiro.
        - O MacPet mostra o bloco como um card e o usuário confirma antes de lançar; não diga que as tarefas já estão rodando.
        """

    /// Fecho do briefing: onde o agente está e o que entregar.
    static func footer(task: ProjectTask, origin: String, project: String) -> String {
        """


        ---
        Tarefa lançada pelo MacPet a partir da conversa em \(origin) (projeto \(project)). \
        Você está numa git worktree na branch \(task.branch), que saiu de \(task.baseBranch). \
        Ao terminar: rode os testes relevantes, faça commit nesta branch e resuma em poucas linhas o que mudou.
        """
    }
}
