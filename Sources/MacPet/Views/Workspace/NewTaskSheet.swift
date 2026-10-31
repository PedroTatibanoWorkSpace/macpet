import SwiftUI

/// Cria uma tarefa paralela: worktree com branch própria e, opcionalmente, já manda o primeiro pedido ao Claude.
struct NewTaskSheet: View {
    let project: Project
    @EnvironmentObject private var store: ProjectStore
    @State private var name = ""
    @State private var branch = ""
    @State private var branchEdited = false
    @State private var base = ""
    @State private var bases: [String] = []
    @State private var prompt = ""
    @State private var creating = false
    @State private var error: String?
    @State private var translating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProjectMonogram(project: project, size: 26)
                Text("Nova tarefa em \(project.name)").font(Theme.display(20))
            }
            Text("Uma cópia de trabalho separada (git worktree) com branch, conversa e terminal próprios. Roda junto com as outras tarefas sem mexer nos mesmos arquivos.")
                .font(.callout).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            field("O que vai ser feito") {
                TextField("Corrigir o preço do fardo", text: $name)
                    .textFieldStyle(.mp)
                    .onChange(of: name) { _, newName in
                        if !branchEdited { branch = newName.isEmpty ? "" : "feat/\(Worktrees.slug(newName))" }
                    }
                    // Branch sempre em inglês: o Haiku traduz o nome depois que você para de digitar.
                    .task(id: name) {
                        guard !branchEdited, name.trimmingCharacters(in: .whitespaces).count > 3 else { return }
                        try? await Task.sleep(for: .milliseconds(900))
                        guard !Task.isCancelled else { return }
                        translating = true
                        defer { translating = false }
                        if let english = try? await CommitAssistant.taskBranch(title: name, in: project.path),
                           !english.isEmpty, !branchEdited, !Task.isCancelled {
                            branch = english
                        }
                    }
            }

            HStack(alignment: .top, spacing: 12) {
                field("Branch") {
                    HStack(spacing: 6) {
                        TextField("feat/my-task", text: Binding(get: { branch }, set: { branch = $0; branchEdited = true }))
                            .textFieldStyle(.mp)
                            .font(Theme.mono(12))
                        if translating {
                            ProgressView().controlSize(.mini).help("Traduzindo para inglês…")
                        }
                    }
                }
                field("A partir de") {
                    MPSelect(icon: "arrow.triangle.branch", title: base.isEmpty ? "—" : base,
                             options: bases.map { .init(value: $0, label: $0) }, selection: $base)
                        .frame(height: 30)
                }
            }

            field("Primeiro pedido para o Claude (opcional)") {
                ZStack(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("Descreva a tarefa e ele começa a trabalhar nela agora, em paralelo.")
                            .foregroundStyle(Theme.textFaint)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $prompt)
                        .scrollContentBackground(.hidden)
                        .frame(height: 90)
                }
                .padding(10)
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.quillStrong))
            }

            if let error {
                Text(error).font(.callout).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if creating {
                    ProgressView().controlSize(.small)
                    Text("Criando a worktree e preparando o ambiente…").font(.callout).foregroundStyle(Theme.textMuted)
                }
                Spacer()
                Button("Cancelar") { mpDismissOverlay() }
                    .keyboardShortcut(.cancelAction)
                Button(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Criar tarefa" : "Criar e começar", action: create)
                    .buttonStyle(.mp(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating || name.trimmingCharacters(in: .whitespaces).isEmpty || branch.isEmpty || base.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(Theme.plumage, in: RoundedRectangle(cornerRadius: Theme.Radius.xl2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xl2, style: .continuous).strokeBorder(Theme.quill))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        .task {
            let repo = store.repo(for: project)
            await repo.refresh()
            bases = await repo.branches().local
            base = repo.branch ?? bases.first ?? "main"
            if !bases.contains(base) { bases.insert(base, at: 0) }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.textMuted)
            content()
        }
    }

    private func create() {
        creating = true
        error = nil
        let firstPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let (workspace, preparation) = try await store.createTask(
                    in: project, name: name.trimmingCharacters(in: .whitespaces),
                    branch: branch.trimmingCharacters(in: .whitespaces), base: base)
                let chat = store.chat(for: workspace)
                var setup = ["Tarefa criada em \(branch), a partir de \(base)."]
                if !preparation.copied.isEmpty { setup.append("Copiei \(preparation.copied.joined(separator: ", ")).") }
                if !preparation.linked.isEmpty {
                    setup.append("node_modules ligados aos do projeto (\(preparation.linked.count)); instalar pacotes aqui mexe nos do projeto também.")
                }
                chat.notice(setup.joined(separator: " "))
                store.hubSelection = .project(workspace.id)
                if !firstPrompt.isEmpty { chat.send(firstPrompt) }
                mpDismissOverlay()
            } catch {
                self.error = error.localizedDescription
                creating = false
            }
        }
    }
}
