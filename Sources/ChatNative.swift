import SwiftUI
import PDFKit
import Vision

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
    // Attached images as data URIs (data:image/jpeg;base64,…) for vision models.
    var imageURIs: [String]? = nil

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
    @Published var reasoningTail = ""
    @Published var hasReasoning = false
    @Published var reasoningExpanded = false
    @Published var speed: Double?
    /// Prompt-processing progress 0…1 before the first token; nil otherwise.
    @Published var prefillProgress: Double?

    private var latestReasoning = ""
    private var lastReasoningPublish = Date.distantPast
    private let reasoningPublishInterval: TimeInterval = 0.5
    private var lastTailPublish = Date.distantPast
    private let tailPublishInterval: TimeInterval = 0.3

    func reset() {
        visibleText = ""
        displayedReasoning = ""
        reasoningTail = ""
        hasReasoning = false
        reasoningExpanded = false
        latestReasoning = ""
        lastReasoningPublish = .distantPast
        lastTailPublish = .distantPast
        speed = nil
        prefillProgress = nil
    }

    func setPrefillProgress(_ p: Double?) {
        if prefillProgress != p { prefillProgress = p }
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
        // One-line live tail so collapsed "Thinking…" visibly progresses (cheap).
        if !reasoningExpanded, visible.isEmpty, !reasoning.isEmpty,
           now.timeIntervalSince(lastTailPublish) >= tailPublishInterval {
            let tail = Self.tailSnippet(reasoning)
            if reasoningTail != tail { reasoningTail = tail }
            lastTailPublish = now
        }
        if visibleText != visible { visibleText = visible }
        if let speed { self.speed = speed }
    }

    /// Tail of the reasoning as one flowing line, capped to recent chars at a
    /// word boundary, so the peek scrolls continuously instead of jumping lines.
    private static func tailSnippet(_ s: String, limit: Int = 200) -> String {
        let flat = s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "  ")
        if flat.count <= limit { return flat }
        var cut = String(flat.suffix(limit))
        if let space = cut.firstIndex(of: " ") { cut = String(cut[cut.index(after: space)...]) }
        return "… " + cut
    }

    func setReasoningExpanded(_ expanded: Bool, now: Date = Date()) {
        reasoningExpanded = expanded
        displayedReasoning = expanded ? latestReasoning : ""
        lastReasoningPublish = expanded ? now : .distantPast
    }
}

/// Thread-safe hand-off of the latest streaming snapshot from the off-main SSE
/// reader (writer) to the main-actor display pump (reader). The reader writes
/// without ever awaiting the main actor, so a slow render cannot stop it from
/// draining the socket. Previously the reader awaited `MainActor.run` on every
/// flush; when a frame was expensive (a long transcript), the reader stopped
/// reading, the TCP buffer filled, and llama-server blocked on send — stalling
/// its decode in multi-second bursts. Decoupling removes that backpressure.
final class StreamBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var reasoning = ""
    private var visible = ""
    private var speed: Double?
    private var progress: Double?
    private var dirty = false
    private var done = false

    func write(reasoning: String, visible: String, speed: Double?) {
        lock.lock()
        self.reasoning = reasoning
        self.visible = visible
        if let speed { self.speed = speed }
        dirty = true
        lock.unlock()
    }

    func writeProgress(_ p: Double?) {
        lock.lock(); progress = p; dirty = true; lock.unlock()
    }

    func finish() {
        lock.lock(); done = true; dirty = true; lock.unlock()
    }

    /// The latest snapshot if it changed since the last take (or the stream
    /// ended); nil when there is nothing new to render.
    func take() -> (reasoning: String, visible: String, speed: Double?, progress: Double?, done: Bool)? {
        lock.lock(); defer { lock.unlock() }
        guard dirty else { return nil }
        dirty = false
        return (reasoning, visible, speed, progress, done)
    }
}

@MainActor
final class ChatStore: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var currentID: UUID?
    @Published var generating = false
    /// Conversation currently streaming, so its live bubble only shows there.
    @Published var generatingConvID: UUID?
    @Published var compacting = false
    @Published var lastError: String?
    let live = LiveStream()
    /// Streaming uses a dedicated session, not URLSession.shared, so the long
    /// idle timeout actually applies. A per-request `timeoutInterval` is
    /// unreliable on the shared session (its 60s `timeoutIntervalForRequest`
    /// effectively wins), which dropped the connection mid-prefill whenever the
    /// first token took longer than ~60s (a long prompt re-processing). The
    /// server's own read/write timeout is an hour, so the client was the one
    /// giving up — hence llama-server's "cancelled after 30s" warning.
    static let streamingSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 600   // idle between bytes (covers a slow first token)
        cfg.timeoutIntervalForResource = 3600
        return URLSession(configuration: cfg)
    }()
    /// Tokens of context consumed by the last exchange (prompt + completion),
    /// reported by the server. Drives the context-usage bar.
    @Published var contextUsed: Int?

    private var task: Task<Void, Never>?
    // Watchdog: large MoE models with CPU offload can deadlock the AMD Metal
    // driver mid-generation (process stuck in uninterruptible wait, 0% CPU).
    // We detect the stall, stop the engine to free memory, and report it.
    private var watchdog: Task<Void, Never>?
    private var lastStreamActivity = Date()
    private var sawFirstToken = false
    /// Which conversation's KV is currently loaded in the engine's slot 0, when
    /// disk cache persistence is on. Reset to nil whenever a fresh engine starts
    /// (empty slots), so the next turn restores the active conversation.
    private var slotConvID: UUID?

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
        pruneOrphanSlots()
        // A fresh engine has empty KV slots: forget which conversation slot 0
        // held, so the next turn restores the active one's persisted cache.
        NotificationCenter.default.addObserver(forName: .engineDidStart, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.slotConvID = nil }
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
        // Drop its persisted KV slot file too, and forget it if it was loaded.
        try? FileManager.default.removeItem(
            at: ServerSettings.primarySlotCacheDir.appendingPathComponent(Self.slotFile(c.id)))
        if slotConvID == c.id { slotConvID = nil }
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

    func send(text: String, attachments: [ChatAttachment] = [], images: [String] = [],
              port: Int, temperature: Double,
              maxTokens: Int, system: String, thinking: Bool) {
        guard !generating, let i = currentIndex else { return }
        lastError = nil
        conversations[i].messages.append(ChatMessage(role: "user", content: text,
                                                     attachments: attachments.isEmpty ? nil : attachments,
                                                     imageURIs: images.isEmpty ? nil : images))
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
        generatingConvID = conversations[i].id
        live.reset()
        startWatchdog(port: port)
        // The user can switch or delete conversations mid-stream; the result
        // must land in the one this request started from, found by id.
        let convID = conversations[i].id

        var history = Self.requestHistory(system: system,
                                          summary: conversations[i].summary,
                                          messages: conversations[i].messages,
                                          from: conversations[i].summarizedCount ?? 0)

        // Disabling reasoning: `enable_thinking:false` (below) is a Qwen chat-
        // template kwarg that some reasoning models ignore, so they keep
        // thinking. The Qwen-family soft switch `/no_think`, appended to the
        // last user turn, disables it even when the template doesn't; other
        // models simply ignore the trailing token. Belt-and-braces — only sent
        // for this request, never persisted to the visible conversation.
        if !thinking, let last = history.lastIndex(where: { ($0["role"] as? String) == "user" }) {
            if let s = history[last]["content"] as? String {
                history[last]["content"] = s + "\n/no_think"
            } else if var parts = history[last]["content"] as? [[String: Any]] {
                if let ti = parts.firstIndex(where: { ($0["type"] as? String) == "text" }) {
                    parts[ti]["text"] = ((parts[ti]["text"] as? String) ?? "") + "\n/no_think"
                } else {
                    parts.insert(["type": "text", "text": "/no_think"], at: 0)
                }
                history[last]["content"] = parts
            }
        }

        conversations[i].messages.append(ChatMessage(role: "assistant", content: ""))

        let buffer = StreamBuffer()
        // Main-actor display pump: the ONLY thing that touches the UI during
        // streaming. It pulls the latest snapshot at a length-scaled rate and
        // drops intermediate frames, so render cost stays off the reader's
        // path. The reader (below) just writes to `buffer` and never awaits the
        // main actor — that is what keeps a slow frame from backpressuring the
        // socket and stalling the engine's decode.
        let pump = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let snap = buffer.take() else {
                    try? await Task.sleep(for: .milliseconds(40))
                    continue
                }
                if snap.done { break }   // finish() publishes the final transcript
                self?.live.update(reasoning: snap.reasoning, visible: snap.visible, speed: snap.speed)
                let prefilling = snap.reasoning.isEmpty && snap.visible.isEmpty
                self?.live.setPrefillProgress(prefilling ? snap.progress : nil)
                self?.noteStreamActivity()
                let n = snap.visible.count
                let ms = n > 12000 ? 600 : n > 6000 ? 350 : n > 2500 ? 180 : 80
                try? await Task.sleep(for: .milliseconds(ms))
            }
        }

        // Detached: SSE parsing must stay off the main actor, otherwise UI
        // rendering throttles token consumption on long responses and the
        // measured t/s drops even though the server keeps generating.
        task = Task.detached(priority: .userInitiated) { [weak self, buffer, pump] in
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

            // Hands the latest snapshot to the display pump at most ~12 Hz.
            // Non-blocking: it only writes to the lock-protected buffer, never
            // awaits the main actor — so the reader keeps draining the socket
            // even while a frame renders. Throttling here (rather than writing
            // every token) also keeps `visible`'s COW append amortized O(1):
            // the buffer shares the string only once per interval.
            func flush() {
                let now = Date()
                let interval: TimeInterval = {
                    let n = visible.count
                    return n > 12000 ? 0.6 : n > 6000 ? 0.35 : n > 2500 ? 0.18 : 0.08
                }()
                guard now.timeIntervalSince(lastFlush) > interval else { return }
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
                buffer.write(reasoning: reasoning, visible: visible, speed: speed)
            }

            do {
                // Restore this conversation's persisted KV (if any) so the slot
                // holds the unchanged history and only the new turn is prefilled.
                await self?.prepareSlot(convID: convID, port: port)

                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                // Idle timeout between SSE packets. A long prompt re-processing
                // can take minutes with no token arriving; the effective idle
                // timeout comes from streamingSession's config (600s) — this
                // per-request value is a belt-and-suspenders match.
                req.timeoutInterval = 600
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
                    // Stream prompt-processing progress (in `prompt_progress`).
                    "return_progress": true,
                ]
                if !thinking {
                    body["chat_template_kwargs"] = ["enable_thinking": false]
                }
                // Pin to slot 0 so the saved/restored KV always matches the chat.
                if self?.slotPersistEnabled == true { body["id_slot"] = 0 }
                req.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (bytes, response) = try await ChatStore.streamingSession.bytes(for: req)
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

                    // {total, cache, processed, time_ms} → processed/total bar.
                    if let pp = obj["prompt_progress"] as? [String: Any],
                       let processed = pp["processed"] as? Int,
                       let totalTok = pp["total"] as? Int, totalTok > 0 {
                        buffer.writeProgress(min(1.0, Double(processed) / Double(totalTok)))
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
                        flush()
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

            // Tell the pump to stop; the final transcript is published below.
            buffer.finish()

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
            // Persist the conversation's KV after a real answer, so reopening it
            // (or restarting the engine) skips re-prefilling the history.
            if !wasCancelled && !didReportError && hasVisibleAnswer {
                await self?.saveSlot(convID: convID, port: port)
            }
            pump.cancel()
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
        generatingConvID = nil
        live.reset()
        task = nil
        watchdog?.cancel()
        watchdog = nil
        save()
    }

    // MARK: KV slot persistence (turbo engine)

    /// On when the disk-cache setting is enabled and the turbo engine is selected
    /// (the only engine where slot save/restore is fast on AMD). Read live from
    /// defaults so toggling it in Settings takes effect on the next turn.
    nonisolated var slotPersistEnabled: Bool {
        let d = UserDefaults.standard
        guard d.bool(forKey: SettingsKeys.persistCache) else { return false }
        guard ServerSettings.isTurbo(d.string(forKey: SettingsKeys.serverBinary) ?? "") else { return false }
        return ServerSettings.mmprojPath(forModel: d.string(forKey: SettingsKeys.modelPath) ?? "") == nil
    }

    nonisolated private static func slotFile(_ id: UUID) -> String { "\(id.uuidString).bin" }

    /// POST /slots/0?action=save|restore (best-effort; a missing file on restore
    /// just means a cold prefill, which is harmless).
    nonisolated private func slotAction(_ action: String, convID: UUID, port: Int) async {
        guard var comps = URLComponents(string: "http://127.0.0.1:\(port)/slots/0") else { return }
        comps.queryItems = [URLQueryItem(name: "action", value: action)]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = ServerSettings.activeAPIKey() {
            req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["filename": Self.slotFile(convID)])
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Before a turn: if slot 0 doesn't already hold this conversation, restore
    /// its persisted KV so only the new tokens get prefilled.
    func prepareSlot(convID: UUID, port: Int) async {
        guard slotPersistEnabled, slotConvID != convID else { return }
        await slotAction("restore", convID: convID, port: port)
        slotConvID = convID
    }

    /// After a turn completes: persist the conversation's KV to disk.
    nonisolated func saveSlot(convID: UUID, port: Int) async {
        guard slotPersistEnabled else { return }
        await slotAction("save", convID: convID, port: port)
    }

    /// Drop slot files with no matching conversation (deleted while disabled, or
    /// left over). Bounds disk use to the conversations that still exist.
    private func pruneOrphanSlots() {
        let dir = ServerSettings.primarySlotCacheDir
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let ids = Set(conversations.map { $0.id.uuidString })
        for f in files where f.pathExtension == "bin" {
            let base = f.deletingPathExtension().lastPathComponent
            // Only prune per-conversation slot files (named by UUID); leave other
            // files like the external-client prefix (external.bin) untouched.
            guard UUID(uuidString: base) != nil else { continue }
            if !ids.contains(base) { try? FileManager.default.removeItem(at: f) }
        }
    }

    // MARK: stall watchdog

    /// Called from the stream whenever a token reaches the UI; resets the
    /// inactivity timer and marks that generation (not prefill) has begun.
    func noteStreamActivity() {
        lastStreamActivity = Date()
        sawFirstToken = true
    }

    private func startWatchdog(port: Int) {
        watchdog?.cancel()
        lastStreamActivity = Date()
        sawFirstToken = false
        watchdog = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.generating else { return }
                let idle = Date().timeIntervalSince(self.lastStreamActivity)
                // Before the first token the engine may be doing a long
                // prefill, so allow a generous grace period; once tokens flow,
                // a 30 s gap means it deadlocked rather than merely slowed.
                let limit: TimeInterval = self.sawFirstToken ? 30 : 180
                if idle > limit {
                    self.handleStreamStall()
                    return
                }
            }
        }
    }

    /// The engine stopped producing tokens while alive: treat it as a driver
    /// deadlock, stop the engine to free its memory, and tell the user.
    private func handleStreamStall() {
        AppLog.chat.error("stream stalled; stopping engine")
        task?.cancel()
        task = nil
        watchdog = nil
        ServerManager.shared.active.stop()
        lastError = Self.stallMessage
        generating = false
        generatingConvID = nil
        live.reset()
        save()
    }

    nonisolated static var stallMessage: String {
        "El motor dejó de responder y se detuvo para liberar memoria. Suele pasar con modelos MoE grandes en GPU AMD: usa un modelo denso (8B) o sube 'Expertos MoE en CPU'. / The engine stopped responding and was stopped to free memory. This happens with large MoE models on AMD GPUs: use a dense model (8B) or raise 'MoE experts on CPU'."
    }

    // MARK: auto-compaction

    /// Builds the wire history: system prompt with the rolling summary of
    /// compacted turns folded in, then the messages that remain uncompacted,
    /// stripped of reasoning blocks (saves context).
    nonisolated static func requestHistory(system: String, summary: String?,
                                           messages: [ChatMessage], from start: Int) -> [[String: Any]] {
        var history: [[String: Any]] = []
        var sys = system.trimmingCharacters(in: .whitespaces)
        if let summary, !summary.isEmpty {
            sys += (sys.isEmpty ? "" : "\n\n")
                + "Summary of the earlier part of this conversation:\n" + summary
        }
        if !sys.isEmpty { history.append(["role": "system", "content": sys]) }
        let safeStart = min(max(0, start), messages.count)
        history += messages[safeStart...].compactMap { m -> [String: Any]? in
            let text = m.role == "assistant" ? m.parts.body : m.wireContent
            guard m.role != "assistant"
                    || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            // A user turn with images uses the OpenAI multimodal content array
            // (text part + image_url parts); everything else stays a plain string.
            if m.role == "user", let imgs = m.imageURIs, !imgs.isEmpty {
                var parts: [[String: Any]] = []
                if !text.isEmpty { parts.append(["type": "text", "text": text]) }
                for uri in imgs { parts.append(["type": "image_url", "image_url": ["url": uri]]) }
                return ["role": m.role, "content": parts]
            }
            return ["role": m.role, "content": text]
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
            return "Contexto lleno: el mensaje, los archivos adjuntos y el historial juntos superan el contexto. Sube el contexto en Ajustes, adjunta menos o inicia un chat nuevo / context full: your message, attached files and history together exceed the context. Raise the context size in Settings, attach less, or start a new chat"
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

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        task?.cancel()
    }

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

/// The chat detail: transcript and composer. The conversation list lives in
/// `ConversationListView` (the split-view sidebar); both share the ChatStore
/// from the environment, injected by ChatMainView.
struct NativeChatView: View {
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var chat: ChatStore
    @AppStorage(SettingsKeys.chatTemp) private var temperature = 0.7
    @AppStorage(SettingsKeys.chatMaxTokens) private var maxTokens = 2048
    @AppStorage(SettingsKeys.chatSystem) private var systemPrompt = ""
    @AppStorage(SettingsKeys.chatThinking) private var thinkingEnabled = true
    @AppStorage(SettingsKeys.port) private var port = 8080
    @AppStorage(SettingsKeys.ctx) private var contextLimit = 16384
    @State private var draft = ""
    @State private var attachments: [ChatAttachment] = []
    @State private var images: [String] = []   // attached images as data URIs (vision models)
    @State private var attachError: String?
    @State private var ocrPending = 0
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""
    @State private var showSystem = false
    // True while the newest message is on screen (inverted scroll rests here).
    @State private var atBottom = true
    @FocusState private var inputFocused: Bool

    private var maxTokenOptions: [Int] {
        [512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072].filter { $0 <= contextLimit }
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
        chatColumn
            .onAppear { inputFocused = true }
            // Markdown links: open valid web/mail URLs in the default browser
            // and silently drop malformed ones (e.g. placeholder "#" links),
            // instead of the system's "can't open the application (-50)" dialog.
            .environment(\.openURL, OpenURLAction { url in
                let raw = url.scheme == nil ? "https://\(url.absoluteString)" : url.absoluteString
                guard let target = URL(string: raw), let scheme = target.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" || scheme == "mailto",
                      target.host != nil || scheme == "mailto" else { return .discarded }
                NSWorkspace.shared.open(target)
                return .handled
            })
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

    // Inverted scroll: the whole stack and every row are flipped, and messages
    // are listed newest-first, so the conversation's end sits at the scroll's
    // natural origin. Opening, following the stream and scrolling up to read all
    // work without any scrollTo or anchor management — the pattern messaging apps
    // use. Avoids the LazyVStack + scrollPosition blank bug (FB/Apple thread).
    private var messagesScroll: some View {
        let messages = chat.current?.messages ?? []
        let newestID = messages.last?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    Color.clear.frame(height: 1).id(Self.bottomID)
                    if let err = chat.lastError {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.red)
                            .flippedUpsideDown()
                    }
                    ForEach(messages.reversed()) { msg in
                        messageRow(msg, isNewest: msg.id == newestID)
                            .flippedUpsideDown()
                            .id(msg.id)
                            .onAppear { if msg.id == newestID { atBottom = true } }
                            .onDisappear { if msg.id == newestID { atBottom = false } }
                    }
                }
                .padding()
            }
            .flippedUpsideDown()
            .overlay {
                if messages.isEmpty { emptyChatState }
            }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom { jumpToBottomButton { proxy.scrollTo(Self.bottomID) } }
            }
            .onChange(of: chat.currentID) { _, _ in
                atBottom = true
                proxy.scrollTo(Self.bottomID)
                inputFocused = true
            }
            // A new turn (send/regenerate) jumps to the bottom.
            .onChange(of: chat.current?.messages.last?.id) { _, _ in
                atBottom = true
                proxy.scrollTo(Self.bottomID)
            }
        }
    }

    private static let bottomID = "convBottom"

    @ViewBuilder
    private func messageRow(_ msg: ChatMessage, isNewest: Bool) -> some View {
        let isLastUser = msg.role == "user"
            && msg.id == chat.current?.messages.last(where: { $0.role == "user" })?.id
        VStack(alignment: .leading, spacing: 14) {
            if msg.id == compactionBoundaryID {
                Label(loc.t("Mensajes anteriores resumidos para liberar contexto",
                            "Earlier messages summarized to free context"),
                      systemImage: "archivebox")
                    .font(.caption2).foregroundStyle(.secondary)
                    .help(loc.t("Lo anterior a esta marca se envía al modelo como un resumen automático; aquí sigue visible íntegro.",
                                "History above this mark is sent to the model as an automatic summary; it remains fully visible here."))
            }
            if chat.generating && chat.current?.id == chat.generatingConvID
                && isNewest && msg.role == "assistant" {
                StreamingBubble(live: chat.live, message: msg) { }
            } else {
                MessageBubble(
                    message: msg,
                    streaming: false,
                    liveSpeed: nil,
                    isLastAssistant: msg.role == "assistant" && isNewest,
                    isLastUser: isLastUser,
                    canRegenerate: !chat.generating,
                    onRegenerate: {
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
            }
        }
    }

    private func jumpToBottomButton(_ action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.25)) { action() }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .glassSurface(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .padding(14)
        .help(loc.t("Ir al final de la conversación y seguir la respuesta.",
                    "Jump to the end of the conversation and follow the response."))
    }

    private var emptyChatState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(.pink.opacity(0.8))
            Text(loc.t("¿En qué puedo ayudarte?", "What can I help with?"))
                .font(.title2.weight(.semibold))
            Text(loc.t("Todo se genera en tu GPU, sin salir de tu equipo. Adjunta código, texto o PDF con el clip para preguntar sobre ellos.",
                       "Everything runs on your GPU, never leaving your machine. Attach code, text or PDF files with the paperclip to ask about them."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }

    // MARK: input

    private var inputArea: some View {
        VStack(spacing: 8) {
            statusStrip
            if !attachments.isEmpty { attachmentChips }
            if !images.isEmpty { imageChips }
            if ocrPending > 0 {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(loc.t("Extrayendo texto de PDF escaneado por OCR…",
                               "Extracting text from scanned PDF via OCR…"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
                    .glassSurface(in: RoundedRectangle(cornerRadius: 20), interactive: true)
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
        !chat.generating && ocrPending == 0
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty || !images.isEmpty)
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
            .infoTip(loc.t("Los modelos razonadores piensan antes de responder (esos tokens cuentan dentro del límite de respuesta). Al desactivarlo se envía enable_thinking:false y /no_think; algunos modelos entrenados solo para razonar (p. ej. R1) pueden seguir pensando de todos modos.",
                        "Reasoning models think before answering (those tokens count toward the response limit). Turning it off sends enable_thinking:false and /no_think; some reasoning-only models (e.g. R1) may still think regardless."))

            HStack(spacing: 8) {
                Label(loc.t("Creatividad", "Creativity"), systemImage: "dial.medium")
                Slider(value: $temperature, in: 0...1.5)
                Text(String(format: "%.2f", temperature))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 34)
            }
            .infoTip(loc.t("Temperatura: 0 = más determinista; valores altos = respuestas más variadas.",
                        "Temperature: 0 = more deterministic; higher values = more varied responses."))

            Picker(selection: $maxTokens) {
                ForEach(maxTokenOptions, id: \.self) { Text($0.formatted()).tag($0) }
            } label: {
                Label(loc.t("Tokens de respuesta", "Response tokens"),
                      systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            .infoTip(loc.t("Máximo de tokens que el modelo puede generar en este turno, incluyendo razonamiento y respuesta visible. No aumenta el contexto. Recomendado: 2.048–4.096.",
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
                .infoTip(loc.t("Instrucciones permanentes para el modelo.",
                               "Permanent instructions for the model."))
            TextEditor(text: $systemPrompt)
                .font(.system(size: 12))
                .frame(height: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
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
        .help(loc.t("Adjuntar archivos: texto, código y PDF (se extrae su texto; los PDF escaneados por OCR); de otros binarios se extraen las cadenas legibles. Imágenes solo si el modelo tiene visión (su mmproj). También puedes arrastrarlos al área de escritura.",
                    "Attach files: text, code and PDF (text is extracted; scanned PDFs via OCR); other binaries contribute their readable strings. Images only if the model has vision (its mmproj). You can also drag them onto the input area."))
    }

    static func nsImage(fromDataURI uri: String) -> NSImage? {
        guard let comma = uri.firstIndex(of: ","),
              let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }

    private var imageChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(images.enumerated()), id: \.offset) { idx, uri in
                    ZStack(alignment: .topTrailing) {
                        if let img = Self.nsImage(fromDataURI: uri) {
                            Image(nsImage: img).resizable().scaledToFill()
                                .frame(width: 54, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        Button { images.remove(at: idx) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white, .black.opacity(0.55))
                        }
                        .buttonStyle(.plain).padding(2)
                    }
                }
            }
            .padding(.vertical, 2)
        }
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
                if attachmentsExceedContext {
                    Label(loc.t("Adjuntos ~\(attachmentTokens / 1000)k tokens > contexto \(contextLimit / 1000)k: sube el contexto en Ajustes o quita archivos",
                                "Attachments ~\(attachmentTokens / 1000)k tokens > context \(contextLimit / 1000)k: raise the context in Settings or remove files"),
                          systemImage: "exclamationmark.octagon.fill")
                        .font(.caption2).foregroundStyle(.red)
                        .help(loc.t("Lo adjunto no cabe en el contexto configurado, así que el envío fallará con 'contexto lleno'. Sube el contexto en Ajustes, quita archivos o inicia un chat nuevo.",
                                    "The attachments don't fit the configured context, so sending will fail with 'context full'. Raise the context in Settings, remove files or start a new chat."))
                } else if attachmentsTooLarge {
                    Label(loc.t("Adjuntos ~\(attachmentTokens / 1000)k tokens: pueden llenar el contexto (\(contextLimit / 1000)k)",
                                "Attachments ~\(attachmentTokens / 1000)k tokens: may fill the context (\(contextLimit / 1000)k)"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                        .help(loc.t("El total estimado supera la mitad del contexto configurado en Ajustes; con el historial podría llenarlo.",
                                    "The estimated total exceeds half the context configured in Settings; with the history it could fill it."))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attachmentTokens: Int {
        attachments.reduce(0) { $0 + $1.estimatedTokens }
    }

    private var attachmentsTooLarge: Bool {
        contextLimit > 0 && attachmentTokens > contextLimit / 2
    }

    /// The attachments alone already exceed the configured context, so the send
    /// will fail with the server's "context full" error — warn before sending.
    private var attachmentsExceedContext: Bool {
        contextLimit > 0 && attachmentTokens >= contextLimit
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

    // Read cap (raw bytes) and extracted-text cap. Text beyond the latter is
    // truncated with a note; the proactive context warning catches huge totals.
    private static let maxAttachBytes = 12 * 1024 * 1024
    private static let maxAttachChars = 400_000

    private func addAttachments(urls: [URL]) {
        var errors: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url) else {
                errors.append(loc.t("\(name): no se pudo leer", "\(name): couldn't read it")); continue
            }
            guard data.count <= Self.maxAttachBytes else {
                errors.append(loc.t("\(name): demasiado grande (máx 12 MB)", "\(name): too large (max 12 MB)")); continue
            }

            let ext = (name as NSString).pathExtension.lowercased()

            // Images → vision (only if the loaded model has a multimodal projector).
            if ["png", "jpg", "jpeg", "heic", "heif", "gif", "bmp", "tiff", "tif", "webp"].contains(ext) {
                guard visionAvailable else {
                    errors.append(loc.t("\(name): el modelo actual no admite imágenes (carga un modelo con visión y su mmproj)",
                                        "\(name): the current model can't read images (load a vision model with its mmproj)")); continue
                }
                guard let uri = Self.imageDataURI(from: data) else {
                    errors.append(loc.t("\(name): no se pudo procesar la imagen", "\(name): couldn't process the image")); continue
                }
                images.append(uri); continue
            }

            var text: String
            if ext == "pdf" || data.prefix(5) == Data("%PDF-".utf8) {
                guard let pdf = PDFDocument(data: data) else {
                    errors.append(loc.t("\(name): no se pudo abrir el PDF", "\(name): couldn't open the PDF")); continue
                }
                if let s = pdf.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text = s
                } else {
                    // No text layer (scanned PDF) → OCR the page images on-device
                    // (Vision framework), asynchronously so the UI doesn't block.
                    let pendingID = UUID()
                    attachments.append(ChatAttachment(id: pendingID, name: name,
                        content: loc.t("(extrayendo texto por OCR…)", "(extracting text via OCR…)")))
                    ocrPending += 1
                    Task { @MainActor in
                        let ocr = await Self.ocrPDF(data: data, maxPages: 20, maxChars: Self.maxAttachChars)
                        ocrPending -= 1
                        guard let idx = attachments.firstIndex(where: { $0.id == pendingID }) else { return }
                        if ocr.isEmpty {
                            attachments.remove(at: idx)
                            attachError = (attachError.map { $0 + "\n" } ?? "")
                                + loc.t("\(name): el OCR no encontró texto", "\(name): OCR found no text")
                        } else {
                            attachments[idx].content = loc.t("[Texto extraído por OCR — \(name)]\n\n",
                                                             "[Text extracted via OCR — \(name)]\n\n") + ocr
                        }
                    }
                    continue
                }
            } else if let decoded = Self.decodeText(data) {
                text = decoded
            } else {
                // Binary: raw bytes are useless to a text model, so extract its
                // printable strings (symbols, embedded text) instead.
                let s = Self.printableStrings(from: data, limit: Self.maxAttachChars)
                guard !s.isEmpty else {
                    errors.append(loc.t("\(name): binario sin texto legible", "\(name): binary with no readable text")); continue
                }
                text = loc.t("[Cadenas extraídas de un binario — \(name)]\n\n",
                             "[Strings extracted from a binary — \(name)]\n\n") + s
            }

            if text.count > Self.maxAttachChars {
                text = String(text.prefix(Self.maxAttachChars))
                    + loc.t("\n\n[…contenido truncado…]", "\n\n[…content truncated…]")
            }
            guard !attachments.contains(where: { $0.name == name && $0.content == text }) else { continue }
            attachments.append(ChatAttachment(name: name, content: text))
        }
        attachError = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    /// Decode a file as text, trying UTF-8/UTF-16, then a single-byte encoding
    /// (Latin-1/Windows-1252) only when the bytes look like text. Returns nil
    /// for binary data (handled separately via string extraction).
    private static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        let sample = data.prefix(8192)
        if !sample.contains(0) {
            let bad = sample.filter { $0 != 0x09 && $0 != 0x0A && $0 != 0x0D && ($0 < 0x20 || $0 == 0x7F) }.count
            if Double(bad) / Double(max(1, sample.count)) < 0.05 {
                return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
            }
        }
        return nil
    }

    /// True when the loaded model has a paired multimodal projector (vision).
    private var visionAvailable: Bool { ServerSettings.mmprojPath(forModel: modelPath) != nil }

    /// Downscale an image (preserving aspect, max dimension) and re-encode as a
    /// JPEG data URI for the OpenAI multimodal `image_url` field — keeps the
    /// request and the persisted conversation from ballooning.
    private static func imageDataURI(from data: Data, maxDim: CGFloat = 1024) -> String? {
        guard let img = NSImage(data: data),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxDim / max(w, h))
        let nw = max(1, Int(w * scale)), nh = max(1, Int(h * scale))
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let out = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }

    /// OCR a scanned (text-less) PDF on-device with the Vision framework. Renders
    /// each page to a bitmap via Core Graphics (thread-safe, off the main actor)
    /// and recognizes text. Bounded by page and character caps.
    private static func ocrPDF(data: Data, maxPages: Int, maxChars: Int) async -> String {
        await Task.detached(priority: .userInitiated) { () -> String in
            guard let doc = PDFDocument(data: data) else { return "" }
            var out = ""
            for i in 0..<min(doc.pageCount, maxPages) {
                guard let page = doc.page(at: i) else { continue }
                let rect = page.bounds(for: .mediaBox)
                let scale: CGFloat = 2
                let w = Int(rect.width * scale), h = Int(rect.height * scale)
                guard w > 0, h > 0,
                      let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: -rect.minX, y: -rect.minY)
                page.draw(with: .mediaBox, to: ctx)
                guard let cg = ctx.makeImage() else { continue }
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                req.recognitionLanguages = ["es-ES", "en-US"]
                req.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                try? handler.perform([req])
                for obs in req.results ?? [] {
                    if let top = obs.topCandidates(1).first { out += top.string + "\n" }
                }
                if out.count >= maxChars { break }
            }
            return String(out.prefix(maxChars))
        }.value
    }

    /// `strings`-style extraction: runs of >= 4 printable ASCII chars, one per line.
    private static func printableStrings(from data: Data, limit: Int) -> String {
        var out = ""
        var run: [UInt8] = []
        for b in data {
            if b == 0x09 || (b >= 0x20 && b < 0x7F) {
                run.append(b)
            } else {
                if run.count >= 4 { out += String(decoding: run, as: UTF8.self) + "\n" }
                run.removeAll(keepingCapacity: true)
                if out.count >= limit { break }
            }
        }
        if run.count >= 4 && out.count < limit { out += String(decoding: run, as: UTF8.self) }
        return out
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

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        draft = ""
        let files = attachments
        let imgs = images
        attachments = []
        images = []
        attachError = nil
        atBottom = true
        chat.send(text: text, attachments: files, images: imgs, port: port, temperature: temperature,
                  maxTokens: maxTokens, system: systemPrompt, thinking: thinkingEnabled)
    }
}

// MARK: - Conversation list (split-view sidebar)

/// The chat sidebar: new-conversation button, search and the conversation
/// list. A native `List`/`.sidebar` inside the NavigationSplitView so it
/// adopts the system's translucent sidebar — including macOS 26 Liquid Glass —
/// on every supported release.
struct ConversationListView: View {
    @EnvironmentObject var chat: ChatStore
    @EnvironmentObject var loc: Localizer
    @State private var searchText = ""
    @State private var renaming: Conversation?
    @State private var renameText = ""

    private var filtered: [Conversation] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return chat.conversations }
        return chat.conversations.filter { c in
            chat.displayTitle(c).localizedCaseInsensitiveContains(query) ||
            c.messages.contains { $0.content.localizedCaseInsensitiveContains(query) }
        }
    }

    /// Relative timestamp in the app's language, not the system locale — the
    /// default `.formatted(.relative…)` ignores the in-app language toggle.
    private func relativeDate(_ date: Date) -> String {
        date.formatted(Date.RelativeFormatStyle(
            presentation: .named,
            locale: Locale(identifier: loc.isSpanish ? "es" : "en")))
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                chat.newConversation()
            } label: {
                Label(loc.t("Nueva conversación", "New chat"), systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut("n", modifiers: .command)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .help(loc.t("Empieza una conversación nueva (⌘N).", "Start a new conversation (⌘N)."))

            TextField(loc.t("Buscar…", "Search…"), text: $searchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

            List(selection: $chat.currentID) {
                ForEach(filtered) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(chat.displayTitle(c))
                            .lineLimit(1)
                        Text(relativeDate(c.updated))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 5)
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
        .navigationSplitViewColumnWidth(min: 200, ideal: 235, max: 320)
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
}
