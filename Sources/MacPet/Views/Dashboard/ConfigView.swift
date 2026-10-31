import AppKit
import SwiftUI

struct ConfigView: View {
    @EnvironmentObject private var config: ClaudeConfig
    @State private var newAllow = ""
    @State private var newDeny = ""
    @State private var savedClaudeMd = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error = config.lastError {
                    MPBanner(tone: .danger, title: "Não deu para salvar", message: error)
                }

                MPFormSection(title: "Instruções globais (CLAUDE.md)", footer: "Valem para todas as sessões, em qualquer projeto.") {
                    VStack(alignment: .leading, spacing: 10) {
                        MPTextArea(text: $config.claudeMd, mono: true, height: 180)
                        HStack {
                            Text((ClaudeConfig.claudeMdURL.path as NSString).abbreviatingWithTildeInPath)
                                .font(Theme.mono(10)).foregroundStyle(Theme.textFaint)
                            Spacer()
                            Button("Salvar") {
                                config.saveClaudeMd()
                                savedClaudeMd = config.claudeMd
                            }
                            .buttonStyle(.mp(.primary, size: .sm))
                            .disabled(config.claudeMd == savedClaudeMd)
                        }
                    }
                }

                MPFormSection(title: "Permitido sem perguntar") {
                    PermissionList(rules: $config.allow, newRule: $newAllow, placeholder: "Ex.: Bash(npm test:*)") { config.savePermissions() }
                }

                MPFormSection(title: "Bloqueado") {
                    PermissionList(rules: $config.deny, newRule: $newDeny, placeholder: "Ex.: Bash(rm -rf:*)") { config.savePermissions() }
                }

                MPFormSection(title: "Plugins") {
                    if config.plugins.isEmpty { Text("Nenhum plugin").foregroundStyle(Theme.textMuted) }
                    ForEach(config.plugins, id: \.name) { plugin in
                        MPFormRow(label: plugin.name) {
                            Toggle("", isOn: Binding(get: { plugin.enabled }, set: { config.setPlugin(plugin.name, enabled: $0) })).labelsHidden()
                        }
                    }
                }

                MPFormSection(title: "Hooks") {
                    if config.hooks.isEmpty { Text("Nenhum hook").foregroundStyle(Theme.textMuted) }
                    ForEach(config.hooks) { hook in
                        HStack(alignment: .top) {
                            Text(hook.event).font(.system(size: 13, weight: .medium)).frame(width: 150, alignment: .leading)
                            Text(hook.isMacPet ? "MacPet" : hook.command)
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(2)
                        }
                    }
                }

                MPFormSection(title: "Arquivo de configuração",
                              footer: "Antes de qualquer alteração o MacPet salva uma cópia em settings.json.macpet-backup. Servidores MCP e skills têm abas próprias.") {
                    MPFormRow(label: "Modelo padrão") { Text(config.model ?? "padrão do Claude Code").font(Theme.mono(12)).foregroundStyle(Theme.textMuted) }
                    MPFormRow(label: "settings.json") {
                        Button("Abrir") { NSWorkspace.shared.open(ClaudeSettingsFile.url) }.buttonStyle(.mp(.secondary, size: .sm))
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Configuração")
        .onAppear {
            config.reload()
            savedClaudeMd = config.claudeMd
        }
    }
}

private struct PermissionList: View {
    @Binding var rules: [String]
    @Binding var newRule: String
    let placeholder: String
    let onChange: () -> Void

    var body: some View {
        ForEach(rules, id: \.self) { rule in
            HStack {
                Text(rule).font(Theme.mono(12)).lineLimit(1).truncationMode(.middle)
                Spacer()
                MPIconButton(icon: "minus.circle", label: "Remover regra") {
                    rules.removeAll { $0 == rule }
                    onChange()
                }
            }
        }
        HStack {
            TextField(placeholder, text: $newRule)
                .textFieldStyle(.mpMono)
                .onSubmit(add)
            Button("Adicionar", action: add)
                .buttonStyle(.mp(.secondary, size: .sm))
                .disabled(newRule.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func add() {
        let rule = newRule.trimmingCharacters(in: .whitespaces)
        guard !rule.isEmpty, !rules.contains(rule) else { return }
        rules.append(rule)
        newRule = ""
        onChange()
    }
}
