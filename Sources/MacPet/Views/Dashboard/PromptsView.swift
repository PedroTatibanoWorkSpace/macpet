import SwiftUI

struct PromptsView: View {
    @EnvironmentObject private var library: PromptLibrary
    @EnvironmentObject private var usage: UsageIndex
    @State private var selection: SavedPrompt.ID?
    @State private var recentProjects: [String] = []

    var body: some View {
        HSplitView {
            MPList {
                ForEach(library.prompts) { prompt in
                    MPListRow(title: prompt.title.isEmpty ? "Sem título" : prompt.title,
                              subtitle: prompt.text.isEmpty ? nil : prompt.text, selected: selection == prompt.id)
                        .onTapGesture { selection = prompt.id }
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)

            Group {
                if let index = library.prompts.firstIndex(where: { $0.id == selection }) {
                    PromptEditor(prompt: $library.prompts[index], recentProjects: recentProjects) {
                        library.prompts.remove(at: index)
                        selection = library.prompts.first?.id
                    }
                } else {
                    MPEmptyState(title: "Selecione ou crie um prompt", message: "Prompts que você repete viram um clique.") {
                        MPEmptyIcon(systemName: "text.badge.star")
                    }
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Prompts")
        .toolbar {
            Button {
                let prompt = SavedPrompt(title: "Novo prompt", text: "")
                library.prompts.insert(prompt, at: 0)
                selection = prompt.id
            } label: {
                Label("Novo prompt", systemImage: "plus")
            }
        }
        .onAppear {
            if selection == nil { selection = library.prompts.first?.id }
            usage.read({ $0.recentProjects() }) { recentProjects = $0 }
        }
    }
}

private struct PromptEditor: View {
    @Binding var prompt: SavedPrompt
    let recentProjects: [String]
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Título", text: $prompt.title)
                .textFieldStyle(.plain)
                .font(Theme.display(22))

            MPTextArea(text: $prompt.text, placeholder: "O que o Claude deve fazer", height: 260)

            HStack(spacing: 8) {
                MPSectionLabel("Projeto")
                MPSelect(icon: "folder", title: prompt.project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Perguntar na hora",
                         options: [.init(value: nil, label: "Perguntar na hora")]
                            + projectOptions.map { .init(value: Optional($0), label: URL(fileURLWithPath: $0).lastPathComponent, detail: $0) },
                         selection: $prompt.project)
                Button("Outra pasta…") {
                    if let folder = FolderPicker.choose() { prompt.project = folder }
                }
                .buttonStyle(.mp(.ghost, size: .sm))
            }

            HStack {
                Button(action: onDelete) {
                    Label("Excluir", systemImage: "trash")
                }
                .buttonStyle(.mp(.danger))
                Spacer()
                Button {
                    guard let folder = prompt.project ?? FolderPicker.choose() else { return }
                    ClaudeLauncher.run(prompt: prompt.text, in: folder)
                } label: {
                    Label("Executar no terminal", systemImage: "play.fill")
                }
                .buttonStyle(.mp(.primary))
                .disabled(prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    /// Projetos recentes + o projeto escolhido, mesmo que não esteja entre os recentes.
    private var projectOptions: [String] {
        var options = recentProjects
        if let project = prompt.project, !options.contains(project) { options.insert(project, at: 0) }
        return options
    }
}
