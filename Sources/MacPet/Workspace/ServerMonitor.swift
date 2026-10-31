import Foundation

/// Árvore de processos (via `ps`): para achar o que cada terminal está rodando.
enum ProcessTree {
    /// pai → filhos, e os processos zumbis (já mortos, esperando o pai).
    static func snapshot() -> (children: [pid_t: [pid_t]], zombies: Set<pid_t>) {
        var children: [pid_t: [pid_t]] = [:]
        var zombies = Set<pid_t>()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-A", "-o", "pid=,ppid=,stat="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return ([:], []) }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]) else { continue }
            children[parent, default: []].append(pid)
            if fields[2].hasPrefix("Z") { zombies.insert(pid) }
        }
        return (children, zombies)
    }

    static func descendants(of root: pid_t, in tree: (children: [pid_t: [pid_t]], zombies: Set<pid_t>)? = nil) -> [pid_t] {
        let tree = tree ?? snapshot()
        var stack = tree.children[root] ?? [], found: [pid_t] = []
        while let pid = stack.popLast() {
            guard !tree.zombies.contains(pid) else { continue }
            found.append(pid)
            stack += tree.children[pid] ?? []
        }
        return found
    }
}

/// Servidor de um terminal, para a lista geral (popover do corvo).
struct ServerEntry: Identifiable, Equatable {
    let id: UUID
    let projectId: UUID
    let projectName: String
    let title: String
    let status: ServerStatus
}

/// Olha os terminais de todos os projetos a cada 3 s: o que cada um está rodando e em que portas escuta.
/// Um `ps` e um `lsof` para tudo, fora da thread principal. Servidor que estava no ar e morreu sem Ctrl+C
/// "caiu": avisa e, se o comando pede, roda de novo (no máximo 3 vezes em 2 minutos).
@MainActor
final class ServerMonitor: ObservableObject {
    @Published private(set) var entries: [ServerEntry] = []

    private let projects: ProjectStore
    private let notifier: Notifier
    private var timer: Timer?
    private var polling = false

    init(projects: ProjectStore, notifier: Notifier) {
        self.projects = projects
        self.notifier = notifier
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let groups = projects.openTerminalGroups
        let shells = groups.flatMap { entry in entry.group.tabs.map { ($0.id, $0.shellPid) } }.filter { $0.1 > 0 }
        guard !polling, !shells.isEmpty else {
            if shells.isEmpty, !entries.isEmpty { entries = [] }
            return
        }
        polling = true
        Task.detached(priority: .utility) {
            let observed = Self.observe(shells: shells)
            await MainActor.run {
                self.polling = false
                self.apply(observed, groups: groups)
            }
        }
    }

    private func apply(_ observed: [UUID: (busy: Bool, ports: [Int])], groups: [(projectId: UUID, group: TerminalGroup)]) {
        var all: [ServerEntry] = []
        for (projectId, group) in groups {
            for tab in group.tabs {
                guard let now = observed[tab.id] else { continue }
                let previous = group.status[tab.id] ?? .idle
                let next = transition(from: previous, busy: now.busy, ports: now.ports, tab: tab, group: group)
                if next != previous { group.status[tab.id] = next }
                if tab.command != nil || !next.ports.isEmpty || next.isCrashed {
                    all.append(ServerEntry(id: tab.id, projectId: projectId, projectName: group.projectName, title: tab.title, status: next))
                }
            }
        }
        if all != entries { entries = all }
    }

    private func transition(from previous: ServerStatus, busy: Bool, ports: [Int], tab: TerminalTab, group: TerminalGroup) -> ServerStatus {
        // Rodando: com porta, no ar; sem porta, subindo (ou reiniciando, como o nodemon faz).
        if busy { return ports.isEmpty ? .starting : .up(ports) }
        switch previous {
        case .up:
            // Saiu do ar. Com Ctrl+C há pouco foi você; senão, caiu.
            if let interrupt = tab.lastInterrupt, Date().timeIntervalSince(interrupt) < 6 { return .stopped }
            crashed(tab, group: group)
            return .crashed(Date())
        case .starting:
            return tab.command == nil ? .idle : .stopped
        default:
            return previous
        }
    }

    private func crashed(_ tab: TerminalTab, group: TerminalGroup) {
        tab.restarts.removeAll { Date().timeIntervalSince($0) > 120 }
        let restarting = tab.autoRestart && tab.command != nil && tab.restarts.count < 3
        notifier.post(id: "server-\(tab.id)", title: "\(tab.title) caiu",
                      subtitle: group.projectName,
                      body: restarting ? "Reiniciando sozinho (\(tab.restarts.count + 1)ª vez)."
                          : tab.autoRestart ? "Caiu 3 vezes em 2 minutos: parei de reiniciar. Veja o terminal."
                          : "Abra o terminal do projeto para ver o erro e reiniciar.",
                      projectPath: group.directory, cwd: group.directory, mood: .hot)
        if restarting {
            tab.restarts.append(Date())
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { group.restart(tab) }
        }
    }

    // MARK: Processos e portas

    /// Para cada shell: se tem algum comando rodando (processo filho vivo) e as portas TCP que os filhos escutam.
    private nonisolated static func observe(shells: [(UUID, pid_t)]) -> [UUID: (busy: Bool, ports: [Int])] {
        let tree = ProcessTree.snapshot()
        var descendants: [UUID: [pid_t]] = [:]
        for (id, shell) in shells { descendants[id] = ProcessTree.descendants(of: shell, in: tree) }
        let pids = descendants.values.flatMap { $0 }
        var portsByPid: [pid_t: Set<Int>] = [:]
        if !pids.isEmpty {
            // -F pn: linhas "p<pid>" e "n<endereço>:<porta>".
            var current: pid_t = 0
            for line in run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", pids.map(String.init).joined(separator: ","), "-Fpn"])
                .split(separator: "\n") {
                if line.hasPrefix("p") { current = pid_t(line.dropFirst()) ?? 0 }
                if line.hasPrefix("n"), let port = Int(line.split(separator: ":").last ?? "") { portsByPid[current, default: []].insert(port) }
            }
        }
        return descendants.mapValues { pids in
            (busy: !pids.isEmpty, ports: Array(Set(pids.flatMap { portsByPid[$0] ?? [] })).sorted())
        }
    }

    private nonisolated static func run(_ executable: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
