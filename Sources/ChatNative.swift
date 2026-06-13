import SwiftUI

// MARK: - Model

/// A text file attached to a user message: sent to the model as a fenced
/// block, rendered in the transcript as a compact chip.
struct ChatAttachment: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var content: String

    /// Rough token estimate (chars/4) for context budgeting in the UI.
    var estimatedTokens: Int { max(1, content.count / 4) }

    var fenceHint: String { (name as NSString).pathExtension.lowercased() }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    let role: String          // user | assistant
    var content: String
    var date = Date()
    var genSpeed: Double?     // t/s for this response
    // Optional keeps pre-attachment JSON decodable.
    var attachments: [ChatAttachment]? = nil

    /// Content as sent over the wire: attached files as fenced blocks first,
    /// then the typed text.
    var wireContent: String {
        guard let attachments, !attachments.isEmpty else { return content }
        let blocks = attachments.map { a in
            "File: \(a.name)\n```\(a.fenceHint)\n\(a.content)\n```"
        }
        return (blocks.joined(separator: "\n\n") + "\n\n" + content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
    // Auto-compaction: rolling summary of the oldest turns and how many
    // leading messages it covers. Those messages stay visible and persisted;
    // they are just no longer sent verbatim with each request. Optionals keep
    // pre-compaction JSON decodable.
    var summary: String?
    var summarizedCount: Int?
}

struct StreamError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Store with persistence and streaming

/// High-frequency streaming state, isolated from ChatStore so per-flush
/// updates re-render only the views that observe it (the streaming bubble
/// and the speed badge), never the sidebar or the rest of the transcript.
@MainActor
final class LiveStream: ObservableObject {
    @Published var visibleText = ""
    @Published var displayedReasoning = ""
    @Published var hasReasoning = false
    @Published var reasoningExpanded = false
    @Published var speed: Double?

    private var latestReasoning = ""
    private var lastReasoningPublish = Date.distantPast
    private let reasoningPublishInterval: TimeInterval = 0.5

    func reset() {
        visibleText = ""
        displayedReasoning = ""
        hasReasoning = false
        reasoningExpanded = false
        latestReasoning = ""
        lastReasoningPublish = .distantPast
        speed = nil
    }

    func update(reasoning: String, visible: String, speed: Double?, now: Date = Date()) {
        latestReasoning = reasoning
        if hasReasoning != !reasoning.isEmpty { hasReasoning = !reasoning.isEmpty }
        // Rendering a growing reasoning transcript is expensive. Keep the
        // answer stream responsive at ~12 Hz, but refresh expanded reasoning
        // in larger chunks at 2 Hz.
        if reasoningExpanded,
           now.timeIntervalSince(lastReasoningPublish) >= reasoningPublishInterval,
           displayedReasoning != reasoning {
            displayedReasoning = reasoning
            lastReasoningPublish = now
        }
        if visibleText != visible { visibleText = visible }
        if let speed { self.speed = speed }
    }

    func setReasoningExpanded(_ expanded: Bool, now: Date = Date()) {
        reasoningExpanded = expanded
        displayedReasoning = expanded ? latestReasoning : ""
        lastReasoningPublish = expanded ? now : .distantPast
    }
}

@MainActor
final class ChatStore: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var currentID: UUID?
    @Published var generating = false
    @Published var compacting = false
    @Published var lastError: String?
    let live = LiveStream()
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
        // Open ready to type a new message: reuse the most recent empty
        // conversation or start a fresh one. Earlier chats stay one click away.
        if let empty = conversations.first(where: { $0.messages.isEmpty }) {
            currentID = empty.id
        } else {
            newConversation()
        }
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

    func rename(_ c: Conversation, to title: String) {
        guard let i = conversations.firstIndex(where: { $0.id == c.id }) else { return }
        conversations[i].title = title.trimmingCharacters(in: .whitespaces)
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

    func send(text: String, attachments: [ChatAttachment] = [], port: Int, temperature: Double,
              maxTokens: Int, system: String, thinking: Bool) {
        guard !generating, let i = currentIndex else { return }
        lastError = nil
        conversations[i].messages.append(ChatMessage(role: "user", content: text,
                                                     attachments: attachments.isEmpty ? nil : attachments))
        if conversations[i].title.isEmpty {
            conversations[i].title = text.isEmpty
                ? (attachments.first?.name ?? "…")
                : String(text.prefix(40))
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
        live.reset()
        // The user can switch or delete conversations mid-stream; the result
        // must land in the one this request started from, found by id.
        let convID = conversations[i].id

        let history = Self.requestHistory(system: system,
                                          summary: conversations[i].summary,
                                          messages: conversations[i].messages,
                                          from: conversations[i].summarizedCount ?? 0)

        conversations[i].messages.append(ChatMessage(role: "assistant", content: ""))

        // Detached: SSE parsing must stay off the main actor, otherwise UI
        // rendering throttles token consumption on long responses and the
        // measured t/s drops even though the server keeps generating.
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var nTokens = 0
            var tFirst: Date?
            // Token arrival times within the last seconds; drives the live
            // t/s as an instantaneous reading instead of a cumulative average.
            var stamps: [Date] = []
            var reasoning = ""
            var visible = ""
            var lastFlush = Date.distantPast
            var usage: (prompt: Int, completion: Int)?
            var finishReason: String?
            var cancelled = false
            var reportedError = false

            func composed() -> String {
                guard !reasoning.isEmpty else { return visible }
                return "<think>" + reasoning + (visible.isEmpty ? "" : "</think>" + visible)
            }

            // Publishes a snapshot to the UI at ~12 Hz; accumulation between
            // flushes happens locally so the UI never re-renders per token.
            func flush(force: Bool = false) async {
                let now = Date()
                guard force || now.timeIntervalSince(lastFlush) > 0.08 else { return }
                lastFlush = now
                if let cut = stamps.firstIndex(where: { now.timeIntervalSince($0) < 3 }) {
                    stamps.removeFirst(cut)
                } else {
                    stamps.removeAll()
                }
                var speed: Double?
                if let first = stamps.first, stamps.count > 4 {
                    let dt = now.timeIntervalSince(first)
                    if dt > 0.3 { speed = Double(stamps.count - 1) / dt }
                }
                let reasoningSnapshot = reasoning
                let visibleSnapshot = visible
                let newSpeed = speed
                let store = self
                await MainActor.run {
                    store?.live.update(reasoning: reasoningSnapshot,
                                       visible: visibleSnapshot,
                                       speed: newSpeed)
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
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    // The error body explains the cause (e.g. context overflow);
                    // surface it instead of a generic "bad server response".
                    var raw = ""
                    for try await line in bytes.lines {
                        raw += line
                        if raw.count > 4000 { break }
                    }
                    throw StreamError(message: Self.describeServerError(status: status, body: raw))
                }

                for try await line in bytes.lines {
                    if Task.isCancelled {
                        cancelled = true
                        break
                    }
                    guard line.hasPrefix("data: ") else { continue }
                    let payload = String(line.dropFirst(6))
                    if payload == "[DONE]" { break }
                    guard let data = payload.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                    if let message = Self.streamedError(from: obj) {
                        throw StreamError(message: message)
                    }

                    if let u = obj["usage"] as? [String: Any],
                       let p = u["prompt_tokens"] as? Int, let c = u["completion_tokens"] as? Int {
                        usage = (p, c)
                    }

                    guard let choices = obj["choices"] as? [[String: Any]],
                          let choice = choices.first else { continue }
                    if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
                        finishReason = reason
                    }

                    var got = false
                    // Some server configurations emit the reasoning in a
                    // dedicated field instead of inline <think> tags.
                    if let delta = choice["delta"] as? [String: Any] {
                        if let r = delta["reasoning_content"] as? String, !r.isEmpty {
                            reasoning += r
                            got = true
                        }
                        if let piece = delta["content"] as? String, !piece.isEmpty {
                            visible += piece
                            got = true
                        }
                    }
                    if got {
                        let now = Date()
                        if tFirst == nil { tFirst = now }
                        nTokens += 1
                        stamps.append(now)
                        await flush()
                    }
                    // Keep consuming after finish_reason: llama-server sends
                    // the final usage counters in a later SSE event before
                    // [DONE]. Those counters drive the context meter and
                    // automatic compaction.
                }
            } catch {
                if error is CancellationError {
                    cancelled = true
                } else {
                    reportedError = true
                    AppLog.chat.error("stream failed: \(error.localizedDescription)")
                    let store = self
                    let message = error.localizedDescription
                    await MainActor.run { store?.lastError = message }
                }
            }

            let finalSpeed: Double? = tFirst.flatMap { start in
                let dt = Date().timeIntervalSince(start)
                return dt > 0.4 && nTokens > 1 ? Double(nTokens) / dt : nil
            }
            // A reasoning-only turn is not a usable assistant response. Drop
            // it instead of persisting an apparently duplicated empty bubble
            // and sending an empty assistant message in the next request.
            let hasVisibleAnswer = !visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let finalText = hasVisibleAnswer ? composed() : ""
            let finalUsage = usage
            let finalFinishReason = finishReason
            let wasCancelled = cancelled
            let didReportError = reportedError
            let hadReasoning = !reasoning.isEmpty
            let store = self
            await MainActor.run {
                if !wasCancelled && !didReportError && hadReasoning && !hasVisibleAnswer {
                    store?.lastError = Self.emptyResponseMessage(finishReason: finalFinishReason)
                }
                if let finalUsage { store?.contextUsed = finalUsage.prompt + finalUsage.completion }
                store?.finish(conversation: convID, text: finalText, speed: finalSpeed)
                store?.compactIfNeeded(conversation: convID, port: port)
            }
        }
    }

    /// Writes the completed response into its conversation and clears the
    /// live-streaming state. The conversation may no longer be the current
    /// one, or may have been deleted, hence the lookup by id.
    private func finish(conversation id: UUID, text: String, speed: Double?) {
        if let i = conversations.firstIndex(where: { $0.id == id }) {
            if let j = conversations[i].messages.indices.last,
               conversations[i].messages[j].role == "assistant" {
                if text.isEmpty {
                    conversations[i].messages.removeLast()
                } else {
                    conversations[i].messages[j].content = text
                    conversations[i].messages[j].genSpeed = speed
                }
            }
            conversations[i].updated = Date()
        }
        // Publish the completed transcript before replacing StreamingBubble.
        // Otherwise SwiftUI can briefly create and retain an empty bubble.
        generating = false
        live.reset()
        task = nil
        save()
    }

    // MARK: auto-compaction

    /// Builds the wire history: system prompt with the rolling summary of
    /// compacted turns folded in, then the messages that remain uncompacted,
    /// stripped of reasoning blocks (saves context).
    nonisolated static func requestHistory(system: String, summary: String?,
                                           messages: [ChatMessage], from start: Int) -> [[String: String]] {
        var history: [[String: String]] = []
        var sys = system.trimmingCharacters(in: .whitespaces)
        if let summary, !summary.isEmpty {
            sys += (sys.isEmpty ? "" : "\n\n")
                + "Summary of the earlier part of this conversation:\n" + summary
        }
        if !sys.isEmpty { history.append(["role": "system", "content": sys]) }
        let safeStart = min(max(0, start), messages.count)
        history += messages[safeStart...].compactMap { m in
            let content = m.role == "assistant" ? m.parts.body : m.wireContent
            guard m.role != "assistant"
                    || !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ["role": m.role, "content": content]
        }
        return history
    }

    /// Index up to which messages can be folded into the summary: keeps the
    /// most recent exchanges verbatim and lands on a user message so the
    /// remaining history starts a full turn. Nil when too little would be
    /// gained over what is already compacted.
    nonisolated static func compactionCutoff(messages: [ChatMessage], alreadyCompacted: Int) -> Int? {
        var cutoff = messages.count - 4
        while cutoff > 0 && messages[cutoff].role != "user" { cutoff -= 1 }
        guard cutoff >= alreadyCompacted + 2 else { return nil }
        return cutoff
    }

    /// Once the last exchange used over 70% of the configured context,
    /// summarize the older turns with the model itself; future requests send
    /// the summary plus the recent messages. The full transcript stays
    /// visible and persisted.
    private func compactIfNeeded(conversation id: UUID, port: Int) {
        let d = UserDefaults.standard
        let enabled = d.object(forKey: SettingsKeys.chatAutoCompact) == nil
            ? true : d.bool(forKey: SettingsKeys.chatAutoCompact)
        let limit = d.object(forKey: SettingsKeys.ctx) == nil
            ? 16384 : d.integer(forKey: SettingsKeys.ctx)
        guard enabled, !generating, !compacting, limit > 0,
              let used = contextUsed, Double(used) / Double(limit) > 0.7,
              let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        let start = conversations[i].summarizedCount ?? 0
        guard let cutoff = Self.compactionCutoff(messages: conversations[i].messages,
                                                 alreadyCompacted: start) else { return }
        compact(conversation: id, index: i, from: start, through: cutoff, port: port)
    }

    /// Manually summarizes every completed exchange. This is useful on
    /// backends without Flash Attention, where generation can slow down well
    /// before the context is close to full.
    func compactCurrent(port: Int) {
        guard !generating, !compacting, let i = currentIndex,
              conversations[i].messages.last?.role == "assistant" else { return }
        let start = conversations[i].summarizedCount ?? 0
        let cutoff = conversations[i].messages.count
        guard cutoff > start else { return }
        compact(conversation: conversations[i].id, index: i,
                from: start, through: cutoff, port: port)
    }

    var canCompactCurrent: Bool {
        guard !generating, !compacting, let i = currentIndex,
              conversations[i].messages.last?.role == "assistant" else { return false }
        return conversations[i].messages.count > (conversations[i].summarizedCount ?? 0)
    }

    private func compact(conversation id: UUID, index i: Int,
                         from start: Int, through cutoff: Int, port: Int) {
        var prompt = ""
        if let prior = conversations[i].summary, !prior.isEmpty {
            prompt += "Previous summary:\n" + prior + "\n\n"
        }
        prompt += "Conversation to summarize:\n\n"
        for m in conversations[i].messages[start..<cutoff] {
            prompt += (m.role == "user" ? "User: " : "Assistant: ")
                + (m.role == "assistant" ? m.parts.body : m.content) + "\n\n"
        }

        compacting = true
        AppLog.chat.info("compacting conversation through message \(cutoff)")
        Task.detached(priority: .utility) { [weak self] in
            let summary = await Self.summarize(prompt: prompt, port: port)
            let store = self
            await MainActor.run {
                store?.applyCompaction(conversation: id, cutoff: cutoff, summary: summary)
            }
        }
    }

    private func applyCompaction(conversation id: UUID, cutoff: Int, summary: String?) {
        compacting = false
        guard let summary, let i = conversations.firstIndex(where: { $0.id == id }),
              cutoff <= conversations[i].messages.count else { return }
        conversations[i].summary = summary
        conversations[i].summarizedCount = cutoff
        save()
    }

    /// Non-streamed completion that condenses old turns. Returns nil on any
    /// failure; compaction is then retried after the next exchange.
    nonisolated private static func summarize(prompt: String, port: Int) async -> String? {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = ServerSettings.activeAPIKey() {
            req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
        let instructions = "You summarize conversations. Write a compact summary (at most ~250 words) of the conversation below, in the same language the conversation itself uses. Preserve key facts, decisions, names, numbers, code references and pending questions. Reply with the summary only."
        let body: [String: Any] = [
            "messages": [["role": "system", "content": instructions],
                         ["role": "user", "content": prompt]],
            "stream": false,
            "temperature": 0.3,
            "max_tokens": 512,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            AppLog.chat.error("compaction summarize request failed")
            return nil
        }
        // Reasoning models may emit a think block anyway; keep only the body.
        let text = ChatMessage(role: "assistant",
                               content: content.trimmingCharacters(in: .whitespacesAndNewlines)).parts.body
        return text.isEmpty ? nil : text
    }

    /// Maps llama-server HTTP errors ({"error":{"message":…}}) to readable,
    /// actionable text, following the same bilingual style as Server.diagnose.
    nonisolated private static func describeServerError(status: Int, body: String) -> String {
        var message = body
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let m = err["message"] as? String {
            message = m
        }
        if message.lowercased().contains("context") {
            return "Contexto lleno: inicia una conversación nueva o sube el contexto en Ajustes / context full: start a new chat or raise the context size in Settings"
        }
        return "HTTP \(status): \(message.prefix(300))"
    }

    /// Streaming APIs can report a compute failure inside an HTTP 200 SSE
    /// response. Surface it instead of silently treating the partial text as
    /// a completed assistant message.
    nonisolated static func streamedError(from object: [String: Any]) -> String? {
        guard let error = object["error"] else { return nil }
        if let details = error as? [String: Any],
           let message = details["message"] as? String, !message.isEmpty {
            return message
        }
        if let message = error as? String, !message.isEmpty { return message }
        return "El motor interrumpió la respuesta / the engine interrupted the response"
    }

    nonisolated static func emptyResponseMessage(finishReason: String?) -> String {
        if finishReason == "length" {
            return "El modelo agotó el máximo de tokens durante el razonamiento; aumenta Máx. o desactiva Razonamiento / the model used all max tokens while reasoning; raise Max or disable Reasoning"
        }
        return "El modelo terminó el razonamiento sin producir una respuesta visible; intenta regenerar o desactiva Razonamiento / the model finished reasoning without a visible answer; regenerate or disable Reasoning"
    }

    func stop() { task?.cancel() }

    /// Removes the last user message (and its response, if any) so it can be
    /// edited and resent. Returns the removed message, attachments included.
    func popLastExchange() -> ChatMessage? {
        guard !generating, let i = currentIndex else { return nil }
        if conversations[i].messages.last?.role == "assistant" {
            conversations[i].messages.removeLast()
        }
        guard conversations[i].messages.last?.role == "user" else { return nil }
        let message = conversations[i].messages.removeLast()
        save()
        return message
    }

    // MARK: persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([Conversation].self, from: data) else { return }
        conversations = list
    }

    // Serial queue: keeps writes ordered while encoding off the main thread,
    // since the full history JSON grows with use and would cause hitches.
    private static let saveQueue = DispatchQueue(label: "dev.engel.toshllm.chat-save", qos: .utility)

    func save() {
        let snapshot = conversations
        let url = fileURL
        Self.saveQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
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
    @State private var attachments: [ChatAttachment] = []
    @State private var attachError: String?
    @State private var searchText = ""
    @State private var showSystem = false
    @State private var pinnedToBottom = true
    @State private var renaming: Conversation?
    @State private var renameText = ""
    @FocusState private var inputFocused: Bool

    private var maxTokenOptions: [Int] {
        [512, 1024, 2048, 4096, 8192, 16384].filter { $0 < contextLimit }
    }

    private var maxTokensIsLarge: Bool {
        contextLimit > 0 && Double(maxTokens) / Double(contextLimit) > 0.5
    }

    private var contextMaySlowGeneration: Bool {
        guard !ServerSettings.isAppleSilicon, let used = chat.contextUsed, contextLimit > 0 else {
            return false
        }
        // Without Flash Attention, generation slows with absolute depth
        // (~ -8 t/s per 1k tokens measured on RDNA2), so an absolute token
        // threshold matters more than the fraction of configured context.
        return used >= 2560 || Double(used) / Double(contextLimit) >= 0.15
    }

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
                        Button(loc.t("Renombrar…", "Rename…")) {
                            renameText = chat.displayTitle(c)
                            renaming = c
                        }
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
        .alert(loc.t("Renombrar conversación", "Rename conversation"),
               isPresented: Binding(get: { renaming != nil },
                                    set: { if !$0 { renaming = nil } })) {
            TextField(loc.t("Título", "Title"), text: $renameText)
            Button(loc.t("Guardar", "Save")) {
                if let c = renaming { chat.rename(c, to: renameText) }
                renaming = nil
            }
            Button(loc.t("Cancelar", "Cancel"), role: .cancel) { renaming = nil }
        }
    }

    // MARK: messages column

    private var chatColumn: some View {
        VStack(spacing: 0) {
            messagesScroll
            Divider()
            inputArea
        }
    }

    /// First message not covered by the compaction summary; the transcript
    /// shows a marker above it.
    private var compactionBoundaryID: UUID? {
        guard let c = chat.current, c.summary != nil,
              let n = c.summarizedCount, n > 0, n < c.messages.count else { return nil }
        return c.messages[n].id
    }

    private var messagesScroll: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if chat.current?.messages.isEmpty ?? true {
                        VStack(spacing: 10) {
                            Image(systemName: "bubble.left.and.text.bubble.right")
                                .font(.system(size: 34))
                                .foregroundStyle(.pink.opacity(0.8))
                            Text(loc.t("¿En qué puedo ayudarte?", "What can I help with?"))
                                .font(.title2.weight(.semibold))
                            Text(loc.t("Todo se genera en tu GPU, sin salir de tu equipo. Adjunta archivos con el clip para preguntar sobre tu código.",
                                       "Everything runs on your GPU, never leaving your machine. Attach files with the paperclip to ask about your code."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 420)
                        }
                        .padding(.top, 100)
                    }
                    ForEach(chat.current?.messages ?? []) { msg in
                        let isLast = msg.id == chat.current?.messages.last?.id
                        let isLastUser = msg.role == "user"
                            && msg.id == chat.current?.messages.last(where: { $0.role == "user" })?.id
                        if msg.id == compactionBoundaryID {
                            Label(loc.t("Mensajes anteriores resumidos para liberar contexto",
                                        "Earlier messages summarized to free context"),
                                  systemImage: "archivebox")
                                .font(.caption2).foregroundStyle(.secondary)
                                .help(loc.t("Lo anterior a esta marca se envía al modelo como un resumen automático; aquí sigue visible íntegro.",
                                            "History above this mark is sent to the model as an automatic summary; it remains fully visible here."))
                        }
                        if chat.generating && isLast && msg.role == "assistant" {
                            StreamingBubble(live: chat.live, message: msg) {
                                if pinnedToBottom { proxy.scrollTo("chatBottom", anchor: .bottom) }
                            }
                            // StreamingBubble and the completed MessageBubble
                            // must not share identity. Reusing the streaming
                            // subtree after live.text is cleared leaves an
                            // empty spinner even though the answer was saved.
                            .id("streaming-\(msg.id.uuidString)")
                        } else {
                            MessageBubble(
                                message: msg,
                                streaming: false,
                                liveSpeed: nil,
                                isLastAssistant: msg.role == "assistant" && isLast,
                                isLastUser: isLastUser,
                                canRegenerate: !chat.generating,
                                onRegenerate: {
                                    pinnedToBottom = true
                                    chat.regenerate(port: port, temperature: temperature,
                                                    maxTokens: maxTokens, system: systemPrompt,
                                                    thinking: thinkingEnabled)
                                },
                                onEdit: {
                                    if let m = chat.popLastExchange() {
                                        draft = m.content
                                        attachments = m.attachments ?? []
                                        inputFocused = true
                                    }
                                })
                                .equatable()
                                .id("finished-\(msg.id.uuidString)")
                        }
                    }
                    if let err = chat.lastError {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.red)
                    }
                    Color.clear.frame(height: 1).id("chatBottom")
                        .background(GeometryReader { g in
                            Color.clear.preference(key: BottomMarkerKey.self,
                                                   value: g.frame(in: .named("chatScroll")).minY)
                        })
                }
                .padding()
            }
            .coordinateSpace(name: "chatScroll")
            // Follow the stream only while the user is already at the bottom;
            // scrolling up to read pauses the auto-follow until they return.
            .onPreferenceChange(BottomMarkerKey.self) { y in
                let pinned = y <= viewport.size.height + 120
                if pinned != pinnedToBottom { pinnedToBottom = pinned }
            }
            .overlay(alignment: .bottomTrailing) {
                if !pinnedToBottom {
                    Button {
                        pinnedToBottom = true
                        proxy.scrollTo("chatBottom", anchor: .bottom)
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                            .background(Circle().fill(.background).padding(3))
                    }
                    .buttonStyle(.borderless)
                    .padding(14)
                    .help(loc.t("Ir al final de la conversación y seguir la respuesta.",
                                "Jump to the end of the conversation and follow the response."))
                }
            }
            .onChange(of: chat.current?.messages.last?.content) { _, _ in
                if pinnedToBottom { proxy.scrollTo("chatBottom", anchor: .bottom) }
            }
            .onChange(of: chat.currentID) { _, _ in
                pinnedToBottom = true
                proxy.scrollTo("chatBottom", anchor: .bottom)
            }
            }
        }
    }

    // MARK: input

    private var inputArea: some View {
        VStack(spacing: 8) {
            statusStrip
            if !attachments.isEmpty { attachmentChips }
            if let attachError {
                Label(attachError, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 10) {
                paramsButton
                attachButton
                TextField(loc.t("Escribe tu mensaje…", "Type your message…"),
                          text: $draft, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 17))
                    .focused($inputFocused)
                    .onSubmit(send)
                    .onChange(of: draft) { _, value in
                        absorbLargeDraft(value)
                    }
                    .help(loc.t("Intro envía; Opción+Intro inserta un salto de línea. Los textos pegados grandes se convierten en un adjunto.",
                                "Return sends; Option+Return inserts a line break. Large pasted text becomes an attachment."))
                if chat.generating {
                    Button { chat.stop() } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .padding(.bottom, 2)
                    .help(loc.t("Detener la generación.", "Stop generation."))
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.45))
                    }
                    .buttonStyle(.borderless)
                    .padding(.bottom, 2)
                    .disabled(!canSend)
                    .help(loc.t("Enviar mensaje (Intro).", "Send message (Return)."))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        // Files dropped anywhere on the composer become attachments.
        .dropDestination(for: URL.self) { urls, _ in
            addAttachments(urls: urls)
            return true
        }
    }

    private var canSend: Bool {
        !chat.generating
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private var paramsButton: some View {
        Button {
            showSystem.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 16))
                .foregroundStyle(systemPrompt.isEmpty ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.borderless)
        .padding(.bottom, 6)
        .popover(isPresented: $showSystem, arrowEdge: .top) { paramsPopover }
        .help(loc.t("Parámetros del chat: razonamiento, creatividad, longitud de respuesta y prompt de sistema.",
                    "Chat parameters: reasoning, creativity, response length and system prompt."))
    }

    private var paramsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc.t("Parámetros del chat", "Chat parameters")).font(.headline)

            Toggle(isOn: $thinkingEnabled) {
                Label(loc.t("Razonamiento", "Reasoning"), systemImage: "brain")
            }
            .help(loc.t("Los modelos razonadores piensan antes de responder. Estos tokens también cuentan dentro del límite de respuesta.",
                        "Reasoning models think before answering. Reasoning tokens also count toward the response limit."))

            HStack(spacing: 8) {
                Label(loc.t("Creatividad", "Creativity"), systemImage: "dial.medium")
                Slider(value: $temperature, in: 0...1.5)
                Text(String(format: "%.2f", temperature))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 34)
            }
            .help(loc.t("Temperatura: 0 = más determinista; valores altos = respuestas más variadas.",
                        "Temperature: 0 = more deterministic; higher values = more varied responses."))

            Picker(selection: $maxTokens) {
                ForEach(maxTokenOptions, id: \.self) { Text($0.formatted()).tag($0) }
            } label: {
                Label(loc.t("Tokens de respuesta", "Response tokens"),
                      systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            .help(loc.t("Máximo de tokens que el modelo puede generar en este turno, incluyendo razonamiento y respuesta visible. No aumenta el contexto. Recomendado: 2.048–4.096.",
                        "Maximum tokens the model may generate this turn, including reasoning and visible answer. It does not increase context. Recommended: 2,048–4,096."))
            if maxTokensIsLarge {
                Label(loc.t("Este límite reserva más de la mitad del contexto para una sola respuesta.",
                            "This limit reserves more than half the context for a single response."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            Divider()

            Label(loc.t("Prompt de sistema", "System prompt"), systemImage: "gearshape")
                .font(.subheadline.weight(.medium))
            TextEditor(text: $systemPrompt)
                .font(.system(size: 12))
                .frame(height: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
                .help(loc.t("Instrucciones permanentes para el modelo.",
                            "Permanent instructions for the model."))
            Text(loc.t("Se aplica a los mensajes nuevos de todas las conversaciones.",
                       "Applies to new messages in all conversations."))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 380)
    }

    private var attachButton: some View {
        Button(action: pickAttachments) {
            Image(systemName: "paperclip")
                .font(.system(size: 16))
                .foregroundStyle(attachments.isEmpty ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.borderless)
        .padding(.bottom, 6)
        .disabled(chat.generating)
        .help(loc.t("Adjuntar archivos de texto o código a este mensaje. También puedes arrastrarlos al área de escritura.",
                    "Attach text or code files to this message. You can also drag them onto the input area."))
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { a in
                    HStack(spacing: 5) {
                        Image(systemName: "doc.text")
                        Text(a.name).lineLimit(1)
                        Text("~\(a.estimatedTokens)t")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button {
                            attachments.removeAll { $0.id == a.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .help(loc.t("Quitar este archivo.", "Remove this file."))
                    }
                    .font(.caption)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                    .help(loc.t("Se enviará al modelo junto con tu mensaje (~\(a.estimatedTokens) tokens).",
                                "Sent to the model along with your message (~\(a.estimatedTokens) tokens)."))
                }
                if attachmentsTooLarge {
                    Label(loc.t("Adjuntos grandes: pueden llenar el contexto",
                                "Large attachments: they may fill the context"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                        .help(loc.t("El total estimado supera la mitad del contexto configurado en Ajustes.",
                                    "The estimated total exceeds half the context configured in Settings."))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attachmentsTooLarge: Bool {
        contextLimit > 0 && attachments.reduce(0) { $0 + $1.estimatedTokens } > contextLimit / 2
    }

    /// A multiline TextField re-measures its whole contents on every
    /// keystroke, so a large pasted blob makes typing crawl. Fold it into an
    /// attachment chip instead; it still reaches the model verbatim.
    private func absorbLargeDraft(_ value: String) {
        guard value.count > 4000 else { return }
        let base = loc.t("Texto pegado", "Pasted text")
        let existing = attachments.filter { $0.name.hasPrefix(base) }.count
        let name = existing == 0 ? base + ".txt" : "\(base) \(existing + 1).txt"
        attachments.append(ChatAttachment(name: name, content: value))
        draft = ""
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { addAttachments(urls: panel.urls) }
    }

    private func addAttachments(urls: [URL]) {
        attachError = nil
        for url in urls {
            guard let data = try? Data(contentsOf: url), data.count <= 512 * 1024,
                  !data.prefix(8192).contains(0),
                  let text = String(data: data, encoding: .utf8) else {
                attachError = loc.t("\(url.lastPathComponent): solo archivos de texto de hasta 512 KB",
                                    "\(url.lastPathComponent): only text files up to 512 KB")
                continue
            }
            guard !attachments.contains(where: { $0.name == url.lastPathComponent && $0.content == text }) else { continue }
            attachments.append(ChatAttachment(name: url.lastPathComponent, content: text))
        }
    }

    /// One slim line above the composer; present only while there is
    /// something to report, so the chat keeps a clean look at rest.
    @ViewBuilder
    private var statusStrip: some View {
        if chat.generating || chat.compacting || chat.contextUsed != nil {
            HStack(spacing: 12) {
                if chat.compacting {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text(loc.t("Compactando…", "Compacting…"))
                            .foregroundStyle(.secondary)
                    }
                    .help(loc.t("Resumiendo los mensajes antiguos con el modelo para liberar contexto.",
                                "Summarizing older messages with the model to free context."))
                }

                if let used = chat.contextUsed, contextLimit > 0 {
                    let fraction = Double(used) / Double(contextLimit)
                    HStack(spacing: 5) {
                        Label(loc.t("Contexto", "Context"), systemImage: "memorychip")
                            .foregroundStyle(.secondary)
                        ProgressView(value: min(fraction, 1))
                            .frame(width: 76)
                            .tint(fraction > 0.9 ? .red : fraction > 0.8 ? .orange : .accentColor)
                        Text("\(used / 1000)k / \(contextLimit / 1000)k")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(fraction > 0.8 ? .orange : .secondary)
                    }
                    .help(loc.t("Tokens usados por el historial y la última respuesta. Al superar 70%, la app intenta resumir los turnos antiguos.",
                                "Tokens used by history and the latest response. Past 70%, the app attempts to summarize older turns."))
                }

                if contextMaySlowGeneration && chat.canCompactCurrent {
                    Button {
                        chat.compactCurrent(port: port)
                    } label: {
                        Label(loc.t("Recuperar velocidad", "Recover speed"),
                              systemImage: "archivebox")
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.borderless)
                    .help(loc.t("Resume el historial completado para que el próximo turno procese menos contexto. El chat completo sigue visible y guardado.",
                                "Summarizes completed history so the next turn processes less context. The full chat remains visible and saved."))
                }

                Spacer(minLength: 0)
                LiveSpeedBadge(live: chat.live)
            }
            .font(.caption)
        }
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
        guard canSend else { return }
        draft = ""
        let files = attachments
        attachments = []
        attachError = nil
        pinnedToBottom = true
        chat.send(text: text, attachments: files, port: port, temperature: temperature,
                  maxTokens: maxTokens, system: systemPrompt, thinking: thinkingEnabled)
    }
}

// MARK: - Message bubble

struct MessageBubble: View, Equatable {
    let message: ChatMessage
    let streaming: Bool
    let liveSpeed: Double?
    let isLastAssistant: Bool
    let isLastUser: Bool
    let canRegenerate: Bool
    let onRegenerate: () -> Void
    let onEdit: () -> Void

    // Skips re-rendering finished bubbles while another one streams; without
    // this every visible bubble re-parses its markdown on each flush. The
    // closures are excluded: their behavior never varies for a given message.
    static func == (a: MessageBubble, b: MessageBubble) -> Bool {
        a.message == b.message && a.streaming == b.streaming
            && a.liveSpeed == b.liveSpeed && a.isLastAssistant == b.isLastAssistant
            && a.isLastUser == b.isLastUser && a.canRegenerate == b.canRegenerate
    }

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
                    if let files = message.attachments, !files.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(files) { a in
                                Label(a.name, systemImage: "doc.text")
                                    .font(.caption)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(.quaternary.opacity(0.7), in: Capsule())
                                    .help(loc.t("Archivo enviado al modelo en este turno (~\(a.estimatedTokens) tokens).",
                                                "File sent to the model this turn (~\(a.estimatedTokens) tokens)."))
                            }
                        }
                    }
                    let parts = message.parts
                    let isThinkingLive = streaming && parts.body.isEmpty && parts.thinking != nil
                    if let think = parts.thinking, !think.isEmpty {
                        DisclosureGroup(isExpanded: $thinkExpanded) {
                            if thinkExpanded {
                                Text(think)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        } label: {
                            Label(isThinkingLive ? loc.t("Razonando…", "Thinking…")
                                                 : loc.t("Razonamiento", "Reasoning"),
                                  systemImage: "brain")
                                .font(.caption).foregroundStyle(.blue)
                        }
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

/// Position of the transcript's bottom sentinel within the scroll viewport,
/// used to detect whether the user is at the bottom (auto-follow) or reading
/// older messages (no scroll hijacking).
private struct BottomMarkerKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Hosts the in-progress assistant bubble: the only transcript view that
/// observes LiveStream, so per-flush updates re-render just this subtree.
private struct StreamingBubble: View {
    @ObservedObject var live: LiveStream
    let message: ChatMessage
    let onGrow: () -> Void

    private var liveMessage: ChatMessage {
        var m = message
        if live.hasReasoning {
            m.content = "<think>" + live.displayedReasoning
                + (live.visibleText.isEmpty ? "" : "</think>" + live.visibleText)
        } else {
            m.content = live.visibleText
        }
        return m
    }

    var body: some View {
        StreamingMessageBubble(live: live, message: liveMessage)
            .onChange(of: live.visibleText) { _, _ in onGrow() }
    }
}

/// Streaming-only bubble. Reasoning stays collapsed and its growing text is
/// not published or laid out unless the user explicitly opens it.
private struct StreamingMessageBubble: View {
    @ObservedObject var live: LiveStream
    let message: ChatMessage
    @EnvironmentObject var loc: Localizer

    private var reasoningBinding: Binding<Bool> {
        Binding(get: { live.reasoningExpanded },
                set: { live.setReasoningExpanded($0) })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 13))
                .foregroundStyle(.pink)
                .frame(width: 26, height: 26)
                .background(.pink.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Asistente").font(.caption.weight(.medium))
                    Text(message.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    if live.hasReasoning {
                        DisclosureGroup(isExpanded: reasoningBinding) {
                            if live.reasoningExpanded {
                                Text(live.displayedReasoning)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Label(live.visibleText.isEmpty ? loc.t("Razonando…", "Thinking…")
                                                               : loc.t("Razonamiento", "Reasoning"),
                                      systemImage: "brain")
                                if live.reasoningExpanded && live.visibleText.isEmpty {
                                    Text(loc.t("actualización ligera", "light updates"))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .font(.caption).foregroundStyle(.blue)
                        }
                    }

                    if !live.visibleText.isEmpty {
                        RichText(text: live.visibleText)
                    }

                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        if let speed = live.speed {
                            Text(String(format: "%.1f t/s", speed))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }

            Spacer(minLength: 70)
        }
    }
}

/// Observes LiveStream on its own so the t/s readout updates per flush
/// without re-evaluating the whole input bar.
private struct LiveSpeedBadge: View {
    @ObservedObject var live: LiveStream

    var body: some View {
        if let speed = live.speed {
            Text(String(format: "%.1f t/s", speed))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.pink)
        }
    }
}

// MARK: - Markdown rendering

private enum MDBlock {
    case paragraph(String)
    case header(Int, String)
    case bullet([String])
    case numbered([String])
    case code(String, String)   // language, content
    case quote(String)
    case table([String], [[String]])   // headers, rows
    case rule
}

struct RichText: View {
    let text: String

    var body: some View {
        let blocks = Self.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            // Positional identity: content-derived ids would change on every
            // streamed token, tearing the last block's views down each flush.
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
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
                                if let done = Self.taskState(item) {
                                    Image(systemName: done ? "checkmark.square" : "square")
                                        .font(.callout).foregroundStyle(.secondary)
                                    Text(Self.inline(String(item.dropFirst(4)))).textSelection(.enabled)
                                } else {
                                    Text("•").foregroundStyle(.secondary)
                                    Text(Self.inline(item)).textSelection(.enabled)
                                }
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
                case .table(let headers, let rows):
                    MDTable(headers: headers, rows: rows)
                case .rule:
                    Divider().padding(.vertical, 2)
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
            } else if let m = l.range(of: #"^#{1,6} "#, options: .regularExpression) {
                flush()
                let level = l[..<m.upperBound].filter { $0 == "#" }.count
                blocks.append(.header(level, String(l[m.upperBound...])))
            } else if l.hasPrefix(">") {
                flush()
                var quoteLines = [stripQuote(l)]
                while let next = lines.first, next.hasPrefix(">") {
                    quoteLines.append(stripQuote(String(next)))
                    lines = lines.dropFirst()
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
            } else if let headers = tableCells(l),
                      let sep = lines.first, isTableSeparator(String(sep)) {
                flush()
                lines = lines.dropFirst()
                var rows: [[String]] = []
                while let next = lines.first, let cells = tableCells(String(next)) {
                    rows.append(cells)
                    lines = lines.dropFirst()
                }
                blocks.append(.table(headers, rows))
            } else if l.range(of: #"^\s*([-*_])(\s*\1){2,}\s*$"#, options: .regularExpression) != nil {
                flush()
                blocks.append(.rule)
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

    private static func stripQuote(_ line: String) -> String {
        var s = line
        if s.hasPrefix("> ") { s.removeFirst(2) } else if s.hasPrefix(">") { s.removeFirst() }
        return s
    }

    /// "[ ] item" / "[x] item" → checkbox state, nil for regular bullets.
    fileprivate static func taskState(_ item: String) -> Bool? {
        if item.hasPrefix("[ ] ") { return false }
        if item.hasPrefix("[x] ") || item.hasPrefix("[X] ") { return true }
        return nil
    }

    /// Splits a `| a | b |` line into trimmed cells; nil when it has no pipes.
    private static func tableCells(_ line: String) -> [String]? {
        var t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("|") else { return nil }
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        let cells = t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.isEmpty ? nil : cells
    }

    /// `|---|:---:|` style separator under the header row.
    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.contains("-") && t.contains("|")
            && t.range(of: #"^[\s|:\-]+$"#, options: .regularExpression) != nil
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Markdown pipe table rendered as a grid: bold header, hairline divider and
/// striped rows, selectable text.
private struct MDTable: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                    Text(RichText.inline(h))
                        .fontWeight(.semibold)
                        .padding(.vertical, 6)
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                GridRow {
                    ForEach(0..<headers.count, id: \.self) { c in
                        Text(RichText.inline(c < row.count ? row[c] : ""))
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(i.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.07))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .textSelection(.enabled)
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
