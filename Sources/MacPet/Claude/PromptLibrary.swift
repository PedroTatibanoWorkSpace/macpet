import Foundation

struct SavedPrompt: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var text: String
    /// Pasta padrão onde rodar; nil = perguntar.
    var project: String?
}

/// Prompts reutilizáveis, salvos em ~/Library/Application Support/MacPet/prompts.json.
@MainActor
final class PromptLibrary: ObservableObject {
    @Published var prompts: [SavedPrompt] = [] {
        didSet { save() }
    }

    private let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacPet/prompts.json")

    init() {
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode([SavedPrompt].self, from: data) {
            prompts = stored
        } else {
            prompts = Self.starters
        }
    }

    /// Exemplos para a biblioteca não começar vazia.
    private static let starters = [
        SavedPrompt(title: "Revisar mudanças", text: "Revise as mudanças não commitadas deste repositório procurando bugs e problemas de segurança. Liste só o que for relevante, do mais grave para o menos grave."),
        SavedPrompt(title: "Explicar o projeto", text: "Explique a arquitetura deste projeto: módulos principais, fluxo de dados e onde ficam as regras de negócio."),
        SavedPrompt(title: "Escrever testes", text: "Identifique as partes mais críticas deste código que estão sem testes e escreva testes para elas, seguindo o padrão de testes já usado no projeto."),
    ]

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(prompts) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
