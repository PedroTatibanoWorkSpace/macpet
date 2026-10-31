import SwiftUI

struct SettingsView: View {
    enum Tab: Hashable { case general, crow, focus, awake, alerts, claude }
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        VStack(spacing: 0) {
            MPTabs(items: [.init(value: .general, label: "Geral"), .init(value: .crow, label: "Corvo"), .init(value: .focus, label: "Foco"),
                           .init(value: .awake, label: "Tela ligada"),
                           .init(value: .alerts, label: "Alertas"), .init(value: .claude, label: "Claude")],
                   selection: $env.settingsTab)
                .fixedSize()
                .padding(.top, 14)
                .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch env.settingsTab {
                    case .general: GeneralSettings()
                    case .crow: CrowSettings()
                    case .focus: FocusSettings()
                    case .awake: AwakeSettings()
                    case .alerts: AlertSettings()
                    case .claude: ClaudeSettings()
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 540)
        .background(Theme.ink)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        MPFormSection(title: "Barra de menu",
                      footer: "Segure ⌘ e arraste os itens na barra para reordenar. Em Macs com notch, os itens mais à esquerda podem ficar escondidos: desligue os que não usa.") {
            ForEach(Metric.allCases) { metric in
                MPFormRow(label: metric.title) { Toggle("", isOn: binding(for: metric)).labelsHidden() }
            }
            MPFormRow(label: "Mostrar o pet na barra") { Toggle("", isOn: $settings.petEnabled).labelsHidden() }
            MPFormRow(label: "Botão do modo limpeza (✨)") { Toggle("", isOn: $settings.cleaningButtonEnabled).labelsHidden() }
        }
        MPFormSection(title: "Atualização") {
            MPFormRow(label: "Intervalo") {
                MPSelect(icon: "timer", title: "\(Int(settings.updateInterval)) s", options: [
                    .init(value: 1.0, label: "1 segundo"), .init(value: 2.0, label: "2 segundos"), .init(value: 5.0, label: "5 segundos"),
                ], selection: $settings.updateInterval)
            }
            MPFormRow(label: "Abrir ao iniciar o Mac") {
                Toggle("", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 })).labelsHidden()
            }
        }
    }

    private func binding(for metric: Metric) -> Binding<Bool> {
        Binding(
            get: { settings.modules.contains(metric) },
            set: { enabled in
                if enabled {
                    // Mantém a ordem padrão ao religar um item.
                    settings.modules = Metric.allCases.filter { settings.modules.contains($0) || $0 == metric }
                } else {
                    settings.modules.removeAll { $0 == metric }
                }
            }
        )
    }
}

private struct FocusSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var focus: FocusTimer

    var body: some View {
        MPFormSection(title: "Agora") {
            FocusCard()
        }
        MPFormSection(title: "Tempos") {
            MPFormRow(label: "Foco") { minutes($settings.focusMinutes, [15, 20, 25, 30, 40, 45, 50, 60]) }
            MPFormRow(label: "Pausa") { minutes($settings.breakMinutes, [3, 5, 10, 15]) }
            MPFormRow(label: "Pausa longa") { minutes($settings.longBreakMinutes, [10, 15, 20, 30]) }
            MPFormRow(label: "Pausa longa a cada") {
                MPSelect(icon: "repeat", title: settings.longBreakEvery == 0 ? "nunca" : "\(settings.longBreakEvery) focos",
                         options: [.init(value: 0, label: "Nunca")] + [2, 3, 4, 5].map { .init(value: $0, label: "\($0) focos") },
                         selection: $settings.longBreakEvery)
            }
        }
        MPFormSection(title: "Durante o foco",
                      footer: "O corvo cochila quieto no lugar. Continuam chegando só os avisos urgentes: o Claude pedindo permissão e servidor que caiu. Tarefas terminadas, horário de pico e alertas do Mac esperam a pausa, quando o corvo conta o que aconteceu.") {
            MPFormRow(label: "Guardar notificações até a pausa") { Toggle("", isOn: $settings.focusHoldNotifications).labelsHidden() }
            MPFormRow(label: "Manter a tela ligada") { Toggle("", isOn: $settings.focusKeepAwake).labelsHidden() }
        }
    }

    private func minutes(_ value: Binding<Int>, _ options: [Int]) -> some View {
        MPSelect(icon: "timer", title: "\(value.wrappedValue) min", options: options.map { .init(value: $0, label: "\($0) min") },
                 selection: value)
    }
}

private struct AwakeSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var awake: KeepAwake

    var body: some View {
        MPFormSection(title: "Agora") {
            MPFormRow(label: "Manter a tela ligada", detail: awake.statusText) { KeepAwakeControl() }
        }
        MPFormSection(title: "Horários",
                      footer: "Nesses horários a tela não apaga, o descanso de tela não entra e o Mac não bloqueia sozinho. O MacPet precisa estar aberto, e com a tampa fechada o Mac dorme mesmo assim.") {
            if settings.awakeSchedules.isEmpty {
                Text("Nenhum horário. Adicione um para a tela ficar ligada sozinha, por exemplo nos dias úteis em horário de trabalho.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach($settings.awakeSchedules) { $schedule in
                AwakeScheduleRow(schedule: $schedule) {
                    settings.awakeSchedules.removeAll { $0.id == schedule.id }
                }
            }
        }
        Button {
            settings.awakeSchedules.append(AwakeSchedule())
        } label: {
            Label("Adicionar horário", systemImage: "plus")
        }
        .fixedSize()
    }
}

/// Um horário: liga/desliga, dias da semana e intervalo.
private struct AwakeScheduleRow: View {
    @Binding var schedule: AwakeSchedule
    let remove: () -> Void

    /// Segunda primeiro: o comum é agendar a semana de trabalho.
    private static let week: [(Int, String)] = [(2, "Seg"), (3, "Ter"), (4, "Qua"), (5, "Qui"), (6, "Sex"), (7, "Sáb"), (1, "Dom")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(isOn: $schedule.enabled) { Text(summary).font(.system(size: 13, weight: .semibold)) }
                Spacer()
                MPIconButton(icon: "trash", label: "Apagar horário", action: remove)
            }
            HStack(spacing: 4) {
                ForEach(Self.week, id: \.0) { day, label in
                    let on = schedule.days.contains(day)
                    Button {
                        if on { schedule.days.remove(day) } else { schedule.days.insert(day) }
                    } label: {
                        Text(label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(on ? AnyShapeStyle(Theme.sheen) : AnyShapeStyle(Theme.textMuted))
                            .frame(width: 40, height: 24)
                            .background(on ? AnyShapeStyle(Theme.sheenSoft) : AnyShapeStyle(Theme.plumageRaised), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            HStack(spacing: 6) {
                Text("Das").foregroundStyle(Theme.textMuted)
                TimeSelect(minutes: $schedule.start)
                Text("às").foregroundStyle(Theme.textMuted)
                TimeSelect(minutes: $schedule.end)
                if schedule.end < schedule.start {
                    Text("do dia seguinte").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                } else if schedule.end == schedule.start {
                    Text("(dia inteiro)").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
            }
        }
        .opacity(schedule.enabled ? 1 : 0.6)
    }

    private var summary: String {
        let days: String
        switch schedule.days {
        case []: days = "Nenhum dia"
        case Set(1...7): days = "Todo dia"
        case [2, 3, 4, 5, 6]: days = "Dias úteis"
        case [1, 7]: days = "Fim de semana"
        default: days = Self.week.filter { schedule.days.contains($0.0) }.map(\.1).joined(separator: ", ")
        }
        let range = schedule.start == schedule.end ? "o dia inteiro"
            : "\(AwakeSchedule.time(schedule.start))–\(AwakeSchedule.time(schedule.end))"
        return "\(days), \(range)"
    }
}

/// Hora e minuto em dois chips (o minuto em passos de 15).
private struct TimeSelect: View {
    @Binding var minutes: Int

    var body: some View {
        HStack(spacing: 0) {
            MPSelect(title: String(format: "%02d", minutes / 60),
                     options: (0..<24).map { .init(value: $0, label: String(format: "%02d h", $0)) },
                     selection: Binding(get: { minutes / 60 }, set: { minutes = $0 * 60 + minutes % 60 }))
            Text(":").font(Theme.mono(12)).foregroundStyle(Theme.textMuted)
            MPSelect(title: String(format: "%02d", minutes % 60),
                     options: [0, 15, 30, 45].map { .init(value: $0, label: String(format: ":%02d", $0)) },
                     selection: Binding(get: { minutes % 60 }, set: { minutes = minutes / 60 * 60 + $0 }))
        }
        .font(Theme.mono(12))
        .background(Theme.ink, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.quillStrong))
    }
}

private struct AlertSettings: View {
    @EnvironmentObject private var settings: AppSettings

    private static let durations: [(Double, String)] = [(0, "na hora"), (60, "1 min"), (120, "2 min"), (300, "5 min"), (600, "10 min")]

    var body: some View {
        MPFormSection(title: "Alertas",
                      footer: "Quando um alerta dispara, o item da barra fica vermelho e chega uma notificação (no máximo uma a cada 15 min por regra).") {
            ForEach($settings.alertRules) { $rule in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Toggle(isOn: $rule.enabled) { Text(rule.metric.title).font(.system(size: 13, weight: .semibold)) }
                        Spacer()
                        MPIconButton(icon: "trash", label: "Apagar alerta") {
                            settings.alertRules.removeAll { $0.id == rule.id }
                        }
                    }
                    HStack(spacing: 12) {
                        Text("Acima de \(Int(rule.threshold))\(rule.metric.unit)").font(Theme.mono(12)).frame(width: 110, alignment: .leading)
                        MPSlider(value: $rule.threshold, range: rule.metric.range)
                    }
                    HStack(spacing: 8) {
                        Text("Por pelo menos").foregroundStyle(Theme.textMuted)
                        MPSelect(icon: "clock", title: Self.durations.first { $0.0 == rule.duration }?.1 ?? "\(Int(rule.duration))s",
                                 options: Self.durations.map { .init(value: $0.0, label: $0.1) }, selection: $rule.duration)
                    }
                }
                .disabled(!rule.enabled)
                .opacity(rule.enabled ? 1 : 0.6)
            }
        }
        MPMenuButton(entries: {
            AlertMetric.allCases.map { metric in
                .item(metric.title) {
                    settings.alertRules.append(AlertRule(metric: metric, threshold: metric == .temperature ? 85 : 80, duration: 60))
                }
            }
        }) {
            Label("Adicionar alerta", systemImage: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.sheen)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Theme.sheenSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
        .fixedSize()
    }
}

private struct ClaudeSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var hooks: HookInstaller
    @EnvironmentObject private var peak: PeakMonitor

    var body: some View {
        MPFormSection(title: "Integração",
                      footer: "Os hooks ficam em ~/.claude/settings.json (backup em settings.json.macpet-backup). Se o MacPet não estiver aberto, eles não fazem nada.") {
            MPFormRow(label: "Hooks do Claude Code") {
                MPBadge(text: hooks.installed ? "instalados" : "não instalados", tone: hooks.installed ? .success : .neutral,
                        icon: hooks.installed ? "checkmark" : nil)
            }
            HStack(spacing: 8) {
                Button(hooks.installed ? "Reinstalar" : "Instalar hooks") { hooks.install() }
                    .buttonStyle(.mp(hooks.installed ? .secondary : .primary, size: .sm))
                if hooks.installed {
                    Button("Remover hooks") { hooks.uninstall() }.buttonStyle(.mp(.danger, size: .sm))
                }
                if let error = hooks.lastError {
                    Text(error).font(.system(size: 11)).foregroundStyle(Theme.danger)
                }
            }
        }
        MPFormSection(title: "Notificações") {
            MPFormRow(label: "Notificar com o terminal em primeiro plano") {
                Toggle("", isOn: $settings.notifyWhenTerminalFocused).labelsHidden()
            }
            MPFormRow(label: "Tocar som") { Toggle("", isOn: $settings.notificationSound).labelsHidden() }
        }
        MPFormSection(title: "Horário de pico do Claude",
                      footer: "Em dias úteis, nesse intervalo, a janela de 5h do plano é consumida mais rápido. No seu fuso: \(PeakMonitor.localRange(start: settings.peakStartHour, end: settings.peakEndHour)). A Anthropic anunciou 5h–11h no horário do Pacífico; ajuste se a regra mudar.") {
            MPFormRow(label: "Mostrar quando estiver no pico") { Toggle("", isOn: $settings.peakEnabled).labelsHidden() }
            MPFormRow(label: "Avisar quando o pico começar") {
                Toggle("", isOn: $settings.peakNotify).labelsHidden()
            }
            .disabled(!settings.peakEnabled)
            MPFormRow(label: "Intervalo (horário do Pacífico)") {
                HStack(spacing: 8) {
                    MPStepper(value: $settings.peakStartHour, range: 0...23, suffix: "h")
                    Text("às").foregroundStyle(Theme.textMuted)
                    MPStepper(value: $settings.peakEndHour, range: 1...24, suffix: "h")
                }
            }
            .disabled(!settings.peakEnabled)
        }
        .onChange(of: settings.peakEnabled) { _, _ in peak.refresh() }
        .onChange(of: settings.peakStartHour) { _, _ in peak.refresh() }
        .onChange(of: settings.peakEndHour) { _, _ in peak.refresh() }
        .onAppear { hooks.refresh() }
    }
}
