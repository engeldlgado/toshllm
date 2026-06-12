import SwiftUI

// MARK: - Model

struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    let role: String          // user | assistant
    var content: String
    var date = Date()
    var genSpeed: Double?     // t/s for this response

    /// Splits the <think>…</think> block from the visible content.
    var parts: (thinking: String?, body: String) {
        guard role == "assistant", content.hasPrefix("<think>") else { return (nil, content) }
        if let end = content.range(of: "</think>") {
            let think = String(content[content.index(content.startIndex, offsetBy: 7)..<end.lowerBound])
            let body = String(content[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (think.trimmingCharacters(in: .whitespacesAndNewlines), body)
        }
        return (String(content.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines), "")
    }
}

struct Conversation: Identifiable, Codable {
    var id = UUID()
    var title: String
    var messages: [ChatMessage] = []
    var created = Date()
    var updated = Date()
}

// MARK: - Store with persistence and streaming

@MainActor
final class ChatStore: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var currentID: UUID?
    @Published var generating = false
    @Published var liveSpeed: Double?
    @Published var lastError: String?
    /// Tokens of context consumed by the last exchange (prompt + completion),
    /// reported by the server. Drives the context-usage bar.
    @Published var contextUsed: Int?

    private var task: Task<Void, Never>?

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ToshLLM")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("conversations.json")
    }

    init() {
        load()
        if conversations.isEmpty { newConversation() }
        currentID = conversations.first?.id
    }

    var currentIndex: Int? { conversations.firstIndex { $0.id == currentID } }
    var current: Conversation? { currentIndex.map { conversations[$0] } }

    func newConversation() {
        let c = Conversation(title: "")
        conversations.insert(c, at: 0)
        currentID = c.id
        lastError = nil
        contextUsed = nil
    }

    func delete(_ c: Conversation) {
        if generating && c.id == currentID { stop() }
        conversations.removeAll { $0.id == c.id }
        if currentID == c.id { currentID = conversations.first?.id }
        if conversations.isEmpty { newConversation() }
        save()
    }

    func displayTitle(_ c: Conversation) -> String {
        if !c.title.isEmpty { return c.title }
        if let first = c.messages.first(where: { $0.role == "user" }) {
            return String(first.content.prefix(40))
        }
        return "…"
    }

    // MARK: sending

    func send(text: String, port: Int, temperature: Double, maxTokens: Int, system: String, thinking: Bool) {
        guard !generating, let i = currentIndex else { return }
        lastError = nil
        conversations[i].messages.append(ChatMessage(role: "user", content: text))
        if conversations[i].title.isEmpty {
            conversations[i].title = String(text.prefix(40))
        }
        stream(into: i, port: port, temperature: temperature, maxTokens: maxTokens, system: system, thinking: thinking)
    }

    func regenerate(port: Int, temperature: Double, maxTokens: Int, system: String, thinking: Bool) {
        guard !generating, let i = currentIndex,
              conversations[i].messages.last?.role == "assistant" else { return }
        conversations[i].messages.removeLast()
        stream(into: i, port: port, temperature: temperature, maxTokens: maxTokens, system: system, thinking: thinking)
    }

    private func stream(into i: Int, port: Int, temperature: Double, maxTokens: Int, system: String, thinking: Bool) {
        generating = true
        liveSpeed = nil

        // History without reasoning blocks (saves context)
        var history: [[String: String]] = []
        if !system.trimmingCharacters(in: .whitespaces).isEmpty {
            history.append(["role": "system", "content": system])
        }
        history += conversations[i].messages.map { m in
            ["role": m.role, "content": m.role == "assistant" ? m.parts.body : m.content]
        }

        conversations[i].messages.append(ChatMessage(role: "assistant", content: ""))

        task = Task { [weak self] in
            var nTokens = 0
            var tFirst: Date?
            // Local accumulation; the UI is updated at ~25 Hz instead of per
            // token, so long responses don't re-render thousands of times.
            var reasoning = ""
            var visible = ""
            var lastFlush = Date.distantPast
            var usage: (prompt: Int, completion: Int)?

            func composed() -> String {
                guard !reasoning.isEmpty else { return visible }
                return "<think>" + reasoning + (visible.isEmpty ? "" : "</think>" + visible)
            }

            @MainActor func flush(force: Bool = false) {
                let now = Date()
                guard force || now.timeIntervalSince(lastFlush) > 0.04 else { return }
                lastFlush = now
                self?.setLast(composed())
                if let start = tFirst {
                    let dt = now.timeIntervalSince(start)
                    if dt > 0.4 { self?.liveSpeed = Double(nTokens) / dt }
                }
            }

            do {
                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let key = ServerSettings.activeAPIKey() {
                    req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
                }
                var body: [String: Any] = [
                    "messages": history,
                    "stream": true,
                    "temperature": temperature,
                    "max_tokens": maxTokens,
                    // Reuse the server-side KV cache for the unchanged history
                    // prefix so each turn only processes the new tokens.
                    "cache_prompt": true,
                    // Ask for a final usage chunk to drive the context meter.
                    "stream_options": ["include_usage": true],
                ]
                if !thinking {
                    body["chat_template_kwargs"] = ["enable_thinking": false]
                }
                req.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (bytes, response) = try await URLSession.shared.bytes(for: req)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }

                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    guard line.hasPrefix("data: ") else { continue }
                    let payload = String(line.dropFirst(6))
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                    if let u = obj["usage"] as? [String: Any],
                       let p = u["prompt_tokens"] as? Int, let c = u["completion_tokens"] as? Int {
                        usage = (p, c)
                    }

                    guard let choices = obj["choices"] as? [[String: Any]],
                          let delta = choices.first?["delta"] as? [String: Any] else { continue }

                    var got = false
                    // Some server configurations emit the reasoning in a
                    // dedicated field instead of inline <think> tags.
                    if let r = delta["reasoning_content"] as? String, !r.isEmpty {
                        reasoning += r
                        got = true
                    }
                    if let piece = delta["content"] as? String, !piece.isEmpty {
                        visible += piece
                        got = true
                    }
                    guard got else { continue }
                    if tFirst == nil { tFirst = Date() }
                    nTokens += 1
                    await flush()
                }
            } catch {
                if !(error is CancellationError) {
                    AppLog.chat.error("stream failed: \(error.localizedDescription)")
                    await MainActor.run { self?.lastError = error.localizedDescription }
                }
            }

            await flush(force: true)
            let finalSpeed: Double? = tFirst.flatMap { start in
                let dt = Date().timeIntervalSince(start)
                return dt > 0.4 && nTokens > 1 ? Double(nTokens) / dt : nil
            }
            let finalUsage = usage
            await MainActor.run {
                if let finalUsage { self?.contextUsed = finalUsage.prompt + finalUsage.completion }
                self?.finish(speed: finalSpeed)
            }
        }
    }

    private func setLast(_ content: String) {
        guard let i = currentIndex, let j = conversations[i].messages.indices.last,
              conversations[i].messages[j].role == "assistant" else { return }
        conversations[i].messages[j].content = content
    }

    private func finish(speed: Double?) {
        generating = false
        liveSpeed = nil
        task = nil
        guard let i = currentIndex else { return }
        if let j = conversations[i].messages.indices.last,
           conversations[i].messages[j].role == "assistant" {
            if conversations[i].messages[j].content.isEmpty {
                conversations[i].messages.removeLast()
            } else {
                conversations[i].messages[j].genSpeed = speed
            }
        }
        conversations[i].updated = Date()
        save()
    }

    func stop() { task?.cancel() }

    /// Removes the last user message (and its response, if any) so it can be
    /// edited and resent. Returns the removed user text.
    func popLastExchange() -> String? {
        guard !generating, let i = currentIndex else { return nil }
        if conversations[i].messages.last?.role == "assistant" {
            conversations[i].messages.removeLast()
        }
        guard conversations[i].messages.last?.role == "user" else { return nil }
        let text = conversations[i].messages.removeLast().content
        save()
        return text
    }

    // MARK: persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([Conversation].self, from: data) else { return }
        conversations = list
    }

    func save() {
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func exportText(_ c: Conversation) -> String {
        c.messages.map { m in
            let who = m.role == "user" ? "## Tú" : "## Asistente"
            return "\(who)\n\n\(m.role == "assistant" ? m.parts.body : m.content)"
        }.joined(separator: "\n\n---\n\n")
    }
}

// MARK: - Main chat view

struct NativeChatView: View {
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var loc: Localizer
    @StateObject private var chat = ChatStore()
    @AppStorage(SettingsKeys.chatTemp) private var temperature = 0.7
    @AppStorage(SettingsKeys.chatMaxTokens) private var maxTokens = 2048
    @AppStorage(SettingsKeys.chatSystem) private var systemPrompt = ""
    @AppStorage(SettingsKeys.chatThinking) private var thinkingEnabled = true
    @AppStorage(SettingsKeys.port) private var port = 8080
    @AppStorage(SettingsKeys.ctx) private var contextLimit = 16384
    @State private var draft = ""
    @State private var searchText = ""
    @State private var showSystem = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        HSplitView {
            conversationList
                .frame(minWidth: 180, idealWidth: 210, maxWidth: 280)
            chatColumn
                .frame(minWidth: 420, maxWidth: .infinity)
        }
        .onAppear { inputFocused = true }
    }

    // MARK: left column

    private var conversationList: some View {
        VStack(spacing: 0) {
            Button {
                chat.newConversation()
                inputFocused = true
            } label: {
                Label(loc.t("Nueva conversación", "New chat"), systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut("n", modifiers: .command)
            .padding(10)

            TextField(loc.t("Buscar…", "Search…"), text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)

            List(selection: $chat.currentID) {
                ForEach(filteredConversations) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.displayTitle(c)).lineLimit(1)
                        Text(c.updated.formatted(.relative(presentation: .named)))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .tag(c.id)
                    .contextMenu {
                        Button(loc.t("Copiar conversación", "Copy conversation")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(chat.exportText(c), forType: .string)
                        }
                        Button(loc.t("Exportar a Markdown…", "Export to Markdown…")) {
                            let panel = NSSavePanel()
                            panel.nameFieldStringValue = chat.displayTitle(c)
                                .replacingOccurrences(of: "/", with: "-") + ".md"
                            if panel.runModal() == .OK, let url = panel.url {
                                try? chat.exportText(c).write(to: url, atomically: true, encoding: .utf8)
                            }
                        }
                        Button(loc.t("Eliminar", "Delete"), role: .destructive) { chat.delete(c) }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .background(.background.secondary)
    }

    // MARK: messages column

    private var chatColumn: some View {
        VStack(spacing: 0) {
            messagesScroll
            Divider()
            inputArea
        }
    }

    private var messagesScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if chat.current?.messages.isEmpty ?? true {
                        ContentUnavailableView(
                            loc.t("Conversa con el modelo", "Chat with the model"),
                            systemImage: "bubble.left.and.text.bubble.right",
                            description: Text(loc.t("Todo se genera en tu GPU, sin salir de tu equipo.",
                                                    "Everything is generated on your GPU, never leaving your machine.")))
                            .padding(.top, 60)
                    }
                    ForEach(chat.current?.messages ?? []) { msg in
                        let isLastUser = msg.role == "user"
                            && msg.id == chat.current?.messages.last(where: { $0.role == "user" })?.id
                        MessageBubble(
                            message: msg,
                            streaming: chat.generating && msg.id == chat.current?.messages.last?.id,
                            liveSpeed: chat.liveSpeed,
                            isLastAssistant: msg.role == "assistant" && msg.id == chat.current?.messages.last?.id,
                            isLastUser: isLastUser,
                            canRegenerate: !chat.generating,
                            onRegenerate: {
                                chat.regenerate(port: port, temperature: temperature,
                                                maxTokens: maxTokens, system: systemPrompt,
                                                thinking: thinkingEnabled)
                            },
                            onEdit: {
                                if let text = chat.popLastExchange() {
                                    draft = text
                                    inputFocused = true
                                }
                            })
                            .id(msg.id)
                    }
                    if let err = chat.lastError {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.red)
                    }
                    Color.clear.frame(height: 1).id("chatBottom")
                }
                .padding()
            }
            .onChange(of: chat.current?.messages.last?.content) { _, _ in
                proxy.scrollTo("chatBottom", anchor: .bottom)
            }
            .onChange(of: chat.currentID) { _, _ in
                proxy.scrollTo("chatBottom", anchor: .bottom)
            }
        }
    }

    // MARK: input

    private var inputArea: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Button {
                    showSystem.toggle()
                } label: {
                    Label(loc.t("Sistema", "System"),
                          systemImage: systemPrompt.isEmpty ? "gearshape" : "gearshape.fill")
                        .foregroundStyle(systemPrompt.isEmpty ? .secondary : Color.accentColor)
                }
                .buttonStyle(.borderless).font(.caption)
                .help(loc.t("Prompt de sistema: instrucciones permanentes para el modelo.",
                            "System prompt: permanent instructions for the model."))
                .popover(isPresented: $showSystem, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(loc.t("Prompt de sistema", "System prompt")).font(.headline)
                        TextEditor(text: $systemPrompt)
                            .font(.system(size: 12))
                            .frame(width: 380, height: 110)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
                        Text(loc.t("Se aplica a los mensajes nuevos de todas las conversaciones.",
                                   "Applies to new messages in all conversations."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(12)
                }

                Toggle(isOn: $thinkingEnabled) {
                    Label(loc.t("Razonamiento", "Reasoning"), systemImage: "brain")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .help(loc.t("Los modelos razonadores piensan antes de responder (más calidad, ~30-60 s extra de espera). Desactívalo para respuestas inmediatas.",
                            "Reasoning models think before answering (better quality, ~30-60 s extra wait). Turn off for instant responses."))

                HStack(spacing: 6) {
                    Text("Temp").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $temperature, in: 0...1.5).frame(width: 80)
                    Text(String(format: "%.2f", temperature))
                        .font(.system(.caption, design: .monospaced)).frame(width: 32)
                }
                .help(loc.t("Creatividad: 0 = determinista, 1+ = más variado.",
                            "Creativity: 0 = deterministic, 1+ = more varied."))

                HStack(spacing: 6) {
                    Text(loc.t("Máx.", "Max")).font(.caption).foregroundStyle(.secondary)
                    TextField("", value: $maxTokens, format: .number)
                        .frame(width: 60).textFieldStyle(.roundedBorder)
                }
                .help(loc.t("Longitud máxima de cada respuesta en tokens.",
                            "Maximum response length in tokens."))

                Spacer()

                if let used = chat.contextUsed, contextLimit > 0 {
                    let fraction = Double(used) / Double(contextLimit)
                    HStack(spacing: 5) {
                        Text(loc.t("Contexto", "Context")).font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: min(fraction, 1))
                            .frame(width: 70)
                            .tint(fraction > 0.9 ? .red : fraction > 0.8 ? .orange : .accentColor)
                        Text("\(used / 1000)k / \(contextLimit / 1000)k")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(fraction > 0.8 ? .orange : .secondary)
                    }
                    .help(loc.t("Tokens de contexto usados en el último turno. Al llenarse, el servidor olvida el inicio de la conversación.",
                                "Context tokens used by the last turn. When full, the server forgets the start of the conversation."))
                }

                if let speed = chat.liveSpeed {
                    Text(String(format: "%.1f t/s", speed))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.pink)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(loc.t("Escribe tu mensaje…", "Type your message…"),
                          text: $draft, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit(send)
                if chat.generating {
                    Button(role: .destructive) { chat.stop() } label: {
                        Label(loc.t("Detener", "Stop"), systemImage: "stop.fill")
                    }
                    .controlSize(.large)
                } else {
                    Button(action: send) {
                        Label(loc.t("Enviar", "Send"), systemImage: "paperplane.fill")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(12)
        .background(.bar)
    }

    private var filteredConversations: [Conversation] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return chat.conversations }
        return chat.conversations.filter { c in
            chat.displayTitle(c).localizedCaseInsensitiveContains(query) ||
            c.messages.contains { $0.content.localizedCaseInsensitiveContains(query) }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chat.generating else { return }
        draft = ""
        chat.send(text: text, port: port, temperature: temperature,
                  maxTokens: maxTokens, system: systemPrompt, thinking: thinkingEnabled)
    }
}

// MARK: - Message bubble

struct MessageBubble: View {
    let message: ChatMessage
    let streaming: Bool
    let liveSpeed: Double?
    let isLastAssistant: Bool
    let isLastUser: Bool
    let canRegenerate: Bool
    let onRegenerate: () -> Void
    let onEdit: () -> Void

    @EnvironmentObject var loc: Localizer
    @State private var thinkExpanded = false
    @State private var copied = false
    @State private var hovering = false

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 70) }

            if !isUser {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.pink)
                    .frame(width: 26, height: 26)
                    .background(.pink.opacity(0.15), in: Circle())
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                // header
                HStack(spacing: 8) {
                    Text(isUser ? loc.t("Tú", "You") : "Asistente")
                        .font(.caption.weight(.medium))
                    Text(message.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption2).foregroundStyle(.tertiary)
                    if let speed = message.genSpeed {
                        Text(String(format: "%.1f t/s", speed))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if hovering && !streaming {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                isUser ? message.content : message.parts.body, forType: .string)
                            copied = true
                            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .help(loc.t("Copiar mensaje", "Copy message"))
                        if isLastAssistant && canRegenerate {
                            Button(action: onRegenerate) {
                                Image(systemName: "arrow.clockwise").font(.system(size: 10))
                            }
                            .buttonStyle(.borderless)
                            .help(loc.t("Regenerar respuesta", "Regenerate response"))
                        }
                        if isLastUser && canRegenerate {
                            Button(action: onEdit) {
                                Image(systemName: "pencil").font(.system(size: 10))
                            }
                            .buttonStyle(.borderless)
                            .help(loc.t("Editar y reenviar", "Edit and resend"))
                        }
                    }
                }

                // body
                VStack(alignment: .leading, spacing: 6) {
                    let parts = message.parts
                    let isThinkingLive = streaming && parts.body.isEmpty && parts.thinking != nil
                    if let think = parts.thinking, !think.isEmpty {
                        DisclosureGroup(isExpanded: $thinkExpanded) {
                            Text(think)
                                .font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } label: {
                            Label(isThinkingLive ? loc.t("Razonando…", "Thinking…")
                                                 : loc.t("Razonamiento", "Reasoning"),
                                  systemImage: "brain")
                                .font(.caption).foregroundStyle(.blue)
                        }
                        .onChange(of: isThinkingLive) { _, live in
                            thinkExpanded = live
                        }
                        .onAppear { if isThinkingLive { thinkExpanded = true } }
                    }
                    if !parts.body.isEmpty || parts.thinking == nil {
                        RichText(text: isUser ? message.content : parts.body)
                    }
                    if streaming {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            if let speed = liveSpeed {
                                Text(String(format: "%.1f t/s", speed))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background(isUser ? AnyShapeStyle(.tint.opacity(0.17)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                            in: RoundedRectangle(cornerRadius: 12))
            }

            if isUser {
                Image(systemName: "person.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(.quaternary.opacity(0.6), in: Circle())
            }
            if !isUser { Spacer(minLength: 70) }
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - Markdown rendering

private enum MDBlock: Identifiable {
    case paragraph(String)
    case header(Int, String)
    case bullet([String])
    case numbered([String])
    case code(String, String)   // language, content
    case quote(String)

    var id: String {
        switch self {
        case .paragraph(let s): return "p" + s
        case .header(let l, let s): return "h\(l)" + s
        case .bullet(let i): return "b" + i.joined()
        case .numbered(let i): return "n" + i.joined()
        case .code(let l, let c): return "c" + l + c
        case .quote(let s): return "q" + s
        }
    }
}

struct RichText: View {
    let text: String

    var body: some View {
        let blocks = Self.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block {
                case .paragraph(let s):
                    Text(Self.inline(s)).textSelection(.enabled)
                case .header(let level, let s):
                    Text(Self.inline(s))
                        .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                case .bullet(let items):
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text("•").foregroundStyle(.secondary)
                                Text(Self.inline(item)).textSelection(.enabled)
                            }
                        }
                    }
                case .numbered(let items):
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text("\(i + 1).").foregroundStyle(.secondary)
                                    .font(.system(.body, design: .monospaced))
                                Text(Self.inline(item)).textSelection(.enabled)
                            }
                        }
                    }
                case .code(let lang, let content):
                    CodeBlock(language: lang, content: content)
                case .quote(let s):
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(.tertiary).frame(width: 3)
                        Text(Self.inline(s)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: parser

    private static func parse(_ raw: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false)[...]
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbers: [String] = []

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
            if !bullets.isEmpty { blocks.append(.bullet(bullets)); bullets = [] }
            if !numbers.isEmpty { blocks.append(.numbered(numbers)); numbers = [] }
        }

        while let line = lines.first {
            lines = lines.dropFirst()
            let l = String(line)

            if l.hasPrefix("```") {
                flush()
                let lang = String(l.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                while let next = lines.first, !next.hasPrefix("```") {
                    code.append(String(next))
                    lines = lines.dropFirst()
                }
                if lines.first?.hasPrefix("```") == true { lines = lines.dropFirst() }
                blocks.append(.code(lang, code.joined(separator: "\n")))
            } else if let m = l.range(of: #"^#{1,4} "#, options: .regularExpression) {
                flush()
                let level = l[..<m.upperBound].filter { $0 == "#" }.count
                blocks.append(.header(level, String(l[m.upperBound...])))
            } else if l.hasPrefix("> ") {
                flush()
                blocks.append(.quote(String(l.dropFirst(2))))
            } else if l.range(of: #"^\s*[-*+] "#, options: .regularExpression) != nil {
                if !paragraph.isEmpty || !numbers.isEmpty { flush() }
                bullets.append(l.replacingOccurrences(of: #"^\s*[-*+] "#, with: "", options: .regularExpression))
            } else if l.range(of: #"^\s*\d+[.)] "#, options: .regularExpression) != nil {
                if !paragraph.isEmpty || !bullets.isEmpty { flush() }
                numbers.append(l.replacingOccurrences(of: #"^\s*\d+[.)] "#, with: "", options: .regularExpression))
            } else if l.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                if !bullets.isEmpty || !numbers.isEmpty { flush() }
                paragraph.append(l)
            }
        }
        flush()
        return blocks
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct CodeBlock: View {
    let language: String
    let content: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "✓" : "", systemImage: copied ? "" : "doc.on.doc")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.35))

            ScrollView(.horizontal) {
                Text(content)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(10)
                    .textSelection(.enabled)
            }
            .background(.black.opacity(0.22))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
