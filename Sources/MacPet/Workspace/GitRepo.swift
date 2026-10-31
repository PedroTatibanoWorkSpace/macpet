import Foundation

struct GitFile: Identifiable, Hashable {
    let path: String
    /// Status no índice (X) e na árvore de trabalho (Y) do `git status --porcelain`.
    let index: Character
    let worktree: Character

    var id: String { path }
    var isUntracked: Bool { index == "?" }
    var hasStaged: Bool { index != " " && index != "?" }
    var hasUnstaged: Bool { worktree != " " || isUntracked }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }

    var badge: String {
        let code = hasStaged ? index : worktree
        switch code {
        case "?": return "N"
        case "A": return "A"
        case "D": return "D"
        case "R": return "R"
        default: return "M"
        }
    }
}

struct GitCommit: Identifiable, Hashable {
    let hash: String
    let subject: String
    let author: String
    let date: Date
    var id: String { hash }
}

/// Operações de git de um projeto, rodando o `git` do sistema.
@MainActor
final class GitRepo: ObservableObject {
    @Published private(set) var isRepo = true
    @Published private(set) var branch: String?
    @Published private(set) var upstream: String?
    @Published private(set) var ahead = 0
    @Published private(set) var behind = 0
    @Published private(set) var files: [GitFile] = []
    @Published private(set) var log: [GitCommit] = []
    @Published private(set) var busy: String?
    @Published var lastError: String?
    @Published var lastInfo: String?

    let path: String
    private let git = ShellEnvironment.which("git") ?? "/usr/bin/git"

    init(path: String) {
        self.path = path
    }

    var staged: [GitFile] { files.filter(\.hasStaged) }
    var unstaged: [GitFile] { files.filter(\.hasUnstaged) }

    func refresh() async {
        let status = await run(["status", "--porcelain=v1", "--branch", "-z", "--untracked-files=all"])
        guard status.ok else {
            isRepo = false
            return
        }
        isRepo = true
        var parsed: [GitFile] = []
        var entries = status.stdout.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            index += 1
            if entry.hasPrefix("## ") {
                parseBranch(String(entry.dropFirst(3)))
                continue
            }
            guard entry.count > 3 else { continue }
            let x = entry[entry.startIndex]
            let y = entry[entry.index(after: entry.startIndex)]
            let filePath = String(entry.dropFirst(3))
            // Renomeações trazem o caminho antigo na entrada seguinte.
            if x == "R" || x == "C" { index += 1 }
            parsed.append(GitFile(path: filePath, index: x, worktree: y))
        }
        entries = []
        files = parsed.sorted { $0.path < $1.path }

        let logResult = await run(["log", "-15", "--format=%H%x1f%s%x1f%an%x1f%ct"])
        log = logResult.stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4 else { return nil }
            return GitCommit(hash: parts[0], subject: parts[1], author: parts[2],
                             date: Date(timeIntervalSince1970: TimeInterval(parts[3]) ?? 0))
        }
    }

    private func parseBranch(_ line: String) {
        // "main...origin/main [ahead 1, behind 2]" ou "No commits yet on main"
        var head = line
        ahead = 0
        behind = 0
        if let bracket = head.range(of: " [") {
            let info = head[bracket.upperBound...].dropLast()
            for part in info.split(separator: ",") {
                let words = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
                if words.count == 2, let value = Int(words[1]) {
                    if words[0] == "ahead" { ahead = value } else if words[0] == "behind" { behind = value }
                }
            }
            head = String(head[..<bracket.lowerBound])
        }
        let parts = head.components(separatedBy: "...")
        branch = parts.first?.replacingOccurrences(of: "No commits yet on ", with: "")
        upstream = parts.count > 1 ? parts[1] : nil
    }

    // MARK: Diff

    func diff(for file: GitFile, staged: Bool) async -> String {
        if file.isUntracked {
            let url = URL(fileURLWithPath: path).appendingPathComponent(file.path)
            guard let data = try? Data(contentsOf: url), data.count < 512 * 1024 else { return "Arquivo novo (grande ou binário)." }
            guard let text = String(data: data, encoding: .utf8) else { return "Arquivo novo (binário)." }
            return "@@ arquivo novo @@\n" + text.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n")
        }
        let result = await run(["diff", "--no-color"] + (staged ? ["--cached"] : []) + ["--", file.path])
        return result.stdout.isEmpty ? "Sem diferenças." : result.stdout
    }

    /// Diff usado pelas ações de IA: o que está preparado ou, se nada estiver, tudo.
    func diffForAI(limit: Int = 80_000) async -> (diff: String, files: [String], onlyStaged: Bool) {
        let onlyStaged = !staged.isEmpty
        var diff = (await run(["diff", "--no-color"] + (onlyStaged ? ["--cached"] : ["HEAD"]))).stdout
        var names = (onlyStaged ? staged : files).map(\.path)
        if !onlyStaged {
            // Arquivos novos não aparecem no git diff; inclui o conteúdo deles.
            for file in files where file.isUntracked {
                diff += "\n" + (await self.diff(for: file, staged: false)).replacingOccurrences(of: "@@ arquivo novo @@", with: "diff --git a/\(file.path) b/\(file.path)\nnew file")
            }
        }
        names = Array(Set(names)).sorted()
        if diff.count > limit { diff = String(diff.prefix(limit)) + "\n[… diff truncado …]" }
        return (diff, names, onlyStaged)
    }

    // MARK: Ações

    func stage(_ paths: [String]) async { await perform("Preparando", ["add", "--"] + paths) }
    func unstage(_ paths: [String]) async { await perform("Removendo do commit", ["restore", "--staged", "--"] + paths) }
    func stageAll() async { await perform("Preparando tudo", ["add", "-A"]) }

    func discard(_ file: GitFile) async {
        if file.isUntracked {
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: path).appendingPathComponent(file.path), resultingItemURL: nil)
            await refresh()
        } else {
            await perform("Descartando", ["restore", "--source=HEAD", "--staged", "--worktree", "--", file.path])
        }
    }

    @discardableResult
    func commit(message: String, paths: [String]? = nil) async -> Bool {
        if let paths {
            // Commit de um grupo: prepara só esses arquivos.
            _ = await run(["reset", "-q"])
            _ = await run(["add", "-A", "--"] + paths)
        }
        let ok = await perform("Commitando", ["commit", "-m", message])
        if ok { lastInfo = "Commit feito: \(message.split(separator: "\n").first ?? "")" }
        return ok
    }

    func createBranch(_ name: String) async { await perform("Criando branch", ["switch", "-c", name]) }

    /// Branches locais (mais recentes primeiro) e remotas que ainda não existem localmente.
    func branches() async -> (local: [String], remote: [String]) {
        func refs(_ prefix: String) async -> [String] {
            let result = await run(["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", prefix])
            return result.stdout.split(separator: "\n").map(String.init)
        }
        let local = await refs("refs/heads")
        let remote = await refs("refs/remotes").filter { !$0.hasSuffix("/HEAD") && $0.contains("/") }
            .filter { name in !local.contains(String(name.split(separator: "/", maxSplits: 1)[1])) }
        return (local, remote)
    }

    /// Troca de branch. Remotas ("origin/x") viram uma branch local "x" que acompanha a remota.
    /// Com `stash`, guarda antes as alterações (inclusive arquivos novos) que impediriam a troca.
    @discardableResult
    func switchBranch(_ name: String, stash: Bool = false) async -> Bool {
        if stash {
            let stashed = await run(["stash", "push", "--include-untracked", "-m", "MacPet: antes de trocar para \(name)"])
            guard stashed.ok else {
                lastError = stashed.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return false
            }
        }
        let isLocal = await branches().local.contains(name)
        let local = !isLocal && name.contains("/") ? String(name.split(separator: "/", maxSplits: 1)[1]) : name
        let ok = await perform("Trocando de branch", ["switch", local])
        if ok { lastInfo = stash ? "Agora em \(local). Suas alterações ficaram guardadas no stash." : "Agora em \(local)." }
        return ok
    }

    func fetch() async { await perform("Buscando branches", ["fetch", "--prune"]) }
    func pull() async { await perform("Pull", ["pull", "--ff-only"]) }

    func push() async {
        let ok = await perform("Push", upstream == nil ? ["push", "-u", "origin", "HEAD"] : ["push"])
        if ok { lastInfo = "Push feito em \(branch ?? "")." }
    }

    /// Commits deste branch que ainda não estão na branch principal (para o PR).
    func commitsForPR() async -> (base: String, log: String, stat: String) {
        let base = await defaultBranch()
        let log = await run(["log", "--format=- %s%n%b", "origin/\(base)..HEAD"])
        let stat = await run(["diff", "--stat", "origin/\(base)...HEAD"])
        return (base, log.stdout, stat.stdout)
    }

    /// O que entra no PR: commits desde a base (remota, se houver) e o que ainda não foi commitado.
    struct ReviewTarget {
        let branch: String
        let base: String
        /// "origin/main...HEAD" (ou "main...HEAD" sem remoto).
        let range: String
        let head: String
        let log: String
        let stat: String
        let uncommitted: String
        /// Diff completo: commits da branch e, em seguida, o que ainda não foi commitado.
        let diff: String
    }

    func reviewTarget() async -> ReviewTarget? {
        let name = await defaultBranch()
        var baseRef = "origin/\(name)"
        if !(await run(["rev-parse", "--verify", "--quiet", baseRef]).ok) {
            guard await run(["rev-parse", "--verify", "--quiet", name]).ok else { return nil }
            baseRef = name
        }
        let baseRefFinal = baseRef
        let range = "\(baseRefFinal)...HEAD"
        async let head = run(["rev-parse", "--short", "HEAD"])
        async let log = run(["log", "--format=- %s", "\(baseRefFinal)..HEAD"])
        async let stat = run(["diff", "--stat", range])
        async let uncommitted = run(["diff", "--stat", "HEAD"])
        // Sem diff externo nem textconv: só o que mudou, sem rodar programas configurados para o diff.
        async let committedDiff = run(["diff", "--no-ext-diff", "--no-textconv", "--no-color", range])
        async let uncommittedDiff = run(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "HEAD"])
        let pending = await uncommittedDiff.stdout
        return await ReviewTarget(branch: branch ?? "HEAD", base: baseRefFinal, range: range,
                                  head: head.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                                  log: log.stdout, stat: stat.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                                  uncommitted: uncommitted.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                                  diff: committedDiff.stdout
                                      + (pending.isEmpty ? "" : "\n# Alterações ainda não commitadas (git diff HEAD)\n\n" + pending))
    }

    /// Diff de um arquivo em tudo o que entra no PR (base até o que está no disco agora).
    func reviewDiff(file: String, base: String) async -> String {
        let mergeBase = await run(["merge-base", base, "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return await run(["diff", mergeBase.isEmpty ? base : mergeBase, "--", file]).stdout
    }

    func currentHead() async -> String {
        await run(["rev-parse", "--short", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func defaultBranch() async -> String {
        let head = await run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
        let name = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "origin/", with: "")
        return name.isEmpty ? "main" : name
    }

    func recentSubjects() -> [String] { log.prefix(12).map(\.subject) }

    @discardableResult
    private func perform(_ label: String, _ args: [String]) async -> Bool {
        busy = label
        defer { busy = nil }
        let result = await run(args)
        if !result.ok {
            lastError = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            lastError = nil
        }
        await refresh()
        return result.ok
    }

    private func run(_ args: [String]) async -> CommandResult {
        await Shell.run(git, args, in: path)
    }
}
