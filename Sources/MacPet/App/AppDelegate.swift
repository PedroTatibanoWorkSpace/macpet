import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var env: AppEnvironment!
    private var statusBar: StatusBarController!
    private var petController: PetController!
    private var desktopPet: DesktopPet!
    private var cleaningItem: CleaningStatusItem!
    private var eventServer: ClaudeEventServer?
    private var settingsWindow: NSWindow?
    private var dashboardWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    /// Links macpet:// que abriram o app: chegam antes de applicationDidFinishLaunching, com `env` ainda nil.
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Escrever num claude que acabou de morrer não pode derrubar o app (vira erro de escrita).
        signal(SIGPIPE, SIG_IGN)
        env = AppEnvironment()
        MPOverlayPresenter.shared.environment = { [unowned env] view in AnyView(env!.inject(view)) }
        env.openSettings = { [weak self] in self?.showSettings() }
        env.openDashboard = { [weak self] in self?.showDashboard() }
        statusBar = StatusBarController(env: env)
        petController = PetController(env: env)
        desktopPet = DesktopPet(env: env)
        env.celebratePet = { [weak self] in self?.desktopPet.celebrate() }
        cleaningItem = CleaningStatusItem(cleaning: env.cleaning)

        env.notifier.setUp()
        env.notifier.onOpenSession = { [weak self] id in self?.env.claude.open(id) }
        env.notifier.onOpenProject = { [weak self] path in self?.openProject(path) }
        env.notifier.soundForPath = { [weak self] path in
            self?.env.projects.workspace(atPath: path)?.sound
        }
        env.claude.openInApp = { [weak self] path in self?.openProject(path) }
        env.projects.onSessionState = { [weak self] id, cwd, state in
            self?.env.claude.setExternalState(id, cwd: cwd, state: state)
        }
        env.projects.onAttention = { [weak self] project, message in
            guard let self else { return }
            // Se você já está olhando o projeto no painel, não precisa de notificação.
            let looking = NSApp.isActive && self.dashboardWindow?.isKeyWindow == true
                && self.env.projects.hubSelection == .project(project.id)
            if !looking {
                let owner = project.parentId.flatMap(self.env.projects.workspace(id:)) ?? project
                self.env.notifier.post(id: "chat-\(project.id)", title: owner.name,
                                       subtitle: project.parentId == nil ? "Esperando sua permissão" : "\(project.name) · esperando sua permissão",
                                       body: message, projectPath: project.path, cwd: project.path, mood: .waiting)
                self.desktopPet.say(Speech(kind: .waiting, project: owner.name, color: ProjectColor.for(owner).color,
                                           text: "Posso? \(message)") { [weak self] in self?.openProject(project.path) })
            }
        }
        // O corvo da tela fala quando uma sessão termina ou pede algo (a não ser que você já esteja olhando).
        env.claude.onSpeech = { [weak self] session, kind, text in
            guard let self else { return }
            // No foco, "terminou" espera a pausa (a notificação fica guardada no FocusTimer).
            if kind == .finished, self.env.focus.isFocusing, self.env.settings.focusHoldNotifications { return }
            let workspace = self.env.projects.workspace(atPath: session.cwd)
            if let workspace, NSApp.isActive, self.dashboardWindow?.isKeyWindow == true,
               self.env.projects.hubSelection == .project(workspace.id) { return }
            let owner = workspace.flatMap { $0.parentId.flatMap(self.env.projects.workspace(id:)) ?? $0 }
            self.desktopPet.say(Speech(kind: kind, project: self.env.claude.displayName?(session.cwd) ?? session.projectName,
                                       color: owner.map { ProjectColor.for($0).color } ?? Theme.sheen, text: text) { [weak self] in
                // Conversa de um chat do painel: abre direto nele. Do terminal: volta para a aba do terminal.
                guard let self else { return }
                if let workspace = self.env.projects.workspace(forSession: session.id) {
                    self.openWorkspace(workspace)
                } else {
                    self.env.claude.open(session.id)
                }
            })
        }
        // "loja › Corrigir preço do frete" para tarefas; o nome do projeto para o resto.
        env.claude.displayName = { [weak self] cwd in
            guard let self, let workspace = self.env.projects.workspace(atPath: cwd) else { return nil }
            guard workspace.isTask, let owner = workspace.parentId.flatMap(self.env.projects.workspace(id:)) else {
                return (workspace.parentId.flatMap(self.env.projects.workspace(id:)) ?? workspace).name
            }
            return "\(owner.name) › \(workspace.name)"
        }
        env.projects.onRateLimits = { [weak self] info in self?.env.limits.update(fromRateLimitEvent: info) }
        env.projects.attachRunningChats()
        NSApp.mainMenu = makeMainMenu()
        ModelCatalog.shared.refresh()
        env.peak.start()
        env.awake.start()
        env.servers.start()
        // Modo foco: segura notificações, mantém a tela ligada e o corvo reage a cada fase.
        env.notifier.hold = { [weak self] id, title, body in self?.env.focus.shouldHold(id: id, title: title, body: body) ?? false }
        env.focus.onPhaseChange = { [weak self] previous, next, held in
            guard let self else { return }
            self.env.awake.focusHold = next == .focus && self.env.settings.focusKeepAwake
            self.desktopPet.focusChanged(from: previous, to: next, held: held)
        }
        env.awake.focusHold = env.focus.isFocusing && env.settings.focusKeepAwake
        // Limites do plano pelo /usage (local, sem custo): agora e a cada 10 minutos.
        env.limits.refresh()
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.env.limits.refresh(ifOlderThan: 300) }
        }
        env.hooks.linkBinary()
        // Quem já tinha os hooks da v0.1 ganha a statusLine (limites do plano) automaticamente,
        // a menos que já use outra statusLine.
        if env.hooks.installed && !env.hooks.statusLineInstalled && !env.hooks.statusLineTaken {
            env.hooks.install()
        }
        // Primeira indexação dos transcripts pode levar ~1 min; começa em segundo plano.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.env.usage.refresh() }

        let claude = env.claude
        let limits = env.limits
        let usage = env.usage
        eventServer = ClaudeEventServer { event in
            MainActor.assumeIsolated {
                if event["hook_event_name"] as? String == "StatusLine" {
                    limits.update(fromStatusLine: event)
                } else if event["hook_event_name"] as? String == "Stop" {
                    usage.refreshSoon()
                }
                claude.handle(event)
            }
        }
        eventServer?.start()

        env.monitor.onSample { [weak self] snapshot in
            guard let self else { return }
            self.env.alerts.evaluate(snapshot)
            self.statusBar.refresh()
        }

        rebuildMenuBar()
        env.monitor.start(interval: env.settings.updateInterval)

        let settings = env.settings
        settings.$modules.dropFirst().removeDuplicates()
            .combineLatest(settings.$petEnabled.removeDuplicates(), settings.$cleaningButtonEnabled.removeDuplicates())
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenuBar() }
            .store(in: &cancellables)
        // Corvo na tela: mostra/oculta conforme a preferência (o menu dele e o popover da barra mudam isto).
        settings.$desktopPetEnabled.removeDuplicates()
            .sink { [weak self] enabled in
                DispatchQueue.main.async { if enabled { self?.desktopPet.install() } else { self?.desktopPet.remove() } }
            }
            .store(in: &cancellables)
        settings.$updateInterval.dropFirst().removeDuplicates()
            .sink { [weak self] interval in self?.env.monitor.start(interval: interval) }
            .store(in: &cancellables)

        if !pendingURLs.isEmpty {
            let urls = pendingURLs
            pendingURLs = []
            application(NSApp, open: urls)
        }
    }

    /// Atalhos por URL: macpet://limpeza, macpet://preferencias, macpet://awake?minutes=30 (ou off=1)
    /// Qualquer página ou app pode abrir um link macpet://, então os atalhos de depuração (que rodam o Claude ou
    /// um servidor numa pasta qualquer) só funcionam com `defaults write <identificador do app> debug.urls -bool YES`.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard env != nil else {
            pendingURLs += urls
            return
        }
        let debug = UserDefaults.standard.bool(forKey: "debug.urls")
        for url in urls where url.scheme == "macpet" {
            switch url.host {
            case "limpeza", "cleaning": env.cleaning.showPanel()
            case "preferencias", "settings": showSettings()
            case "claude", "dashboard", "hub": showDashboard()
            case "awake": keepAwake(url, debug: debug)
            case "pet": petAction(url, debug: debug)
            case "snapshot" where debug: snapshot(url)
            case "scrolltest" where debug: scrollTest(url)
            case "bgtest" where debug: backgroundTest(url)
            case "reviewtest" where debug: reviewTest(url)
            case "servertest" where debug: serverTest(url)
            case "dialogtest" where debug: dialogTest(url)
            default: break
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        env.projects.stopAll()
        desktopPet.remove()
        env.cleaning.deactivate()
        eventServer?.stop()
    }

    /// O macOS insere cada item novo à esquerda dos existentes. Criamos ✨ e o pet primeiro
    /// para ficarem na ponta direita, longe do notch, que esconde os itens mais à esquerda.
    private func rebuildMenuBar() {
        statusBar.removeAll()
        petController.remove()
        cleaningItem.remove()
        if env.settings.cleaningButtonEnabled {
            cleaningItem.install()
        }
        if env.settings.petEnabled {
            petController.install()
        }
        statusBar.build(modules: env.settings.modules)
    }

    /// Abre o painel no projeto, já na aba Chat (balão do corvo, notificações).
    private func openProject(_ path: String) {
        guard let workspace = env.projects.workspace(atPath: path) else { return showDashboard() }
        openWorkspace(workspace)
    }

    /// Pelo id (e não pela pasta): uma conversa fixada usa a mesma pasta do projeto.
    private func openWorkspace(_ workspace: Project) {
        showDashboard()
        env.projects.select(workspace)
        env.projects.tabRequest = .chat
    }

    private func showDashboard() {
        if dashboardWindow == nil {
            let hosting = NSHostingController(rootView: env.inject(DashboardView().mpDesignSystem()))
            let window = NSWindow(contentViewController: hosting)
            window.title = "MacPet"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 1100, height: 720))
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("macpet.dashboard")
            window.center()
            window.delegate = self
            dashboardWindow = window
        }
        env.usage.refresh()
        // Com o painel aberto o MacPet vira um app comum: aparece no Dock e no ⌘Tab.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        dashboardWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let window = notification.object as? NSWindow
        // Janela fechada é descartada (e recriada ao abrir de novo): fechada mas viva, a interface continuaria
        // animando por baixo (corvo trabalhando, pontinhos de carregamento) e gastando CPU à toa.
        if window === settingsWindow {
            DispatchQueue.main.async { [weak self] in self?.settingsWindow = nil }
        }
        guard window === dashboardWindow else { return }
        DispatchQueue.main.async { [weak self] in self?.dashboardWindow = nil }
        // Sem o painel, volta a ser só a barra de menus (sai do Dock e do ⌘Tab).
        NSApp.setActivationPolicy(.accessory)
    }

    /// Clique no ícone do Dock com o painel minimizado ou escondido.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showDashboard() }
        return true
    }

    /// Depuração visual: macpet://snapshot?project=loja&tab=chat (ou section=overview) navega e salva
    /// o painel em ~/.macpet/snapshot.png — o app pode desenhar a própria janela sem permissão de gravação de tela.
    private func snapshot(_ url: URL) {
        let query = Self.query(url)
        if let repoPath = query["repo"], let file = query["file"] {
            let repo = GitRepo(path: repoPath)
            Task {
                await repo.refresh()
                guard let entry = repo.files.first(where: { $0.path == file }) else { return }
                let diff = await repo.diff(for: entry, staged: false)
                self.showPreview(AnyView(UnifiedDiffView(diff: diff)), delay: 3)
            }
            return
        }
        if let view = query["view"] {
            // Horário desligado só para a captura (não liga nada) e removido logo depois.
            let demo = query["demo"] == "1" ? AwakeSchedule(enabled: false) : nil
            if let demo { env.settings.awakeSchedules.append(demo) }
            switch view {
            case "pet": showPreview(AnyView(PetView().padding(20).background(Theme.plumage)), delay: 2)
            case "menu":
                // O menu de modo do chat (com descrições), aberto no alto da prévia.
                showPreview(AnyView(Color.clear), delay: 2)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let window = self?.previewWindow else { return }
                    let anchor = NSRect(x: window.frame.minX + 60, y: window.frame.maxY - 90, width: 140, height: 24)
                    MPOverlayPresenter.shared.showMenu(at: anchor, in: window) {
                        MPMenuPanel(entries: PermissionMode.allCases.map { mode in
                            .item(mode.label, detail: mode.detail, checked: mode == .default) {}
                        }) { MPOverlayPresenter.shared.dismissMenu() }
                    } onDismiss: {}
                }
            default:
                env.settingsTab = ["awake": .awake, "alerts": .alerts, "claude": .claude, "crow": .crow, "focus": .focus][query["tab"] ?? ""] ?? .general
                showPreview(AnyView(SettingsView()), delay: 2)
            }
            if let demo {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.env.settings.awakeSchedules.removeAll { $0.id == demo.id }
                }
            }
            return
        }
        if let transcript = query["preview"] {
            previewChat(transcript: transcript, name: query["name"] ?? "Prévia", delay: Double(query["delay"] ?? "") ?? 2,
                        query: query["appearance"] ?? "dark", keep: query["keep"] == "1")
            return
        }
        showDashboard()
        let workspaces = env.projects.projects.flatMap { project in
            [project] + (project.tasks ?? []).map { env.projects.workspace($0, in: project) }
                + (project.pins ?? []).map { env.projects.workspace($0, in: project) }
        }
        if let name = query["project"], let project = workspaces.first(where: { $0.name == name }) {
            env.projects.hubSelection = .project(project.id)
            if let tab = query["tab"].flatMap(ProjectTab.init(debugName:)) { env.projects.tabRequest = tab }
            if query["newtask"] != nil, let owner = project.parentId.flatMap(env.projects.workspace(id:)) ?? Optional(project) {
                env.projects.newTaskRequest = owner
            }
        } else if let name = query["section"], let section = DashboardSection.allCases.first(where: { "\($0)" == name }) {
            env.projects.hubSelection = .section(section)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (Double(query["delay"] ?? "") ?? 1.5)) { [weak self] in
            if let window = self?.dashboardWindow { Self.capture(window.attachedSheet ?? window) }
        }
    }

    private var previewWindow: NSWindow?

    /// Chat descartável (fora do ProjectStore, sem processo) carregado de um transcript, só para conferir o visual.
    private var previewChatSession: ChatSession?

    private func previewChat(transcript: String, name: String, delay: Double, query: String, keep: Bool = false) {
        let path = (transcript as NSString).deletingLastPathComponent
        let chat = ChatSession(project: Project(path: path, name: name))
        chat.resume(sessionId: UUID().uuidString, transcript: transcript)
        previewChatSession = chat
        showPreview(AnyView(ChatView(chat: chat)), delay: delay, appearance: query, keep: keep)
    }

    /// Janela à parte para conferir uma tela isolada (chat de um transcript, diff de um arquivo).
    private func showPreview(_ content: AnyView, delay: Double, appearance: String = "dark", keep: Bool = false) {
        previewWindow?.close()
        let window = NSWindow(contentViewController: NSHostingController(rootView: env.inject(content.mpDesignSystem()
            .background(Theme.ink).tint(Theme.sheen).frame(width: 900, height: 760))))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.title = "Prévia"
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        previewWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Self.capture(window)
            if !keep {
                window.close()
                self?.previewWindow = nil
            }
        }
    }

    /// Desenha a árvore de camadas da janela (o SwiftUI desenha em camadas; `cacheDisplay` perde boa parte).
    private typealias WindowImageFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private static func capture(_ window: NSWindow) {
        // Imagem da janela pelo servidor de janelas (inclui o que o SwiftUI desenha na GPU).
        // A função saiu do SDK, mas segue no CoreGraphics; um app pode capturar as próprias janelas.
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let create = unsafeBitCast(symbol, to: WindowImageFunction.self)
            // .null = limites da janela; 1<<3 = optionIncludingWindow; 1<<0 = boundsIgnoreFraming
            // Com diálogo ou menu aberto, inclui as janelas do app acima do painel (o diálogo é uma janela à parte).
            let withOverlays = !window.childWindows.isNilOrEmpty
            let bounds = withOverlays ? NSRect(x: window.frame.minX, y: (NSScreen.screens.first?.frame.height ?? 0) - window.frame.maxY,
                                               width: window.frame.width, height: window.frame.height) : .null
            let options: UInt32 = withOverlays ? (1 << 1 | 1 << 3) : 1 << 3
            if let image = create(bounds, options, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: MacPetPaths.support.appendingPathComponent("snapshot.png"))
                return
            }
        }
        guard let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else { return }
        if UserDefaults.standard.string(forKey: "snapshot.method") != "layer",
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: MacPetPaths.support.appendingPathComponent("snapshot.png"))
            return
        }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        if layer.isGeometryFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: MacPetPaths.support.appendingPathComponent("snapshot.png"))
    }

    /// Depuração: macpet://bgtest?dir=<pasta> abre na prévia uma conversa (Haiku) que deixa um comando de 20 s
    /// em segundo plano; `phase=shutdown` simula fechar o MacPet; `phase=snap` captura a prévia.
    private func backgroundTest(_ url: URL) {
        let query = Self.query(url)
        switch query["phase"] {
        case "shutdown": previewChatSession?.shutdown()
        case "snap": if let window = previewWindow { Self.capture(window) }
        default:
            guard let dir = query["dir"] else { return }
            let chat = ChatSession(project: Project(path: dir, name: "bgtest"))
            previewChatSession = chat
            chat.setModel(query["model"] ?? "haiku")
            showPreview(AnyView(ChatView(chat: chat)), delay: 1, keep: true)
            // `prompt`: uma conversa qualquer numa pasta de exemplo (prints do app sem projetos de verdade).
            chat.send(query["prompt"] ?? "Run this exact Bash command with run_in_background set to true: `sleep 20 && echo BG-DONE`. Do not wait for it or check on it; reply 'started' and end your turn. When it finishes, tell me its output in Portuguese.")
            try? "\(chat.project.id.uuidString)".write(toFile: dir + "/project-id", atomically: true, encoding: .utf8)
        }
    }

    /// Corvo na tela: macpet://pet?do=carinho|petisco|sambar|tocar|parar-samba|brincar|voar|dormir|comemorar|mostrar|ocultar (ocultar só em depuração; foto = captura, depuração).
    /// `falar` e `aviso-teste` mostram texto ou notificação como se viessem do Claude: só com `debug.urls`.
    private func petAction(_ url: URL, debug: Bool) {
        let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "do" }?.value
        switch action {
        case "mostrar": env.settings.desktopPetEnabled = true
        // Esconder só pelo menu (ou em depuração): um link de qualquer página não faz o corvo "sumir".
        case "ocultar" where debug: env.settings.desktopPetEnabled = false
        case "carinho": desktopPet.pet()
        case "petisco": desktopPet.feed()
        case "sambar": desktopPet.samba()
        // O jogo pega o teclado: por link, só em depuração (uma página não pode tomar o teclado de você).
        case "tocar" where debug: desktopPet.playSamba()
        case "parar-samba": desktopPet.stopSamba()
        case "tocar-demo" where debug: desktopPet.playSamba(autoplay: true)
        case "brincar": desktopPet.play()
        case "voar": desktopPet.flySomewhere()
        case "dormir": desktopPet.toggleSleep()
        case "comemorar": desktopPet.celebrate()
        case "foco": env.focus.startFocus()
        case "foco-parar": env.focus.stop()
        case "aviso-teste" where debug:
            // `titulo`, `sub` e `texto` trocam o conteúdo (prints e vídeos com dados de exemplo).
            let query = Self.query(url)
            let mood: PetMood = ["espera": .waiting, "quente": .hot][query["humor"] ?? ""] ?? .celebrating
            env.notifier.post(id: "claude-teste-\(UUID().uuidString)-stop", title: query["titulo"] ?? "meu-projeto",
                              subtitle: query["sub"] ?? "Terminou",
                              body: query["texto"] ?? "Teste do modo foco: esta notificação deve esperar a pausa.", mood: mood)
        case "falar" where debug:
            // `tipo` (terminou, espera, foco), `projeto` e `cor` (ProjectColor) para prints com dados de exemplo.
            let query = Self.query(url)
            let kind: Speech.Kind = ["espera": .waiting, "foco": .focus][query["tipo"] ?? ""] ?? .finished
            desktopPet.say(Speech(kind: kind, project: query["projeto"] ?? "meu-projeto",
                                  color: (query["cor"].flatMap(ProjectColor.init(rawValue:)) ?? .teal).color,
                                  text: Speech.headline(query["texto"] ?? "Oi!")) { [weak self] in self?.showDashboard() })
        case "foto": if let window = desktopPet.window { Self.capture(window) }
        case "foto-balao": if let window = desktopPet.bubbleWindow { Self.capture(window) }
        // Sem ação: mostra o corvo. Ação desconhecida (ou só de depuração, sem ela): nada. Antes alternava, e
        // qualquer link escondia o corvo.
        case nil: env.settings.desktopPetEnabled = true
        default: break
        }
    }

    /// Depuração: macpet://dialogtest?step=open|menu|pick|cancel reproduz um menu aberto dentro de um diálogo.
    private func dialogTest(_ url: URL) {
        let presenter = MPOverlayPresenter.shared
        switch URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "step" })?.value {
        case "open":
            showPreview(AnyView(Color.clear), delay: 60, keep: true)
            presenter.showDialog(over: previewWindow) {
                MPDialogCard(title: "Teste", actions: [MPDialogAction(label: "Cancelar")]) { Text("conteúdo") }
            } onDismiss: {}
        case "tarefa":
            // Três ações longas (a remoção de tarefa): os botões precisam caber no cartão.
            showPreview(AnyView(Color.clear), delay: 60, keep: true)
            presenter.showDialog(over: previewWindow) {
                MPDialogCard(title: "Remover a tarefa Módulo de risco e limite de crédito na API?",
                             message: "A tarefa sai da barra e a pasta dela é apagada.", actions: [
                    MPDialogAction(label: "Cancelar"),
                    MPDialogAction(label: "Remover e apagar a branch", variant: .danger),
                    MPDialogAction(label: "Remover e manter a branch", variant: .primary),
                ])
            } onDismiss: {}
        case "menu":
            guard let window = presenter.dialogWindow else { return }
            presenter.showMenu(at: NSRect(x: window.frame.midX, y: window.frame.midY, width: 80, height: 20), in: window) {
                MPMenuPanel(entries: [.item("Funk") {}]) { MPOverlayPresenter.shared.dismissMenu() }
            } onDismiss: {}
        case "pick": presenter.dismissMenu()
        case "cancel": presenter.dismissDialog()
        default:
            previewWindow?.close()
            previewWindow = nil
        }
    }

    /// Depuração: macpet://servertest?dir=<pasta>&phase=start|auto|snap|close abre na prévia o terminal de um
    /// projeto de teste rodando um servidor HTTP na porta 8765.
    private var serverTestProject: Project?

    private func serverTest(_ url: URL) {
        let query = Self.query(url)
        switch query["phase"] {
        case "auto":
            guard let project = serverTestProject, let tab = env.projects.terminalGroup(for: project).tabs.first else { return }
            tab.autoRestart = true
        case "snap":
            if let window = previewWindow { Self.capture(window) }
        case "close":
            if let project = serverTestProject { env.projects.terminalGroup(for: project).closeAll() }
            previewWindow?.close()
            previewWindow = nil
        default:
            guard let dir = query["dir"] else { return }
            let project = Project(path: dir, name: "teste-servidor")
            serverTestProject = project
            let group = env.projects.terminalGroup(for: project)
            group.open(title: "api", command: "python3 -m http.server 8765 --bind 127.0.0.1")
            showPreview(AnyView(TerminalPane(group: group, project: project).frame(width: 900, height: 420)), delay: 1, keep: true)
        }
    }

    /// Depuração: macpet://reviewtest?dir=<repo> abre na prévia a revisão do PR desse repositório e começa a revisar.
    private func reviewTest(_ url: URL) {
        guard let dir = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "dir" })?.value else { return }
        let repo = GitRepo(path: dir)
        let project = Project(path: dir, name: "revisão")
        Task {
            await repo.refresh()
            BranchReview.for(dir).start(repo: repo)
            showPreview(AnyView(BranchReviewView(review: BranchReview.for(dir), repo: repo, project: project,
                                                 onClose: {}, onOpenPR: {})), delay: 1, keep: true)
        }
    }

    /// Parâmetros do link. Repetidos (`?on=1&on=1`) valem pelo primeiro: `uniqueKeysWithValues` derrubava o app.
    private static func query(_ url: URL) -> [String: String] {
        Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Manter a tela ligada: `minutes=90` por um tempo (até 8 h), `off=1` para desligar. `on=1` (sem prazo e
    /// lembrado entre aberturas) só com `debug.urls`: qualquer página pode abrir o link, e a tela sempre acesa
    /// desliga o bloqueio por inatividade sem você perceber.
    private func keepAwake(_ url: URL, debug: Bool) {
        let query = Self.query(url)
        if query["off"] != nil {
            env.awake.turnOff()
        } else if let minutes = Double(query["minutes"] ?? ""), minutes.isFinite, minutes > 0 {
            env.awake.turnOn(for: min(minutes, 480) * 60)
        } else if debug, query["on"] != nil {
            env.awake.turnOn(for: nil)
        }
    }

    /// Depuração: macpet://scrolltest?dy=40&steps=30&interval=0.03 manda rolagens de trackpad para o meio da
    /// área do chat (positivo sobe a conversa), como um gesto: começo, meio, fim.
    private func scrollTest(_ url: URL) {
        let query = Self.query(url)
        // A prévia, se aberta, para não mexer na janela que você está usando.
        guard let window = previewWindow ?? dashboardWindow else { return }
        let dy = Int32(query["dy"] ?? "") ?? 40
        let steps = Int(query["steps"] ?? "") ?? 30
        let interval = Double(query["interval"] ?? "") ?? 0.03
        let frame = window.frame
        let screenHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
        let point = CGPoint(x: frame.minX + frame.width * 0.62, y: screenHeight - (frame.minY + frame.height * 0.55))
        for step in 0..<steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * interval) {
                guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) else { return }
                event.location = point
                // 1 = começou, 2 = mudou, 4 = terminou (kCGScrollPhase*)
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: step == 0 ? 1 : step == steps - 1 ? 4 : 2)
                if let nsEvent = NSEvent(cgEvent: event) { window.sendEvent(nsEvent) }
                // Simula o Claude trabalhando: um item novo a cada 4 passos.
                if query["append"] == "1", step % 4 == 0 { self.previewChatSession?.notice("item novo \(step)") }
            }
        }
    }

    @objc private func closeDashboard() {
        dashboardWindow?.close()
    }

    @objc private func openSettingsFromMenu() {
        showSettings()
    }

    /// Menu do app enquanto ele está no ⌘Tab. ⌘Q fecha só o painel: o MacPet continua na barra
    /// (monitor, pet, conversas). Para encerrar de vez: "Sair do MacPet" (⌥⌘Q).
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector?, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            return item
        }
        submenu("MacPet", [
            item("Preferências…", #selector(openSettingsFromMenu), ",", target: self),
            .separator(),
            item("Ocultar MacPet", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item("Fechar painel", #selector(closeDashboard), "q", target: self),
            item("Sair do MacPet", #selector(NSApplication.terminate(_:)), "q", [.command, .option]),
        ])
        submenu("Editar", [
            item("Desfazer", Selector(("undo:")), "z"),
            item("Refazer", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Recortar", #selector(NSText.cut(_:)), "x"),
            item("Copiar", #selector(NSText.copy(_:)), "c"),
            item("Colar", #selector(NSText.paste(_:)), "v"),
            item("Selecionar tudo", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("Janela", [
            item("Minimizar", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Fechar janela", #selector(NSWindow.performClose(_:)), "w"),
        ])
        return main
    }

    private func showSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: env.inject(SettingsView().mpDesignSystem().background(Theme.ink)))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Preferências do MacPet"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

private extension Optional where Wrapped: Collection {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
