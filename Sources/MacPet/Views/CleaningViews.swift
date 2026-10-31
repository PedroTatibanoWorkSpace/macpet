import SwiftUI

/// Janelinha que explica e ativa o modo limpeza.
struct CleaningPanelView: View {
    @EnvironmentObject private var cleaning: CleaningMode

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(Theme.ember)
                Text("Modo limpeza").font(.title3.weight(.semibold))
            }

            Text("Apaga a tela e desliga o teclado para você limpar o Mac. O touchpad continua funcionando para você clicar em **Sair** quando terminar.")
                .fixedSize(horizontal: false, vertical: true)

            if cleaning.hasPermission {
                Label("Permissão de Acessibilidade concedida", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Para desligar o teclado o MacPet precisa da permissão de Acessibilidade.", systemImage: "lock.fill")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Em Ajustes → Privacidade e Segurança → Acessibilidade, ligue o MacPet. Esta janela atualiza sozinha.\n\nSe o MacPet já aparece ligado e mesmo assim não funciona, é a permissão de uma versão antiga: selecione o MacPet, clique em − para remover e conceda de novo.")
                        .font(.caption).foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Conceder permissão…") { cleaning.requestPermission() }
                }
                .padding(10)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            if let error = cleaning.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Text("Sair sozinho depois de")
                MPSelect(icon: "timer", title: "\(cleaning.autoExitMinutes) min", options: [
                    .init(value: 2, label: "2 min"), .init(value: 5, label: "5 min"), .init(value: 10, label: "10 min"),
                ], selection: $cleaning.autoExitMinutes)
                Spacer()
            }

            Text("O botão liga/Touch ID não pode ser bloqueado pelo macOS. Evite apertá-lo durante a limpeza.")
                .font(.caption).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Ativar modo limpeza") { cleaning.activate() }
                    .buttonStyle(.mp(.primary))
                    .controlSize(.large)
                    .disabled(!cleaning.hasPermission)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// Conteúdo da tela preta. Só a tela principal mostra o botão de sair.
struct CleaningOverlayView: View {
    let showsControls: Bool
    @EnvironmentObject private var cleaning: CleaningMode
    @State private var pressing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if showsControls {
                VStack(spacing: 18) {
                    Spacer()
                    Text("Modo limpeza · teclado desligado")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.35))
                    if let deadline = cleaning.exitDeadline {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = max(0, Int(deadline.timeIntervalSince(context.date)))
                            Text("Sai sozinho em \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.25))
                        }
                    }
                    exitButton
                        .padding(.bottom, 80)
                }
            }
        }
    }

    /// Segurar por 1s evita que um esbarrão no touchpad com o pano encerre a limpeza.
    private var exitButton: some View {
        ZStack {
            Capsule()
                .fill(.white.opacity(pressing ? 0.22 : 0.12))
            Capsule()
                .trim(from: 0, to: pressing ? 1 : 0)
                .stroke(.white.opacity(0.8), lineWidth: 2)
                .animation(pressing ? .linear(duration: 1) : .easeOut(duration: 0.2), value: pressing)
            Text(pressing ? "Continue segurando…" : "Segure para sair do modo limpeza")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(width: 320, height: 54)
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: 1, maximumDistance: 40) {
            cleaning.deactivate()
        } onPressingChanged: { isPressing in
            pressing = isPressing
        }
    }
}
