import Foundation

/// Uma tarefa paralela dentro de um projeto: branch própria numa git worktree própria, com chat,
/// alterações e terminal separados. Várias tarefas do mesmo repositório rodam juntas sem uma
/// mexer nos arquivos da outra.
struct ProjectTask: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var branch: String
    /// Branch de onde a tarefa saiu e para onde volta no merge.
    var baseBranch: String
    /// Pasta da worktree.
    var path: String
    var created = Date()
    var lastSessionId: String?
}

/// Operações de git das tarefas. As worktrees ficam em ~/.macpet/worktrees/<projeto>/<tarefa>,
/// fora das pastas de trabalho (assim jest/tsc/eslint do projeto principal não as enxergam).
enum Worktrees {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Preparation {
        var copied: [String] = []
        var linked: [String] = []
    }

    private static var git: String { ShellEnvironment.which("git") ?? "/usr/bin/git" }

    static func folder(for project: Project, slug: String) -> String {
        let projectFolder = "\(Self.slug(project.name))-\(project.id.uuidString.prefix(6).lowercased())"
        return MacPetPaths.support.appendingPathComponent("worktrees/\(projectFolder)/\(slug)").path
    }

    /// "Corrigir preço do fardo" → "corrigir-preco-do-fardo"
    static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR")).lowercased()
        let allowed = folded.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(allowed).split(separator: "-").joined(separator: "-").prefix(48).description
    }

    static func create(in project: Project, name: String, branch: String, base: String) async throws -> (ProjectTask, Preparation) {
        let slug = Self.slug(name.isEmpty ? branch : name)
        guard !slug.isEmpty else { throw Failure(message: "Dê um nome para a tarefa.") }
        var path = folder(for: project, slug: slug)
        var suffix = 2
        while FileManager.default.fileExists(atPath: path) {
            path = folder(for: project, slug: "\(slug)-\(suffix)")
            suffix += 1
        }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        let exists = await Shell.run(git, ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: project.path).ok
        let args = exists ? ["worktree", "add", path, branch] : ["worktree", "add", "-b", branch, path, base]
        let result = await Shell.run(git, args, in: project.path)
        guard result.ok else { throw Failure(message: clean(result)) }

        let preparation = await prepareEnvironment(from: project.path, to: path)
        let task = ProjectTask(name: name.isEmpty ? branch : name, branch: branch, baseBranch: base, path: path)
        return (task, preparation)
    }

    /// O que o git ignora e o projeto precisa para rodar: `.env*` e configurações locais do Claude são
    /// copiados; `node_modules` viram links para os do projeto principal (sem reinstalar nada).
    static func prepareEnvironment(from main: String, to worktree: String) async -> Preparation {
        let ignored = await Shell.run(git, ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory"], in: main)
        var preparation = Preparation()
        let fm = FileManager.default
        for entry in ignored.stdout.split(separator: "\n").map(String.init) {
            let isFolder = entry.hasSuffix("/")
            let relative = isFolder ? String(entry.dropLast()) : entry
            let source = (main as NSString).appendingPathComponent(relative)
            let target = (worktree as NSString).appendingPathComponent(relative)
            let name = (relative as NSString).lastPathComponent
            guard !fm.fileExists(atPath: target) else { continue }
            try? fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if name == "node_modules" {
                if (try? fm.createSymbolicLink(atPath: target, withDestinationPath: source)) != nil {
                    preparation.linked.append(relative)
                }
            } else if !isFolder, name.hasPrefix(".env") || name == "CLAUDE.local.md" || relative.hasSuffix(".claude/settings.local.json") {
                if (try? fm.copyItem(atPath: source, toPath: target)) != nil { preparation.copied.append(relative) }
            }
        }
        await excludeLinks(preparation.linked, in: worktree)
        return preparation
    }

    /// Um link não é pasta, então `node_modules/` no .gitignore não o ignora e ele apareceria como
    /// arquivo novo. Os caminhos exatos vão para o exclude local do repositório (não versionado).
    private static func excludeLinks(_ links: [String], in worktree: String) async {
        guard !links.isEmpty else { return }
        let commonDir = await Shell.run(git, ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: worktree)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commonDir.isEmpty else { return }
        let exclude = (commonDir as NSString).appendingPathComponent("info/exclude")
        try? FileManager.default.createDirectory(atPath: (exclude as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let current = (try? String(contentsOfFile: exclude, encoding: .utf8)) ?? ""
        let missing = links.map { "/" + $0 }.filter { !current.components(separatedBy: "\n").contains($0) }
        guard !missing.isEmpty else { return }
        let block = (current.isEmpty || current.hasSuffix("\n") ? "" : "\n")
            + "# MacPet: links de node_modules das tarefas\n" + missing.joined(separator: "\n") + "\n"
        if let handle = FileHandle(forWritingAtPath: exclude) {
            handle.seekToEndOfFile()
            handle.write(Data(block.utf8))
            try? handle.close()
        } else {
            try? block.write(toFile: exclude, atomically: true, encoding: .utf8)
        }
    }

    /// Alterações ainda não commitadas na worktree (para avisar antes de remover).
    static func pendingChanges(_ task: ProjectTask) async -> Int {
        let status = await Shell.run(git, ["status", "--porcelain"], in: task.path)
        return status.stdout.split(separator: "\n").count
    }

    /// Commits da tarefa que ainda não estão na branch base.
    static func unmergedCommits(_ task: ProjectTask, in project: Project) async -> Int {
        let count = await Shell.run(git, ["rev-list", "--count", "\(task.baseBranch)..\(task.branch)"], in: project.path)
        return Int(count.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Traz a branch da tarefa para a branch base, na pasta principal do projeto.
    static func merge(_ task: ProjectTask, into project: Project) async throws -> String {
        let current = await Shell.run(git, ["branch", "--show-current"], in: project.path)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == task.baseBranch else {
            throw Failure(message: "A pasta principal de \(project.name) está em \(current.isEmpty ? "outro ponto" : current), não em \(task.baseBranch). Troque para \(task.baseBranch) antes do merge.")
        }
        let dirty = await Shell.run(git, ["status", "--porcelain", "--untracked-files=no"], in: project.path)
        guard dirty.stdout.isEmpty else {
            throw Failure(message: "\(project.name) tem alterações não commitadas em \(task.baseBranch). Faça commit ou guarde-as antes do merge.")
        }
        let result = await Shell.run(git, ["merge", "--no-ff", "--no-edit", task.branch], in: project.path)
        guard result.ok else {
            _ = await Shell.run(git, ["merge", "--abort"], in: project.path)
            throw Failure(message: "O merge deu conflito e foi desfeito. Resolva pela tarefa (traga \(task.baseBranch) para a branch dela) e tente de novo.\n\n\(clean(result))")
        }
        return "\(task.branch) entrou em \(task.baseBranch)."
    }

    static func remove(_ task: ProjectTask, from project: Project, deleteBranch: Bool) async throws {
        let result = await Shell.run(git, ["worktree", "remove", "--force", task.path], in: project.path)
        if !result.ok, FileManager.default.fileExists(atPath: task.path) { throw Failure(message: clean(result)) }
        _ = await Shell.run(git, ["worktree", "prune"], in: project.path)
        if deleteBranch {
            _ = await Shell.run(git, ["branch", "-D", task.branch], in: project.path)
        }
    }

    private static func clean(_ result: CommandResult) -> String {
        (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
