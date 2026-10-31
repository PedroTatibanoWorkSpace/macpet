import Foundation
import ServiceManagement

/// Preferências persistidas em UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// Itens visíveis na barra, da esquerda para a direita.
    @Published var modules: [Metric] {
        didSet { defaults.set(modules.map(\.rawValue), forKey: "modules") }
    }

    @Published var updateInterval: Double {
        didSet { defaults.set(updateInterval, forKey: "updateInterval") }
    }

    @Published var alertRules: [AlertRule] {
        didSet { save(alertRules, "alertRules") }
    }

    @Published var petEnabled: Bool {
        didSet { defaults.set(petEnabled, forKey: "petEnabled") }
    }

    @Published var cleaningButtonEnabled: Bool {
        didSet { defaults.set(cleaningButtonEnabled, forKey: "cleaningButtonEnabled") }
    }

    /// Notificar fim de tarefa do Claude mesmo quando o terminal da sessão está em primeiro plano.
    @Published var notifyWhenTerminalFocused: Bool {
        didSet { defaults.set(notifyWhenTerminalFocused, forKey: "notifyWhenTerminalFocused") }
    }

    @Published var notificationSound: Bool {
        didSet { defaults.set(notificationSound, forKey: "notificationSound") }
    }

    /// Horário de pico do Claude (ver PeakMonitor). Horas no fuso do Pacífico.
    @Published var peakEnabled: Bool {
        didSet { defaults.set(peakEnabled, forKey: "peakEnabled") }
    }
    @Published var peakNotify: Bool {
        didSet { defaults.set(peakNotify, forKey: "peakNotify") }
    }
    @Published var peakStartHour: Int {
        didSet { defaults.set(peakStartHour, forKey: "peakStartHour") }
    }
    @Published var peakEndHour: Int {
        didSet { defaults.set(peakEndHour, forKey: "peakEndHour") }
    }

    /// Horários em que a tela fica ligada (ver KeepAwake).
    @Published var awakeSchedules: [AwakeSchedule] {
        didSet { save(awakeSchedules, "awakeSchedules") }
    }

    /// Corvo solto na tela (ver DesktopPet).
    @Published var desktopPetEnabled: Bool {
        didSet { defaults.set(desktopPetEnabled, forKey: "desktopPetEnabled") }
    }
    /// Pixels por célula da arte: 3 pequeno, 4 médio, 5 grande.
    @Published var desktopPetScale: Int {
        didSet { defaults.set(desktopPetScale, forKey: "desktopPetScale") }
    }
    /// Anda, voa e cai sozinho; desligado, fica onde você deixar.
    @Published var desktopPetRoams: Bool {
        didSet { defaults.set(desktopPetRoams, forKey: "desktopPetRoams") }
    }

    /// Modo foco (ver FocusTimer): minutos de foco, pausa e pausa longa; pausa longa a cada N focos (0: nunca).
    @Published var focusMinutes: Int { didSet { defaults.set(focusMinutes, forKey: "focusMinutes") } }
    @Published var breakMinutes: Int { didSet { defaults.set(breakMinutes, forKey: "breakMinutes") } }
    @Published var longBreakMinutes: Int { didSet { defaults.set(longBreakMinutes, forKey: "longBreakMinutes") } }
    @Published var longBreakEvery: Int { didSet { defaults.set(longBreakEvery, forKey: "longBreakEvery") } }
    /// Segura as notificações que podem esperar (tarefa terminada, pico, alertas) até a pausa.
    @Published var focusHoldNotifications: Bool { didSet { defaults.set(focusHoldNotifications, forKey: "focusHoldNotifications") } }
    /// Tela ligada durante o foco (lendo código, o Mac não apaga).
    @Published var focusKeepAwake: Bool { didSet { defaults.set(focusKeepAwake, forKey: "focusKeepAwake") } }

    /// Roupa do corvo (barra e tela).
    @Published var petOutfit: PetOutfit {
        didSet {
            save(petOutfit, "petOutfit")
            PetArt.outfit = petOutfit
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("MacPet: falha ao alterar login item: \(error)")
            }
        }
    }

    private init() {
        let storedModules = (defaults.array(forKey: "modules") as? [String])?.compactMap(Metric.init(rawValue:))
        var initialModules = storedModules ?? Metric.defaultModules
        // v0.1: THR saiu do padrão para economizar espaço na barra (o notch esconde itens).
        if !defaults.bool(forKey: "migration.removeThermal") {
            initialModules.removeAll { $0 == .thermal }
            defaults.set(initialModules.map(\.rawValue), forKey: "modules")
            defaults.set(true, forKey: "migration.removeThermal")
        }
        modules = initialModules
        updateInterval = defaults.object(forKey: "updateInterval") as? Double ?? 2
        alertRules = Self.load([AlertRule].self, "alertRules", defaults) ?? AlertRule.defaults
        petEnabled = defaults.object(forKey: "petEnabled") as? Bool ?? true
        cleaningButtonEnabled = defaults.object(forKey: "cleaningButtonEnabled") as? Bool ?? true
        notifyWhenTerminalFocused = defaults.bool(forKey: "notifyWhenTerminalFocused")
        notificationSound = defaults.object(forKey: "notificationSound") as? Bool ?? true
        peakEnabled = defaults.object(forKey: "peakEnabled") as? Bool ?? true
        peakNotify = defaults.object(forKey: "peakNotify") as? Bool ?? true
        peakStartHour = defaults.object(forKey: "peakStartHour") as? Int ?? 5
        peakEndHour = defaults.object(forKey: "peakEndHour") as? Int ?? 11
        awakeSchedules = Self.load([AwakeSchedule].self, "awakeSchedules", defaults) ?? []
        desktopPetEnabled = defaults.object(forKey: "desktopPetEnabled") as? Bool ?? true
        desktopPetScale = defaults.object(forKey: "desktopPetScale") as? Int ?? 4
        desktopPetRoams = defaults.object(forKey: "desktopPetRoams") as? Bool ?? true
        focusMinutes = defaults.object(forKey: "focusMinutes") as? Int ?? 25
        breakMinutes = defaults.object(forKey: "breakMinutes") as? Int ?? 5
        longBreakMinutes = defaults.object(forKey: "longBreakMinutes") as? Int ?? 15
        longBreakEvery = defaults.object(forKey: "longBreakEvery") as? Int ?? 4
        focusHoldNotifications = defaults.object(forKey: "focusHoldNotifications") as? Bool ?? true
        focusKeepAwake = defaults.object(forKey: "focusKeepAwake") as? Bool ?? true
        petOutfit = Self.load(PetOutfit.self, "petOutfit", defaults) ?? PetOutfit()
        PetArt.outfit = petOutfit
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
