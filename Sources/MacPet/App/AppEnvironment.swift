import SwiftUI

/// Agrupa os serviços do app e injeta todos como EnvironmentObject nas views.
@MainActor
final class AppEnvironment: ObservableObject {
    let settings = AppSettings.shared
    let history = HistoryStore()
    let monitor: SystemMonitor
    let notifier: Notifier
    let alerts: AlertEngine
    let claude: ClaudeSessionStore
    let hooks = HookInstaller()
    let pet: PetModel
    let cleaning = CleaningMode()
    let usage = UsageIndex()
    let limits = RateLimitStore()
    let prompts = PromptLibrary()
    let config = ClaudeConfig()
    let projects = ProjectStore()
    let peak: PeakMonitor
    let awake: KeepAwake
    let servers: ServerMonitor
    let focus: FocusTimer

    var openSettings: () -> Void = {}
    /// Aba das Preferências; quem abre numa aba específica muda isto antes de `openSettings`.
    @Published var settingsTab: SettingsView.Tab = .general
    var openDashboard: () -> Void = {}
    /// Faz o corvo da tela comemorar agora (botão "Ver comemoração" do guarda-roupa).
    var celebratePet: () -> Void = {}

    init() {
        monitor = SystemMonitor(history: history)
        notifier = Notifier(settings: settings)
        alerts = AlertEngine(settings: settings, notifier: notifier)
        claude = ClaudeSessionStore(notifier: notifier, settings: settings)
        pet = PetModel(claude: claude, monitor: monitor, limits: limits)
        peak = PeakMonitor(settings: settings, notifier: notifier)
        awake = KeepAwake(settings: settings)
        servers = ServerMonitor(projects: projects, notifier: notifier)
        focus = FocusTimer(settings: settings, notifier: notifier)
        cleaning.attach(self)
    }

    func openSettings(_ tab: SettingsView.Tab) {
        settingsTab = tab
        openSettings()
    }

    func inject<V: View>(_ view: V) -> some View {
        view
            .environmentObject(self)
            .environmentObject(settings)
            .environmentObject(monitor)
            .environmentObject(alerts)
            .environmentObject(claude)
            .environmentObject(hooks)
            .environmentObject(pet)
            .environmentObject(cleaning)
            .environmentObject(usage)
            .environmentObject(limits)
            .environmentObject(prompts)
            .environmentObject(config)
            .environmentObject(projects)
            .environmentObject(peak)
            .environmentObject(awake)
            .environmentObject(servers)
            .environmentObject(focus)
    }
}
