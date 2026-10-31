import AppKit
import SwiftUI

/// Uma skill do Claude Code: pasta com SKILL.md (suas ou de um projeto) ou vinda de um plugin.
struct SkillEntry: Identifiable, Hashable {
    enum Source: Hashable {
        case user
        case project(String)
        case plugin(String)
    }

    let name: String
    let description: String
    let source: Source
    /// SKILL.md (nil para skills de plugin, que só são listadas).
    let file: String?

    var id: String { file ?? "plugin:\(name)" }
    var editable: Bool { file != nil }
}

@MainActor
final class SkillCatalog: ObservableObject {
    @Published private(set) var user: [SkillEntry] = []
    @Published private(set) var projects: [(project: String, skills: [SkillEntry])] = []
    @Published private(set) var plugins: [(plugin: String, skills: [SkillEntry])] = []
    @Published private(set) var loadingPlugins = false

    static let userFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills").path

    func reload(projects list: [Project]) {
        user = Self.scan(Self.userFolder, source: .user)
        projects = list.compactMap { project in
            let skills = Self.scan(project.path + "/.claude/skills", source: .project(project.name))
            return skills.isEmpty ? nil : (project.name, skills)
        }
        loadingPlugins = true
        Task {
            // Skills de plugins: a lista que o próprio Claude Code monta (os caches de plugin têm versões repetidas).
            let commands = await Task.detached(priority: .utility) {
                ClaudeCLI.initialize(in: FileManager.default.homeDirectoryForCurrentUser.path)?["commands"] as? [[String: Any]] ?? []
            }.value
            var grouped: [String: [SkillEntry]] = [:]
            for command in commands {
                guard let name = command["name"] as? String, let colon = name.firstIndex(of: ":") else { continue }
                let plugin = String(name[..<colon])
                let description = (command["description"] as? String ?? "")
                    .replacingOccurrences(of: #" \((plugin|user|project)[^)]*\)$"#, with: "", options: .regularExpression)
                grouped[plugin, default: []].append(SkillEntry(name: String(name[name.index(after: colon)...]),
                                                               description: description, source: .plugin(plugin), file: nil))
            }
            plugins = grouped.keys.sorted().map { ($0, grouped[$0]!.sorted { $0.name < $1.name }) }
            loadingPlugins = false
        }
    }

    static func scan(_ folder: String, source: SkillEntry.Source) -> [SkillEntry] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).sorted().compactMap { name in
            let file = "\(folder)/\(name)/SKILL.md"
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
            let meta = frontmatter(text)
            return SkillEntry(name: meta["name"] ?? name, description: meta["description"] ?? "", source: source, file: file)
        }
    }

    /// Campos simples do cabeçalho `---` (name, description), inclusive descrições em várias linhas.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [:] }
        var result: [String: String] = [:]
        var key: String?
        for line in lines[1..<end] {
            if let match = line.firstMatch(of: #/^([A-Za-z_-]+):\s*(.*)$/#) {
                key = String(match.1)
                let value = String(match.2)
                result[key!] = value == ">" || value == "|" ? "" : value
            } else if let key, line.hasPrefix(" ") {
                result[key] = ((result[key] ?? "") + " " + line.trimmingCharacters(in: .whitespaces)).trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }

    /// Corpo do SKILL.md, sem o cabeçalho.
    static func body(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return text }
        return lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SkillsView: View {
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var config: ClaudeConfig
    @StateObject private var catalog = SkillCatalog()
    @State private var selection: SkillEntry.ID?
    @State private var creating = false

    var body: some View {
        HSplitView {
            MPList {
                MPListSection("Suas skills · todas as sessões")
                if catalog.user.isEmpty {
                    Text("Nenhuma ainda").font(.system(size: 12)).foregroundStyle(Theme.textMuted).padding(.horizontal, 10)
                }
                ForEach(catalog.user) { row($0) }
                ForEach(catalog.projects, id: \.project) { group in
                    MPListSection("Projeto \(group.project)")
                    ForEach(group.skills) { row($0) }
                }
                ForEach(catalog.plugins, id: \.plugin) { group in
                    let plugin = config.plugins.first(where: { $0.name.hasPrefix(group.plugin + "@") || $0.name == group.plugin })
                    MPListSection("Plugin \(group.plugin)", trailing: plugin.map { plugin in AnyView(
                        Toggle("", isOn: Binding(get: { plugin.enabled }, set: { config.setPlugin(plugin.name, enabled: $0) }))
                            .labelsHidden()
                            .help(plugin.enabled ? "Plugin ligado" : "Plugin desligado"))
                    })
                    ForEach(group.skills) { row($0) }
                }
                if catalog.loadingPlugins {
                    ProgressView { Text("Lendo skills de plugins…") }.padding(10)
                }
            }
            .frame(minWidth: 250, idealWidth: 300, maxWidth: 420)

            Group {
                if let skill = allSkills.first(where: { $0.id == selection }) {
                    SkillDetail(skill: skill) { reload() }.id(skill.id)
                } else {
                    MPEmptyState(title: "Selecione uma skill",
                                 message: "Skills ensinam o Claude a fazer algo do seu jeito. Ele usa sozinho quando a descrição combina com o pedido.") {
                        MPEmptyIcon(systemName: "wand.and.stars")
                    }
                }
            }
            .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.ink)
        }
        .navigationTitle("Skills")
        .toolbar {
            HStack(spacing: 6) {
                MPIconButton(icon: "arrow.clockwise", label: "Atualizar", glass: true) { reload() }
                Button { creating = true } label: { Label("Nova skill", systemImage: "plus") }
                    .buttonStyle(.mp(.primary, size: .sm))
            }
        }
        .mpSheet(isPresented: $creating) {
            NewSkillSheet(projects: store.projects) { file in
                reload()
                selection = file
            }
        }
        .onAppear(perform: reload)
    }

    private func row(_ skill: SkillEntry) -> some View {
        SkillRow(skill: skill, selected: selection == skill.id).onTapGesture { selection = skill.id }
    }

    private var allSkills: [SkillEntry] {
        catalog.user + catalog.projects.flatMap(\.skills) + catalog.plugins.flatMap(\.skills)
    }

    private func reload() {
        catalog.reload(projects: store.projects)
        config.reload()
    }
}

private struct SkillRow: View {
    let skill: SkillEntry
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(skill.name).font(Theme.mono(12, weight: .semibold))
            if !skill.description.isEmpty {
                Text(skill.description).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? AnyShapeStyle(Theme.sheenSoft) : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .contentShape(Rectangle())
    }
}

private struct SkillDetail: View {
    let skill: SkillEntry
    let changed: () -> Void
    @State private var text = ""
    @State private var saved = ""
    @State private var editing = false
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(skill.name).font(Theme.display(24))
                    Text(sourceLabel).font(Theme.mono(11)).foregroundStyle(Theme.textMuted)
                    if !skill.description.isEmpty {
                        Text(skill.description).foregroundStyle(Theme.textMuted).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let file = skill.file {
                    HStack {
                        Button(editing ? "Ver formatado" : "Editar") { editing.toggle() }
                        if editing {
                            Button("Salvar") { save(file) }
                                .buttonStyle(.mp(.primary))
                                .disabled(text == saved)
                        }
                        Button("Mostrar no Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
                        }
                        Spacer()
                        Button("Apagar…") { confirmingDelete = true }.buttonStyle(.mp(.danger))
                    }
                    .controlSize(.small)
                    if editing {
                        MPTextArea(text: $text, mono: true, height: 420)
                    } else {
                        MarkdownText(text: SkillCatalog.body(text))
                    }
                } else {
                    Text("Skill de plugin: liga e desliga junto com o plugin, no interruptor ao lado do nome dele na lista.")
                        .font(.callout).foregroundStyle(Theme.textMuted)
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .onAppear {
            if let file = skill.file, let content = try? String(contentsOfFile: file, encoding: .utf8) {
                text = content
                saved = content
            }
        }
        .mpDialog(isPresented: $confirmingDelete, title: "Apagar a skill \(skill.name)?",
                  message: "A pasta da skill vai para o Lixo; dá para recuperar de lá.", actions: [
                    MPDialogAction(label: "Cancelar"),
                    MPDialogAction(label: "Mover para o Lixo", variant: .danger) {
                        if let file = skill.file {
                            try? FileManager.default.trashItem(at: URL(fileURLWithPath: file).deletingLastPathComponent(), resultingItemURL: nil)
                            changed()
                        }
                    },
                  ])
    }

    private var sourceLabel: String {
        switch skill.source {
        case .user: "sua · \(skill.file.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "")"
        case .project(let name): "projeto \(name) · \(skill.file.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "")"
        case .plugin(let name): "plugin \(name)"
        }
    }

    private func save(_ file: String) {
        if (try? text.write(toFile: file, atomically: true, encoding: .utf8)) != nil {
            saved = text
            changed()
        }
    }
}

private struct NewSkillSheet: View {
    let projects: [Project]
    let created: (String) -> Void
    @State private var scope = "user"
    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nova skill").font(Theme.display(20))
            HStack(spacing: 8) {
                MPSectionLabel("Onde")
                MPSelect(icon: "folder", title: scope == "user" ? "Suas (todas as sessões)" : "Projeto \(projects.first { $0.path == scope }?.name ?? "")",
                         options: [.init(value: "user", label: "Suas (todas as sessões)")] + projects.map { .init(value: $0.path, label: "Projeto \($0.name)") },
                         selection: $scope)
            }
            TextField("nome-da-skill", text: $name).textFieldStyle(.mpMono)
            VStack(alignment: .leading, spacing: 4) {
                Text("Quando usar").font(.caption.weight(.semibold)).foregroundStyle(Theme.textMuted)
                TextField("Ex.: Use ao revisar migrations do Postgres…", text: $description, axis: .vertical)
                    .textFieldStyle(.mp).lineLimit(2...4)
                Text("O Claude decide usar a skill por esta descrição: diga o que ela faz e em que situação.")
                    .font(.caption).foregroundStyle(Theme.textFaint)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Instruções").font(.caption.weight(.semibold)).foregroundStyle(Theme.textMuted)
                MPTextArea(text: $instructions, mono: true, height: 180)
            }
            if let error { Text(error).foregroundStyle(Theme.danger).font(.callout) }
            HStack {
                Spacer()
                Button("Cancelar") { mpDismissOverlay() }.keyboardShortcut(.cancelAction)
                Button("Criar skill", action: create)
                    .buttonStyle(.mp(.primary))
                    .disabled(slug.isEmpty || description.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .mpDialogSurface(width: 560)
    }

    private var slug: String { Worktrees.slug(name) }

    private func create() {
        let root = scope == "user" ? SkillCatalog.userFolder : scope + "/.claude/skills"
        let folder = "\(root)/\(slug)"
        guard !FileManager.default.fileExists(atPath: folder) else {
            error = "Já existe uma skill com esse nome aí."
            return
        }
        let oneLine = description.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let content = "---\nname: \(slug)\ndescription: \(oneLine)\n---\n\n\(instructions.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try content.write(toFile: folder + "/SKILL.md", atomically: true, encoding: .utf8)
            created(folder + "/SKILL.md")
            mpDismissOverlay()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
