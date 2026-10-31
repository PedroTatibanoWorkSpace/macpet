import AppKit
import SwiftTerm
import SwiftUI

/// Estado de um terminal visto como servidor (ver `ServerMonitor`).
enum ServerStatus: Equatable {
    /// Só o shell, esperando comando.
    case idle
    /// Rodando um comando, ainda sem porta aberta.
    case starting
    /// Rodando com portas abertas.
    case up([Int])
    /// Você parou (Ctrl+C).
    case stopped
    /// Estava no ar e morreu sozinho.
    case crashed(Date)

    var ports: [Int] {
        if case .up(let ports) = self { return ports }
        return []
    }

    var isCrashed: Bool {
        if case .crashed = self { return true }
        return false
    }
}

/// Terminal que avisa quando você aperta Ctrl+C (para não confundir "parei" com "caiu").
final class WatchedTerminalView: LocalProcessTerminalView {
    var onInterrupt: (() -> Void)?

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if data.contains(0x03) { onInterrupt?() }
        super.send(source: source, data: data)
    }
}

/// Uma aba de terminal (shell de login no diretório do projeto).
final class TerminalTab: Identifiable {
    let id = UUID()
    var title: String
    let view: WatchedTerminalView
    /// Comando salvo que esta aba roda (os servidores); nil num terminal livre.
    let command: String?
    var autoRestart: Bool
    private(set) var lastInterrupt: Date?
    /// Reinícios automáticos recentes (trava contra um servidor que cai em loop).
    var restarts: [Date] = []

    init(title: String, directory: String, command: String?, autoRestart: Bool = false) {
        self.title = title
        self.command = command
        self.autoRestart = autoRestart
        view = WatchedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        // Cores fixas do tema escuro: sem isso, ao ser recolocado na tela o terminal às vezes pega o fundo branco do sistema.
        view.nativeBackgroundColor = NSColor(srgbRed: 0x12 / 255.0, green: 0x13 / 255.0, blue: 0x19 / 255.0, alpha: 1)
        view.nativeForegroundColor = NSColor(srgbRed: 0xEC / 255.0, green: 0xEB / 255.0, blue: 0xF3 / 255.0, alpha: 1)
        let environment = ShellEnvironment.variables.map { "\($0.key)=\($0.value)" }
        let shell = ShellEnvironment.shell
        view.startProcess(executable: shell, args: ["-l"], environment: environment,
                          execName: "-" + URL(fileURLWithPath: shell).lastPathComponent,
                          currentDirectory: directory)
        view.onInterrupt = { [weak self] in self?.lastInterrupt = Date() }
        if let command {
            view.send(txt: command + "\r")
        }
    }

    var isRunning: Bool { view.process?.running ?? false }
    var shellPid: pid_t { view.process?.shellPid ?? 0 }

    /// Roda o comando de novo no mesmo shell (o histórico do terminal continua).
    func restart() {
        guard let command else { return }
        view.send(txt: command + "\r")
    }

    /// Fecha o shell e o que ele estiver rodando: o zsh interativo ignora SIGTERM, e um servidor deixado
    /// para trás ficaria órfão segurando a porta.
    func close() {
        let shell = shellPid
        if shell > 0 {
            for pid in ProcessTree.descendants(of: shell) { kill(pid, SIGTERM) }
            kill(shell, SIGHUP)
        }
        if isRunning { view.terminate() }
    }
}

/// Terminais de um projeto. Ficam vivos ao trocar de projeto (servidores continuam rodando).
@MainActor
final class TerminalGroup: ObservableObject {
    @Published private(set) var tabs: [TerminalTab] = []
    @Published var selectedId: UUID?
    /// Estado de cada aba como servidor, atualizado pelo `ServerMonitor`.
    @Published var status: [UUID: ServerStatus] = [:]

    let directory: String
    let projectName: String

    init(directory: String, projectName: String) {
        self.directory = directory
        self.projectName = projectName
    }

    var selected: TerminalTab? { tabs.first { $0.id == selectedId } }

    func open(title: String = "zsh", command: String? = nil, autoRestart: Bool = false) {
        let tab = TerminalTab(title: title, directory: directory, command: command, autoRestart: autoRestart)
        tabs.append(tab)
        status[tab.id] = command == nil ? .idle : .starting
        selectedId = tab.id
    }

    func close(_ tab: TerminalTab) {
        tab.close()
        tabs.removeAll { $0.id == tab.id }
        status[tab.id] = nil
        if selectedId == tab.id { selectedId = tabs.last?.id }
    }

    func restart(_ tab: TerminalTab) {
        tab.restart()
        status[tab.id] = .starting
    }

    func closeAll() {
        tabs.forEach { $0.close() }
        tabs = []
        status = [:]
        selectedId = nil
    }
}

/// Mostra a NSView do terminal selecionado dentro do SwiftUI.
struct TerminalHost: NSViewRepresentable {
    let tab: TerminalTab

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if tab.view.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        tab.view.removeFromSuperview()
        tab.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tab.view)
        NSLayoutConstraint.activate([
            tab.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tab.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tab.view.topAnchor.constraint(equalTo: container.topAnchor),
            tab.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DispatchQueue.main.async { container.window?.makeFirstResponder(tab.view) }
    }
}
