import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @ObservedObject var chat: ChatSession
    @EnvironmentObject private var usage: UsageIndex
    @EnvironmentObject private var store: ProjectStore
    @EnvironmentObject private var peak: PeakMonitor
    @State private var showingHistory = false
    @FocusState private var composerFocused: Bool
    @State private var pasteMonitor = ImagePasteMonitor()
    @State private var projectFiles: [String]?
    @State private var suggestionIndex = 0
    @State private var dismissedToken: String?
    @State private var dropTargeted = false
    /// Seguir o fim da conversa. Desliga quando você rola para cima; liga de novo quando volta ao fim.
    @State private var follow = true
    /// O marcador do fim está na tela.
    @State private var bottomVisible = false
    /// Primeira mensagem desenhada. Tudo dali para baixo é desenhado por inteiro, com a altura real: uma lista
    /// preguiçosa estima a altura do que está fora da tela e corrige no meio da rolagem, e era isso que fazia
    /// a conversa pular. As mais antigas entram pelo botão no topo, sem mexer no que está na tela.
    @State private var firstShown = 0
    private static let pageSize = 60
    @ObservedObject private var catalog = ModelCatalog.shared

    private var selectedModel: ModelOption? { catalog.models.first { $0.value == chat.model } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if chat.items.isEmpty {
                        if chat.isLoadingHistory {
                            HStack(spacing: 10) {
                                CrowView(mood: .working, scale: 1.5)
                                Text("Carregando a conversa…").foregroundStyle(Theme.textMuted)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 120)
                        } else {
                            EmptyChatHint(projectName: chat.project.name)
                        }
                    }
                    let start = min(firstShown, chat.items.count)
                    if start > 0 {
                        Button {
                            let anchor = chat.items[start].id
                            firstShown = max(0, start - Self.pageSize)
                            // As anteriores entram acima: volta a mostrar a mesma mensagem no topo.
                            DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
                        } label: {
                            Label("Mostrar \(min(start, Self.pageSize)) mensagens anteriores", systemImage: "arrow.up")
                        }
                        .buttonStyle(.mp(.ghost, size: .sm))
                        .frame(maxWidth: .infinity)
                    }
                    ForEach(chat.items[start...]) { item in
                        // .equatable(): enquanto o Claude escreve, só a mensagem que cresce é redesenhada (sem isso,
                        // cada pedacinho de texto refazia as ~60 mensagens da tela, Markdown incluído).
                        ChatItemView(item: item, chat: chat).equatable().id(item.id)
                    }
                    if chat.isRunning {
                        HStack(spacing: 10) {
                            CrowView(mood: chat.pendingPermissions > 0 ? .waiting : .working, scale: 1.5)
                            Text(chat.pendingPermissions > 0 ? "Esperando sua permissão…" : "Claude está trabalhando…")
                                .font(.callout)
                                .foregroundStyle(chat.pendingPermissions > 0 ? AnyShapeStyle(Theme.ember) : AnyShapeStyle(Theme.textMuted))
                        }
                        .id("running")
                    } else if !chat.backgroundTasks.isEmpty {
                        BackgroundTasksNote(tasks: chat.backgroundTasks)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .modifier(TrackBottomVisibility(visible: $bottomVisible))
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 12)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .modifier(InitialBottomAnchor())
            .modifier(TrackUserScroll(started: { follow = false }) { follow = bottomVisible })
            .background(ScrollWheelWatcher { follow = false })
            .modifier(ScrollProbe())
            .onChange(of: bottomVisible) { _, visible in if visible { follow = true } }
            // O composer flutua sobre a conversa (vidro), que rola por baixo dele.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 6) {
                    if !follow {
                        Button {
                            follow = true
                            scrollToEnd(proxy)
                        } label: {
                            Label("Ir para o fim", systemImage: "arrow.down")
                                .font(.callout)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .glassSurface(cornerRadius: 14)
                        }
                        .buttonStyle(.plain)
                    }
                    composer
                }
            }
            // Mensagem nova só puxa a rolagem se você já estava no fim (lendo lá em cima, fica onde está).
            .onChange(of: chat.items.count) { oldCount, newCount in
                // Conversa (re)carregada: começa pelas últimas. Mensagem nova não muda o começo (nada some lá em cima).
                if newCount < oldCount || oldCount == 0 || newCount - oldCount > 20 {
                    firstShown = max(0, newCount - Self.pageSize)
                    follow = true
                }
                if follow { scrollToEnd(proxy) }
            }
            .onChange(of: chat.items.last) { _, _ in
                if follow { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear {
                firstShown = max(0, chat.items.count - Self.pageSize)
                scrollToEnd(proxy)
            }
        }
        .mpSheet(isPresented: $showingHistory) {
            ConversationPicker(project: chat.project) { session in
                chat.resume(sessionId: session.id, transcript: session.transcript)
                mpDismissOverlay()
            }
        }
        .onAppear {
            if chat.items.isEmpty, chat.sessionId != nil {
                let id = chat.sessionId
                usage.read({ worker in id.flatMap(worker.transcript(session:)) }) { transcript in
                    chat.loadHistoryIfNeeded(transcript: transcript)
                }
            }
            composerFocused = true
            pasteMonitor.install { [chat] in
                let images = PasteboardImages.read()
                guard !images.isEmpty else { return false }
                chat.attachments += images
                return true
            }
        }
        .onDisappear { pasteMonitor.remove() }
        .onChange(of: composerFocused) { _, focused in pasteMonitor.active = focused }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let completion, !completion.items.isEmpty {
                SuggestionList(items: completion.items, selected: min(suggestionIndex, completion.items.count - 1)) { item in
                    accept(item, in: completion)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                if !chat.attachments.isEmpty {
                    AttachmentStrip(images: chat.attachments) { image in
                        chat.attachments.removeAll { $0.id == image.id }
                    }
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $chat.draft)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 20, maxHeight: 200)
                        .fixedSize(horizontal: false, vertical: true)
                        .focused($composerFocused)
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.shift) { return .ignored }
                            if acceptSelected() { return .handled }
                            submit()
                            return .handled
                        }
                        .onKeyPress(.tab, phases: .down) { press in
                            // ⇧⇥ alterna o modo de permissão, como no Claude Code do terminal.
                            if press.modifiers.contains(.shift) {
                                chat.setPermissionMode(chat.permissionMode.next)
                                return .handled
                            }
                            return acceptSelected() ? .handled : .ignored
                        }
                        .onKeyPress(characters: ["\u{19}"], phases: .down) { _ in
                            chat.setPermissionMode(chat.permissionMode.next)
                            return .handled
                        }
                        .onKeyPress(.upArrow) { moveSelection(-1) ? .handled : .ignored }
                        .onKeyPress(.downArrow) { moveSelection(1) ? .handled : .ignored }
                        .onKeyPress(.escape) {
                            guard let completion, !completion.items.isEmpty else { return .ignored }
                            dismissedToken = completion.token
                            return .handled
                        }
                }

                HStack(spacing: 2) {
                    MPIconButton(icon: "paperclip", label: "Anexar imagem (ou cole com ⌘V, ou arraste para cá)", action: chooseImages)

                    MPSelect(icon: chat.permissionMode.icon, title: chat.permissionMode.label,
                             highlighted: chat.permissionMode == .auto,
                             help: "\(chat.permissionMode.detail) ⇧⇥ alterna o modo.",
                             options: PermissionMode.allCases.map { .init(value: $0, label: $0.label, detail: $0.detail) },
                             selection: Binding(get: { chat.permissionMode }, set: { chat.setPermissionMode($0) }))

                    // Aliases ("opus", "sonnet"…) apontam sempre para a versão mais nova; IDs completos fixam uma versão.
                    MPSelect(icon: "sparkle", title: selectedModel?.name ?? chat.model, help: selectedModel?.detail ?? "Modelo",
                             options: catalog.models.filter { !$0.value.hasPrefix("claude-") }.map { .init(value: $0.value, label: $0.name, detail: $0.detail.isEmpty ? nil : $0.detail) },
                             extra: pinnedModelEntries,
                             selection: Binding(get: { chat.model }, set: { chat.setModel($0) }))

                    if let efforts = selectedModel?.efforts, !efforts.isEmpty {
                        MPSelect(icon: "gauge.with.dots.needle.50percent",
                                 title: chat.effort.map(ModelCatalog.effortLabel) ?? "Esforço padrão",
                                 help: "Quanto o Claude pensa antes de agir. Mudar no meio da conversa reinicia o processo; a conversa continua.",
                                 options: [.init(value: nil, label: "Esforço padrão")] + efforts.map { .init(value: Optional($0), label: ModelCatalog.effortLabel($0)) },
                                 selection: Binding(get: { chat.effort }, set: { chat.setEffort($0) }))
                    }

                    MPMenuButton(entries: conversationEntries) {
                        HStack(spacing: 5) {
                            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 11))
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.6)
                        }
                        .foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .contentShape(Capsule())
                    }
                    .fixedSize()
                    .help("Conversas e tarefas")

                    Spacer(minLength: 8)

                    if peak.isPeak, let end = peak.boundary {
                        // Onde os tokens são gastos: lembra que agora a janela de 5h anda mais rápido.
                        Label("Pico até \(end.formatted(date: .omitted, time: .shortened))", systemImage: "flame.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.ember)
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(Theme.ember.opacity(0.14), in: Capsule())
                            .help("Horário de pico do Claude: a janela de 5h do plano é consumida mais rápido. Tarefas pesadas e workflows rendem mais depois.")
                            .padding(.trailing, 4)
                    }

                    if chat.totalCost > 0 {
                        Text(Format.usd(chat.totalCost))
                            .font(Theme.mono(11)).foregroundStyle(Theme.textMuted)
                            .help("Custo desta conversa (equivalente em API)")
                            .padding(.trailing, 6)
                    }

                    let empty = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.attachments.isEmpty
                    // Trabalhando com algo escrito: o botão envia (o Claude lê a mensagem no meio do que está fazendo).
                    // Sem nada escrito: o botão para. ⌘. sempre para.
                    if chat.isRunning && empty {
                        Button(action: chat.interrupt) {
                            Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Theme.ember, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(".", modifiers: .command)
                        .help("Parar (⌘.) · aperte de novo para encerrar à força")
                    } else {
                        Button(action: submit) {
                            Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(empty ? AnyShapeStyle(Theme.quill) : AnyShapeStyle(Theme.iridescent), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(empty)
                        .help(chat.isRunning ? "Enviar agora: o Claude lê no meio do que está fazendo (⏎) · ⌘. para"
                                             : "Enviar (⏎) · ⇧⏎ quebra linha · @ arquivo · / comando")
                        .background {
                            // ⌘. continua parando mesmo com texto escrito (o botão visível aqui é o de enviar).
                            if chat.isRunning {
                                Button("", action: chat.interrupt).keyboardShortcut(".", modifiers: .command).opacity(0)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .glassSurface(cornerRadius: 20)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(dropTargeted ? AnyShapeStyle(Theme.iridescent) : AnyShapeStyle(Theme.quill.opacity(0.7)),
                                  lineWidth: dropTargeted ? 2 : 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
            .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted, perform: handleDrop)
            .onChange(of: chat.draft) { _, _ in
                suggestionIndex = 0
                if completion?.kind == .file, projectFiles == nil { loadProjectFiles() }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        // A conversa some suavemente ao chegar no composer, em vez de aparecer atrás e abaixo dele.
        .background(alignment: .bottom) {
            Rectangle().fill(Theme.ink)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.35)],
                                     startPoint: .top, endPoint: .bottom))
                .padding(.top, -24)
                .allowsHitTesting(false)
        }
    }

    /// Na abertura o layout ainda está assentando: repete até o marcador do fim aparecer de verdade.
    private func scrollToEnd(_ proxy: ScrollViewProxy, attempt: Int = 0) {
        proxy.scrollTo("bottom", anchor: .bottom)
        guard attempt < 8 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if follow && (!bottomVisible || attempt < 1) { scrollToEnd(proxy, attempt: attempt + 1) }
        }
    }

    /// Versões fixas dos modelos (IDs completos), numa seção do menu de modelo.
    private var pinnedModelEntries: [MPMenuEntry] {
        let pinned = catalog.models.filter { $0.value.hasPrefix("claude-") }
        guard !pinned.isEmpty else { return [] }
        return [.divider, .header("Outras versões")] + pinned.map { model in
            .item(model.name, checked: chat.model == model.value) { chat.setModel(model.value) }
        }
    }

    private func conversationEntries() -> [MPMenuEntry] {
        var entries: [MPMenuEntry] = [
            .item("Dividir em tarefas paralelas", icon: "square.split.2x2", disabled: chat.isRunning || chat.items.isEmpty) { chat.send(TaskPlan.request) },
            .divider,
            .item("Ferramentas MCP", detail: "Notion, ClickUp, Figma… Desligado, a conversa fica mais leve.",
                  checked: chat.usesMCP) { chat.setUsesMCP(!chat.usesMCP) },
            .divider,
        ]
        if chat.project.isPinned {
            // A conversa fixada é sempre a mesma: trocar de conversa aqui faria você perdê-la.
            entries.append(.item("Desafixar conversa", icon: "pin.slash") { store.unpin(chat.project.id) })
        } else {
            entries += [
                .item("Fixar esta conversa", icon: "pin", disabled: chat.sessionId == nil || chat.isRunning || chat.project.isTask) { pinCurrent() },
                .item("Nova conversa", icon: "plus.bubble") { chat.newConversation() },
                .item("Abrir conversa anterior…", icon: "clock.arrow.circlepath") { showingHistory = true },
            ]
        }
        return entries
    }

    /// Fixa a conversa atual: ela ganha lugar próprio na barra lateral e o chat do projeto começa uma nova.
    private func pinCurrent() {
        guard let sessionId = chat.sessionId else { return }
        let path = chat.project.path
        usage.read({ $0.sessions(inProject: path, limit: 400) }) { sessions in
            let title = sessions.first { $0.id == sessionId }?.displayTitle ?? "Conversa fixada"
            guard let pinned = store.pin(sessionId: sessionId, title: title, in: chat.project) else { return }
            chat.newConversation()
            store.hubSelection = .project(pinned.id)
        }
    }

    /// Também com o Claude trabalhando: ele lê a mensagem no próximo passo, no mesmo turno.
    private func submit() {
        let text = chat.draft
        chat.draft = ""
        chat.send(text)
    }

    // MARK: Autocompletar (@ arquivo, / comando)

    private var completion: Completion? {
        let draft = chat.draft
        let completion: Completion?
        if draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) {
            let names = SlashCommands.matches(String(draft.dropFirst()), in: chat.slashCommands)
            completion = Completion(kind: .command, token: draft, items: names.map {
                Suggestion(insert: "/\($0) ", title: "/\($0)", subtitle: SlashCommands.description($0), icon: "command")
            })
        } else {
            let start = draft.lastIndex(where: \.isWhitespace).map { draft.index(after: $0) } ?? draft.startIndex
            let token = String(draft[start...])
            guard token.hasPrefix("@") else { return nil }
            let paths = ProjectFileIndex.matches(String(token.dropFirst()), in: projectFiles ?? [])
            completion = Completion(kind: .file, token: token, items: paths.map {
                Suggestion(insert: "@\($0) ", title: $0, subtitle: nil, icon: $0.hasSuffix("/") ? "folder" : "doc")
            })
        }
        return completion?.token == dismissedToken ? nil : completion
    }

    private func accept(_ item: Suggestion, in completion: Completion) {
        chat.draft = String(chat.draft.dropLast(completion.token.count)) + item.insert
        dismissedToken = nil
        composerFocused = true
    }

    private func acceptSelected() -> Bool {
        guard let completion, !completion.items.isEmpty else { return false }
        accept(completion.items[min(suggestionIndex, completion.items.count - 1)], in: completion)
        return true
    }

    private func moveSelection(_ delta: Int) -> Bool {
        guard let completion, !completion.items.isEmpty else { return false }
        suggestionIndex = (min(suggestionIndex, completion.items.count - 1) + delta + completion.items.count) % completion.items.count
        return true
    }

    private func loadProjectFiles() {
        projectFiles = []
        let root = chat.project.path
        Task { projectFiles = await ProjectFileIndex.load(root) }
    }

    // MARK: Imagens

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.prompt = "Anexar"
        guard panel.runModal() == .OK else { return }
        chat.attachments += panel.urls.compactMap(ChatImageEncoder.make(file:))
    }

    /// Imagens viram anexo; outros arquivos viram menção `@caminho` no texto.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let root = chat.project.path
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    if ChatImageEncoder.isImage(url) {
                        let image = ChatImageEncoder.make(file: url)
                        DispatchQueue.main.async { if let image { chat.attachments.append(image) } }
                    } else {
                        let path = url.path.hasPrefix(root + "/") ? String(url.path.dropFirst(root.count + 1)) : url.path
                        DispatchQueue.main.async {
                            let separator = chat.draft.isEmpty || chat.draft.hasSuffix(" ") ? "" : " "
                            chat.draft += "\(separator)@\(path) "
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    let image = data.flatMap(ChatImageEncoder.make(data:))
                    DispatchQueue.main.async { if let image { chat.attachments.append(image) } }
                }
            }
        }
        return true
    }
}

private struct Completion {
    enum Kind { case command, file }
    let kind: Kind
    /// Trecho digitado que a sugestão substitui ("/comp", "@src/us").
    let token: String
    let items: [Suggestion]
}

private struct Suggestion: Identifiable {
    var id: String { insert }
    let insert: String
    let title: String
    let subtitle: String?
    let icon: String
}

private struct SuggestionList: View {
    let items: [Suggestion]
    let selected: Int
    let pick: (Suggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    Image(systemName: item.icon).foregroundStyle(Theme.textMuted).frame(width: 16)
                    Text(item.title).lineLimit(1).truncationMode(.head)
                    if let subtitle = item.subtitle {
                        Text(subtitle).foregroundStyle(Theme.textMuted).lineLimit(1)
                    }
                    Spacer()
                    if index == selected { Text("⇥").font(.caption).foregroundStyle(Theme.textFaint) }
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(index == selected ? Theme.sheenSoft : .clear)
                .contentShape(Rectangle())
                .onTapGesture { pick(item) }
            }
        }
        .padding(.vertical, 4)
        .glassSurface(cornerRadius: 12)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.quill.opacity(0.7)))
    }
}

private struct AttachmentStrip: View {
    let images: [ChatImage]
    let remove: (ChatImage) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { image in
                    ImageThumbnail(image: image, height: 64)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                remove(image)
                            } label: {
                                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .padding(3)
                        }
                }
            }
        }
    }
}

/// Miniatura clicável: abre a imagem no Preview.
struct ImageThumbnail: View {
    let image: ChatImage
    let height: CGFloat

    var body: some View {
        if let nsImage = NSImage(data: image.data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: height * 3, maxHeight: height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.quill))
                .onTapGesture { image.openInPreview() }
                .help("Abrir no Preview")
        }
    }
}

/// Intercepta ⌘V quando o composer está focado e há imagem no clipboard; texto segue o caminho normal.
@MainActor
final class ImagePasteMonitor {
    var active = false
    private var monitor: Any?

    func install(_ handler: @escaping @MainActor () -> Bool) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v" else { return event }
            let consumed = MainActor.assumeIsolated {
                guard self?.active == true, NSApp.keyWindow?.firstResponder is NSTextView else { return false }
                return handler()
            }
            return consumed ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct EmptyChatHint: View {
    let projectName: String

    var body: some View {
        VStack(spacing: 14) {
            CrowView(mood: .idle, scale: 5)
            Text("O que vamos fazer em \(projectName)?")
                .font(Theme.display(26))
                .multilineTextAlignment(.center)
            Text("Peça uma mudança, uma investigação ou uma revisão. Quando o Claude precisar editar ou rodar algo, ele pede sua permissão aqui mesmo.")
                .multilineTextAlignment(.center).foregroundStyle(Theme.textMuted)
                .frame(maxWidth: 440)
            HStack(spacing: 16) {
                Hint(key: "⌘V", text: "cola um print")
                Hint(key: "@", text: "cita um arquivo")
                Hint(key: "/", text: "roda um comando")
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    private struct Hint: View {
        let key: String
        let text: String

        var body: some View {
            HStack(spacing: 6) {
                Text(key).font(Theme.mono(11, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.plumageRaised, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.quill))
                Text(text).font(.callout).foregroundStyle(Theme.textMuted)
            }
        }
    }
}

/// No marcador do fim da conversa: está na tela? (macOS 15+; antes, considera sempre que sim.)
/// Medir pela altura do conteúdo não funciona numa lista preguiçosa, onde ela é estimada.
private struct TrackBottomVisibility: ViewModifier {
    @Binding var visible: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollVisibilityChange(threshold: 0.01) { isVisible in
                if isVisible != visible { visible = isVisible }
            }
        } else {
            content.onAppear { visible = true }
        }
    }
}

/// O turno acabou, mas o Claude deixou agentes rodando: ele volta sozinho a esta conversa quando terminarem.
private struct BackgroundTasksNote: View {
    let tasks: [BackgroundTask]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CrowView(mood: .working, scale: 1.5)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout).foregroundStyle(Theme.textMuted)
                ForEach(tasks.prefix(4)) { task in
                    Text("· \(task.description)").font(.caption).foregroundStyle(Theme.textFaint).lineLimit(1)
                }
                Text("O Claude continua sozinho quando terminar\(tasks.count == 1 ? "" : "em"). Pode fechar o MacPet.")
                    .font(.caption).foregroundStyle(Theme.textFaint)
            }
        }
    }

    private var title: String {
        let agents = tasks.filter(\.isAgent).count
        let commands = tasks.count - agents
        let parts = [agents > 0 ? "\(agents) agente\(agents == 1 ? "" : "s")" : nil,
                     commands > 0 ? "\(commands) comando\(commands == 1 ? "" : "s")" : nil].compactMap { $0 }
        return parts.joined(separator: " e ") + " em segundo plano"
    }
}

/// Você rolou para cima sobre a conversa (roda do mouse ou trackpad): para de seguir o fim na hora.
/// Olha o evento de entrada, não a posição: enquanto a conversa carrega, o SwiftUI move a posição sozinho.
private struct ScrollWheelWatcher: NSViewRepresentable {
    let scrolledUp: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak coordinator = context.coordinator] event in
            coordinator?.handle(event)
            return event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.scrolledUp = scrolledUp
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(scrolledUp: scrolledUp) }

    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var scrolledUp: () -> Void

        init(scrolledUp: @escaping () -> Void) { self.scrolledUp = scrolledUp }

        func handle(_ event: NSEvent) {
            guard event.scrollingDeltaY > 0, let view, event.window === view.window,
                  view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return }
            scrolledUp()
        }
    }
}

/// Começa no fim da conversa, sem reajustar a rolagem depois (o conteúdo crescendo não puxa a tela).
private struct InitialBottomAnchor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            content
        }
    }
}

/// Depuração: com `defaults write app.macpet debug.scrollLog -bool YES`, registra a posição da
/// rolagem em ~/.macpet/scroll.log (usado pelo macpet://scrolltest para achar saltos).
private struct ScrollProbe: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *), UserDefaults.standard.bool(forKey: "debug.scrollLog") {
            content.onScrollGeometryChange(for: [Double].self) { geometry in
                [geometry.contentOffset.y, geometry.contentSize.height]
            } action: { _, value in
                let line = String(format: "%.3f %.1f %.1f\n", Date().timeIntervalSince1970, value[0], value[1])
                let url = MacPetPaths.support.appendingPathComponent("scroll.log")
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(Data(line.utf8))
                    try? handle.close()
                } else {
                    try? line.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        } else {
            content
        }
    }
}

/// Quando você termina de rolar (com o trackpad ou a barra), decide se continua seguindo o fim.
/// O conteúdo crescendo sozinho (streaming) não conta como rolagem sua.
private struct TrackUserScroll: ViewModifier {
    var started: () -> Void = {}
    let ended: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollPhaseChange { oldPhase, newPhase in
                // Começou a rolar: para de seguir na hora (uma mensagem nova não puxa a tela no meio do gesto).
                if newPhase == .interacting, oldPhase == .idle { started() }
                if newPhase == .idle, oldPhase == .interacting || oldPhase == .decelerating { ended() }
            }
        } else {
            content
        }
    }
}

/// Abre a aba Agentes focando a chamada (tool_use) que disparou o agente/workflow.
struct OpenAgentAction {
    let open: (String) -> Void
}

private struct OpenAgentKey: EnvironmentKey {
    static let defaultValue: OpenAgentAction? = nil
}

extension EnvironmentValues {
    var openAgent: OpenAgentAction? {
        get { self[OpenAgentKey.self] }
        set { self[OpenAgentKey.self] = newValue }
    }
}

/// Um item do chat. `chat` é nil quando só exibe histórico (ex.: execução de um subagente).
struct ChatItemView: View, Equatable {
    let item: ChatItem
    let chat: ChatSession?

    static func == (lhs: ChatItemView, rhs: ChatItemView) -> Bool {
        lhs.item == rhs.item && lhs.chat === rhs.chat
    }

    var body: some View {
        switch item.kind {
        case .user(let text, let images):
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 6) {
                    if !images.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(images) { ImageThumbnail(image: $0, height: 140) }
                        }
                    }
                    if !text.isEmpty {
                        let tint = chat.map { ProjectColor.for($0.project).color } ?? Theme.sheen
                        Text(text)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(0.28)))
                    }
                }
            }
        case .assistant(let text):
            if let split = TaskPlan.split(text) {
                // A resposta trouxe um plano de tarefas paralelas: vira um card para lançar.
                VStack(alignment: .leading, spacing: 12) {
                    if !split.before.isEmpty { MarkdownText(text: split.before) }
                    if let plan = split.plan, let chat {
                        TaskPlanCard(plan: plan, chat: chat)
                    } else if split.pending {
                        HStack(spacing: 10) {
                            CrowView(mood: .working, scale: 1.5)
                            Text("Montando o plano de tarefas…").foregroundStyle(Theme.textMuted)
                        }
                    } else {
                        MarkdownText(text: text)
                    }
                    if !split.after.isEmpty { MarkdownText(text: split.after) }
                }
            } else {
                MarkdownText(text: text)
            }
        case .tool(let call):
            ToolCardView(call: call)
        case .permission(let request):
            if let chat {
                PermissionCardView(request: request, chat: chat)
            } else {
                ToolCardView(call: request.tool)
            }
        case .result(let cost, let seconds, let isError):
            // Fim do turno: uma linha discreta, não um card.
            HStack(spacing: 10) {
                Rectangle().fill(Theme.quill).frame(height: 1)
                Text("\(isError ? "terminou com erro" : "pronto") · \(AgentFormat.duration(seconds)) · \(Format.usd(cost))")
                    .font(Theme.mono(10))
                    .foregroundStyle(isError ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(Theme.textFaint))
                    .fixedSize()
                Rectangle().fill(Theme.quill).frame(height: 1)
            }
            .padding(.vertical, 4)
        case .notice(let text):
            Label(text, systemImage: "info.circle")
                .font(.callout).foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Theme.plumage, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

// MARK: - Ferramentas

private struct ToolCardView: View {
    let call: ToolCall
    @State private var expanded = false
    @Environment(\.openAgent) private var openAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon).font(.system(size: 11)).frame(width: 16)
                        .foregroundStyle(call.isError ? AnyShapeStyle(.red) : AnyShapeStyle(Theme.sheen))
                    Text(call.name).font(Theme.mono(11.5, weight: .semibold))
                    Text(call.summary).font(.callout).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if call.result == nil { ProgressView().controlSize(.mini) }
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textFaint)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if call.spawnsAgents {
                HStack(spacing: 8) {
                    if call.result == nil {
                        Text(call.childSteps > 0 ? "\(call.childSteps) ações" : "começando…").foregroundStyle(Theme.sheen)
                        if let last = call.childLast {
                            Text(last).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    Spacer()
                    if let openAgent {
                        Button(call.name == "Workflow" ? "Ver workflow" : "Ver agente") { openAgent.open(call.id) }
                            .controlSize(.small)
                    }
                }
                .font(.caption)
            }

            if expanded || call.name == "TodoWrite" || call.name == "ExitPlanMode" {
                ToolDetails(call: call, showResult: expanded)
            } else if !call.edits.isEmpty {
                // Edições aparecem resumidas mesmo fechadas: é o que mais importa revisar.
                DiffLines(old: call.edits.first?.old ?? "", new: call.edits.first?.new ?? "", maxLines: 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.plumage, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(call.isError ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(Theme.quill)))
    }

    private var icon: String {
        switch call.name {
        case "Bash": "terminal"
        case "Edit", "MultiEdit": "pencil"
        case "Write": "doc.badge.plus"
        case "Read": "doc.text"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Task", "Agent": "person.2"
        case "TodoWrite": "checklist"
        case "ExitPlanMode": "list.bullet.clipboard"
        default: "wrench.and.screwdriver"
        }
    }
}

private struct ToolDetails: View {
    let call: ToolCall
    let showResult: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(call.edits.enumerated()), id: \.offset) { _, edit in
                DiffLines(old: edit.old, new: edit.new, maxLines: 200)
            }
            if let detail = call.detail, !detail.isEmpty {
                if call.name == "ExitPlanMode" {
                    MarkdownText(text: detail)
                } else {
                    CodeBox(text: detail, maxLines: call.name == "Write" ? 40 : 30)
                }
            }
            if showResult, let result = call.result, !result.isEmpty {
                Text("Resultado").font(.caption).foregroundStyle(Theme.textMuted)
                CodeBox(text: result, maxLines: 40)
            }
        }
    }
}

struct CodeBox: View {
    let text: String
    let maxLines: Int

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        let shown = lines.prefix(maxLines).joined(separator: "\n") + (lines.count > maxLines ? "\n… (+\(lines.count - maxLines) linhas)" : "")
        ScrollView(.horizontal) {
            Text(shown)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
        }
        .background(Theme.ink.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Trecho antigo em vermelho e novo em verde (Edit/MultiEdit).
struct DiffLines: View {
    let old: String
    let new: String
    let maxLines: Int

    var body: some View {
        let removed = old.isEmpty ? [] : old.components(separatedBy: "\n").map { ("-", $0) }
        let added = new.isEmpty ? [] : new.components(separatedBy: "\n").map { ("+", $0) }
        let lines = Array((removed + added).prefix(maxLines))
        // Linhas longas quebram (sem rolagem lateral), e o fundo ocupa a largura toda.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 6) {
                    Text(line.0).foregroundStyle(line.0 == "-" ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(Theme.success))
                    Text(line.1).fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.mono(11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .background(line.0 == "-" ? Theme.diffRemove : Theme.diffAdd)
            }
            if removed.count + added.count > maxLines {
                Text("… (+\(removed.count + added.count - maxLines) linhas)")
                    .font(.caption2).foregroundStyle(Theme.textMuted).padding(.horizontal, 8).padding(.vertical, 3)
            }
        }
        .textSelection(.enabled)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct PermissionCardView: View {
    let request: PermissionRequest
    let chat: ChatSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: request.status == .pending ? "hand.raised.fill" : request.status == .allowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(request.status == .pending ? AnyShapeStyle(Theme.ember) : request.status == .allowed ? AnyShapeStyle(Theme.success) : AnyShapeStyle(Theme.danger))
                Text(title).fontWeight(.semibold)
                Text(request.tool.summary).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
            }
            .font(.callout)

            ToolDetails(call: request.tool, showResult: false)

            if request.status == .pending {
                HStack {
                    Button("Permitir") { chat.respond(to: request.requestId, allow: true) }
                        .buttonStyle(.mp(.primary))
                        .keyboardShortcut(.return, modifiers: .command)
                    if let label = request.suggestionLabel {
                        Button(label) { chat.respond(to: request.requestId, allow: true, applySuggestion: true) }
                    }
                    Button("Negar", role: .destructive) { chat.respond(to: request.requestId, allow: false) }
                    Spacer()
                    Text("⌘⏎ permite").font(.caption2).foregroundStyle(Theme.textFaint)
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(Theme.ember.opacity(request.status == .pending ? 0.10 : 0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.ember.opacity(request.status == .pending ? 0.55 : 0.15)))
    }

    private var title: String {
        switch request.status {
        case .pending: request.tool.name == "ExitPlanMode" ? "Aprovar o plano?" : "Permitir \(request.tool.name)?"
        case .allowed: "Permitido: \(request.tool.name)"
        case .denied: "Negado: \(request.tool.name)"
        }
    }
}

// MARK: - Conversas anteriores

private struct ConversationPicker: View {
    let project: Project
    let onPick: (SessionSummary) -> Void
    @EnvironmentObject private var usage: UsageIndex
    @State private var sessions: [SessionSummary] = []
    @State private var loaded = false

    var body: some View {
        MPDialogCard(title: "Conversas em \(project.name)", width: 560, actions: [MPDialogAction(label: "Fechar")]) {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(sessions) { session in
                        Button {
                            onPick(session)
                        } label: {
                            MPListRow(title: session.displayTitle,
                                      subtitle: Format.relative(session.lastActivity),
                                      meta: Format.usd(session.cost), titleLines: 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 380)
            .overlay {
                if !loaded {
                    ProgressView { Text("Lendo conversas…") }
                } else if sessions.isEmpty {
                    MPEmptyState(title: "Nenhuma conversa nesta pasta",
                                 message: "Só aparecem conversas do Claude Code abertas em \(project.path) ou numa subpasta. O Claude Code apaga as conversas paradas há mais tempo que o configurado em cleanupPeriodDays (padrão: 30 dias).") {
                        MPEmptyIcon(systemName: "bubble.left.and.bubble.right")
                    }
                }
            }
        }
        .onAppear {
            let path = project.path
            usage.read({ worker in worker.sessions(inProject: path) }) {
                sessions = $0
                loaded = true
            }
        }
    }
}
