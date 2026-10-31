import SwiftUI

struct PetView: View {
    @EnvironmentObject private var pet: PetModel
    @EnvironmentObject private var claude: ClaudeSessionStore
    @EnvironmentObject private var hooks: HookInstaller
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var limits: RateLimitStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var servers: ServerMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AnimatedPet(mood: pet.mood, scale: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacPet").font(.headline)
                    Text(pet.moodDescription).font(.callout).foregroundStyle(Theme.textMuted)
                }
            }

            if !hooks.installed {
                HookSetupCard()
            }

            if limits.hasData {
                HStack(spacing: 12) {
                    MiniLimit(title: "5h", window: limits.fiveHour)
                    MiniLimit(title: "Semana", window: limits.sevenDay)
                }
            }

            FocusCard()

            if !servers.entries.isEmpty {
                ServersList(entries: servers.entries)
            }

            KeepAwakeCard()

            Toggle(isOn: $settings.desktopPetEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Corvo na tela").font(.callout.weight(.medium))
                    Text("Arraste, clique para carinho, clique direito para mais").font(.caption).foregroundStyle(Theme.textMuted)
                }
            }

            Button {
                env.openDashboard()
            } label: {
                Label("Abrir dashboard do Claude", systemImage: "chart.bar.xaxis")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            if !claude.sessions.isEmpty {
                Text("Sessões do Claude Code").font(.subheadline.weight(.semibold))
                VStack(spacing: 4) {
                    ForEach(claude.ordered) { session in
                        SessionRow(session: session)
                    }
                }
            } else if hooks.installed {
                Text("Nenhuma sessão ativa. Abra o Claude Code em algum projeto e ela aparece aqui.")
                    .font(.callout).foregroundStyle(Theme.textMuted)
            }

            MPDivider()
            HStack {
                Button("Preferências…") { env.openSettings() }
                Button("Modo limpeza…") { env.cleaning.showPanel() }
                Spacer()
                Button("Sair do MacPet") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.callout)
        }
        .padding(14)
        .frame(width: 360)
    }
}

/// Modo foco (pomodoro): começa, mostra o relógio e controla a fase atual.
struct FocusCard: View {
    @EnvironmentObject private var focus: FocusTimer
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(focus.isActive ? AnyShapeStyle(Theme.sheen) : AnyShapeStyle(Theme.textMuted))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    if focus.isActive {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(focus.phaseLabel).font(.callout.weight(.medium))
                            Text(focus.clock).font(Theme.mono(15)).monospacedDigit()
                        }
                    } else {
                        Text("Modo foco").font(.callout.weight(.medium))
                    }
                    Text(subtitle).font(.caption).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
                Spacer(minLength: 8)
                controls
            }
            if focus.isActive {
                ProgressView(value: focus.progress)
                    .tint(focus.phase == .focus ? ProjectColor.violet.color : ProjectColor.sage.color)
            }
        }
        .padding(10)
        .background(focus.isActive ? AnyShapeStyle(Theme.sheenSoft) : AnyShapeStyle(Theme.plumage),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.quill))
    }

    private var icon: String {
        switch focus.phase {
        case .focus: focus.isPaused ? "pause.circle" : "moon.zzz.fill"
        case .shortBreak, .longBreak: "cup.and.saucer.fill"
        case nil: "timer"
        }
    }

    private var subtitle: String {
        switch focus.phase {
        case .focus:
            let held = focus.held.count
            if !settings.focusHoldNotifications { return "\(focus.completedToday) focos hoje" }
            return held == 0 ? "Notificações guardadas até a pausa" : "\(held) aviso\(held == 1 ? "" : "s") guardado\(held == 1 ? "" : "s") para a pausa"
        case .shortBreak, .longBreak:
            return "Levanta, alonga, bebe uma água"
        case nil:
            let today = focus.completedToday
            return "\(settings.focusMinutes) min de foco, \(settings.breakMinutes) de pausa" + (today > 0 ? " · \(today) hoje" : "")
        }
    }

    @ViewBuilder
    private var controls: some View {
        if !focus.isActive {
            Button("Começar") { focus.startFocus() }.buttonStyle(.mp(.primary, size: .sm))
        } else {
            HStack(spacing: 2) {
                if focus.phase == .focus {
                    if focus.isPaused {
                        MPIconButton(icon: "play.fill", label: "Continuar") { focus.resume() }
                    } else {
                        MPIconButton(icon: "pause.fill", label: "Pausar") { focus.pause() }
                    }
                }
                MPIconButton(icon: "forward.fill", label: focus.phase == .focus ? "Ir para a pausa" : "Pular pausa") { focus.skip() }
                MPIconButton(icon: "stop.fill", label: "Encerrar") { focus.stop() }
            }
        }
    }
}

/// Servidores rodando nos terminais de todos os projetos; clicar abre o terminal dele.
struct ServersList: View {
    let entries: [ServerEntry]
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Servidores").font(.subheadline.weight(.semibold))
            ForEach(entries) { entry in
                Button { open(entry) } label: {
                    HStack(spacing: 8) {
                        MPStatusDot(status: dot(entry.status), showsLabel: false)
                        Text(entry.projectName).font(.callout.weight(.medium)).lineLimit(1)
                        Text(entry.title).font(.callout).foregroundStyle(Theme.textMuted).lineLimit(1)
                        Spacer()
                        Text(detail(entry.status)).font(Theme.mono(11))
                            .foregroundStyle(entry.status.isCrashed ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(Theme.textMuted))
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Abrir o terminal deste servidor")
            }
        }
    }

    private func open(_ entry: ServerEntry) {
        store.openTerminalGroups.first { $0.projectId == entry.projectId }?.group.selectedId = entry.id
        store.hubSelection = .project(entry.projectId)
        store.tabRequest = .terminal
        env.openDashboard()
    }

    private func dot(_ status: ServerStatus) -> MPStatusDot.Status {
        switch status {
        case .idle, .stopped: .idle
        case .starting: .working
        case .up: .ok
        case .crashed: .error
        }
    }

    private func detail(_ status: ServerStatus) -> String {
        switch status {
        case .idle, .stopped: "parado"
        case .starting: "subindo…"
        case .up(let ports): ports.prefix(2).map { ":\(String($0))" }.joined(separator: " ")
        case .crashed: "caiu"
        }
    }
}

/// Manter a tela ligada: o estado e o atalho para ligar por um tempo ou desligar.
struct KeepAwakeCard: View {
    @EnvironmentObject private var awake: KeepAwake

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: awake.isActive ? "sun.max.fill" : "moon.zzz")
                .font(.system(size: 14))
                .foregroundStyle(awake.isActive ? AnyShapeStyle(Theme.sheen) : AnyShapeStyle(Theme.textMuted))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Manter a tela ligada").font(.callout.weight(.medium))
                Text(awake.statusText).font(.caption).foregroundStyle(Theme.textMuted)
            }
            Spacer(minLength: 8)
            KeepAwakeControl()
        }
        .padding(10)
        .background(awake.isActive ? AnyShapeStyle(Theme.sheenSoft) : AnyShapeStyle(Theme.plumage),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.quill))
    }
}

/// Ligada: botão de desligar. Desligada: menu com quanto tempo manter ligada.
struct KeepAwakeControl: View {
    @EnvironmentObject private var awake: KeepAwake
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        if awake.isActive {
            Button("Desligar") { awake.turnOff() }
                .buttonStyle(.mp(.secondary, size: .sm))
        } else {
            MPMenuButton(entries: {[
                .header("Manter ligada por"),
                .item("30 minutos") { awake.turnOn(for: 30 * 60) },
                .item("1 hora") { awake.turnOn(for: 3600) },
                .item("2 horas") { awake.turnOn(for: 2 * 3600) },
                .item("4 horas") { awake.turnOn(for: 4 * 3600) },
                .item("Até eu desligar", icon: "infinity") { awake.turnOn(for: nil) },
                .divider,
                .item("Agendar horários…", icon: "calendar") { env.openSettings(.awake) },
            ]}) {
                HStack(spacing: 4) {
                    Text("Ligar")
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.onSheen)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Theme.sheenStrong, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            }
            .fixedSize()
        }
    }
}

struct MiniLimit: View {
    let title: String
    let window: RateWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                Text(window.map { $0.isExpired ? "0%" : "\(Int($0.usedPercentage.rounded()))%" } ?? "—")
                    .font(.caption).monospacedDigit()
            }
            ProgressView(value: window?.fraction ?? 0)
                .tint((window?.fraction ?? 0) >= 0.9 ? Color(hex: 0xFF7B72) : (window?.fraction ?? 0) >= 0.7 ? Theme.ember : Theme.sheen)
            if let window, !window.isExpired {
                Text("reinicia em \(Format.until(window.resetsAt))").font(.caption2).foregroundStyle(Theme.textMuted)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct AnimatedPet: View {
    let mood: PetMood
    let scale: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / mood.fps)) { context in
            let frames = mood.frames
            let index = frames.isEmpty ? 0 : Int(context.date.timeIntervalSinceReferenceDate * mood.fps) % frames.count
            if !frames.isEmpty {
                Image(nsImage: PetSprites.image(frames[index], scale: scale))
                    .interpolation(.none)
            }
        }
        .frame(width: CGFloat(PetSprites.width) * scale, height: CGFloat(PetSprites.height) * scale)
    }
}

struct HookSetupCard: View {
    @EnvironmentObject private var hooks: HookInstaller

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Conectar ao Claude Code").font(.subheadline.weight(.semibold))
            Text("Adiciona hooks em ~/.claude/settings.json (com backup) para o pet saber quando uma sessão trabalha, termina ou espera você. Sessões já abertas passam a aparecer depois de reiniciadas.")
                .font(.caption).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Instalar hooks") { hooks.install() }
                .buttonStyle(.mp(.primary))
            if let error = hooks.lastError {
                Text(error).font(.caption).foregroundStyle(Theme.danger)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SessionRow: View {
    let session: ClaudeSession
    @EnvironmentObject private var claude: ClaudeSessionStore
    @State private var hovering = false

    var body: some View {
        Button {
            claude.open(session.id)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(session.projectName).font(.callout.weight(.medium))
                        Spacer()
                        Text("\(session.state.label) · \(Format.relative(session.lastEvent))")
                            .font(.caption).foregroundStyle(Theme.textMuted)
                    }
                    if let message = session.message {
                        Text(message).font(.caption).foregroundStyle(Theme.textMuted).lineLimit(2)
                    }
                    if session.model != nil || session.contextPercentage != nil {
                        Text([session.model, session.contextPercentage.map { "contexto \(Int($0))%" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(Theme.textFaint)
                    }
                }
            }
            .padding(6)
            .contentShape(Rectangle())
            .background(hovering ? AnyShapeStyle(Theme.plumageRaised) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Abrir o terminal desta sessão")
        .mpContextMenu {[
            .item("Abrir terminal", icon: "terminal") { claude.open(session.id) },
            .item("Remover da lista", icon: "minus.circle") { claude.dismiss(session.id) },
        ]}
    }

    private var color: Color { session.state.color }
}
