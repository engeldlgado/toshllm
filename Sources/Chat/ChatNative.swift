// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import PDFKit
import Vision
import UniformTypeIdentifiers
import AVFoundation

// MARK: - Model

/// A text file attached to a user message: sent to the model as a fenced
/// block, rendered in the transcript as a compact chip.
struct ChatAttachment: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var content: String
    var mimeType: String? = nil
    var dataURI: String? = nil
    var byteCount: Int? = nil
    var durationSeconds: Double? = nil
    var videoFrameArea: Int? = nil

    // mtmd samples video at ~4 fps with no cap; Qwen-VL bills each frame by its
    // pixels (≈1 token / 32x32) up to a per-frame cap.
    private static let videoFPS = 4.0
    private static let videoPixelsPerToken = 1024
    private static let videoMaxTokensPerFrame = 1120

    /// Rough token estimate for context budgeting in the UI: chars/4 for text,
    /// duration-and-resolution based for video (its text content is empty).
    var estimatedTokens: Int {
        if mediaKind == "video", let seconds = durationSeconds, seconds > 0 {
            let area = videoFrameArea ?? Self.videoMaxTokensPerFrame * Self.videoPixelsPerToken
            let perFrame = min(area / Self.videoPixelsPerToken, Self.videoMaxTokensPerFrame)
            return max(1, Int(seconds * Self.videoFPS) * perFrame)
        }
        return max(1, content.count / 4)
    }

    var fenceHint: String { (name as NSString).pathExtension.lowercased() }

    var mediaKind: String? {
        guard let mimeType else { return nil }
        if mimeType.hasPrefix("audio/") { return "audio" }
        if mimeType.hasPrefix("video/") { return "video" }
        return nil
    }

    var base64Payload: String? {
        guard let dataURI, let comma = dataURI.firstIndex(of: ",") else { return nil }
        return String(dataURI[dataURI.index(after: comma)...])
    }

    var audioInputFormat: String {
        let normalized = (mimeType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let waveTypes: Set<String> = [
            "audio/wav", "audio/wave", "audio/x-wav", "audio/x-wave",
            "audio/vnd.wave", "audio/x-pn-wav",
        ]
        return waveTypes.contains(normalized) ? "wav" : "mp3"
    }

    var videoInputFormat: String {
        let normalized = (mimeType ?? "").lowercased()
        if normalized.contains("mp4") { return "mp4" }
        if normalized.contains("ogg") { return "ogg" }
        return "auto"
    }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    let role: String          // user | assistant
    var content: String
    var date = Date()
    var genSpeed: Double?     // t/s for this response
    var mtpAccept: Double?    // MTP acceptance 0-1, when speculation ran
    var timings: ChatTimings? = nil
    var model: String? = nil
    var rawOutput: String? = nil
    var toolCalls: [ChatToolCall]? = nil
    var toolCallID: String? = nil
    // Optional keeps pre-attachment JSON decodable.
    var attachments: [ChatAttachment]? = nil
    // Attached images as data URIs (data:image/jpeg;base64,…) for vision models.
    var imageURIs: [String]? = nil

    var estimatedTokens: Int {
        let text = role == "assistant" ? parts.body : wireContent
        let attached = (attachments ?? []).reduce(0) { $0 + $1.estimatedTokens }
        return max(1, text.count / 4) + attached
    }

    var wireContent: String {
        guard let attachments, !attachments.isEmpty else { return content }
        let blocks = attachments.filter { $0.mediaKind == nil }.map { a in
            "File: \(a.name)\n```\(a.fenceHint)\n\(a.content)\n```"
        }
        return ((blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n\n") + content)
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
    var summary: String?
    var summarizedCount: Int?
    /// Pinned conversations sort first. Optional for backward compatibility
    /// with conversations.json saved by older builds.
    var pinned: Bool? = nil
    /// Project this conversation belongs to; nil = ungrouped. Optionals keep
    /// pre-projects JSON decodable, and older builds ignore the extra keys.
    var projectID: UUID? = nil
    /// Per-conversation system prompt. Empty/nil falls back to the project's,
    /// then to the global one.
    var systemPrompt: String? = nil
    var draft: ChatDraft? = nil
    var branches: [ChatBranch]? = nil
    var activeBranchID: UUID? = nil
    var enabledToolNames: [String]? = nil
    /// Working directory the server tools run in. Empty/nil falls back to the project's.
    var workingDirectory: String? = nil
    /// Ranges the model set aside with memory_archive: still in `messages` and on
    /// disk, just not sent with each request. Optional so older JSON still decodes.
    var archived: [ArchivedBlock]? = nil
    /// Last exchange's context tokens, per chat so the bar follows the open
    /// conversation and persists with the KV cache. Optional for old JSON.
    var contextUsed: Int? = nil
}

struct ChatBranch: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var messages: [ChatMessage]
    var created = Date()
}

extension Conversation {
    mutating func beginAlternativeBranch(messages newMessages: [ChatMessage]) {
        var values = branches ?? []
        if values.isEmpty {
            let original = ChatBranch(name: "Branch 1", messages: messages)
            values.append(original)
            activeBranchID = original.id
        } else if let activeBranchID,
                  let index = values.firstIndex(where: { $0.id == activeBranchID }) {
            values[index].messages = messages
        }
        let branch = ChatBranch(name: "Branch \(values.count + 1)", messages: newMessages)
        values.append(branch)
        branches = values
        activeBranchID = branch.id
        messages = newMessages
    }

    mutating func activateBranch(_ id: UUID) -> Bool {
        guard var values = branches,
              let target = values.firstIndex(where: { $0.id == id }) else { return false }
        if let activeBranchID,
           let current = values.firstIndex(where: { $0.id == activeBranchID }) {
            values[current].messages = messages
        }
        branches = values
        activeBranchID = id
        messages = values[target].messages
        return true
    }
}

/// Folder in the chat sidebar grouping conversations, with its own system
/// prompt inherited by every chat inside.
struct ChatProject: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var systemPrompt: String = ""
    var workingDirectory: String? = nil
    var pinned: Bool? = nil
    /// Sidebar disclosure state, persisted so folders keep their fold.
    var collapsed: Bool? = nil
    var created = Date()
}

struct StreamError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Store with persistence and streaming

/// The live answer as it stood at one instant. Rendering this instead of the
/// live properties keeps the bubble's layout still while generation continues.
struct StreamSnapshot: Equatable {
    let visible: String
    let reasoning: String
    let reasoningTail: String
}

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

    var snapshot: StreamSnapshot {
        StreamSnapshot(visible: visibleText, reasoning: displayedReasoning, reasoningTail: reasoningTail)
    }

    func setPrefillProgress(_ p: Double?) {
        if prefillProgress != p { prefillProgress = p }
    }

    func update(reasoning: String, visible: String, speed: Double?, now: Date = Date()) {
        latestReasoning = reasoning
        if hasReasoning != !reasoning.isEmpty { hasReasoning = !reasoning.isEmpty }
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

private struct AgentRunContext {
    let port: Int
    let temperature: Double
    let maxTokens: Int
    let system: String
    let thinking: Bool
    let sampling: ChatSamplingSettings
    let modalities: ModelModalities?
    var remainingTurns: Int
    var tools: [BuiltinToolInfo]
    var workingDirectory: String?
}

@MainActor
final class ChatStore: ObservableObject {
    nonisolated static func reasoningBudget(for effort: String) -> Int? {
        switch effort {
        case "minimal": 128
        case "low": 512
        case "medium": 2_048
        case "high": 8_192
        default: nil
        }
    }
    private static var configuredAgentTurnLimit: Int {
        max(1, UserDefaults.standard.object(forKey: SettingsKeys.chatAgenticMaxTurns) as? Int ?? 10)
    }

    @Published var conversations: [Conversation] = []
    @Published var projects: [ChatProject] = []
    @Published var currentID: UUID?
    @Published var generating = false
    /// Conversation currently streaming, so its live bubble only shows there.
    @Published var generatingConvID: UUID?
    @Published var compacting = false
    @Published var lastError: String?
    @Published var pendingToolPermission: PendingToolPermission?
    @Published var pendingAgentContinuation: PendingAgentContinuation?
    @Published var queuedMessage: QueuedChatMessage?
    let live = LiveStream()
    static let streamingSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 600   // idle between bytes (covers a slow first token)
        cfg.timeoutIntervalForResource = 3600
        return URLSession(configuration: cfg)
    }()
    /// Context consumed by the current conversation's last exchange; drives the
    /// usage bar. Stored per chat, so switching conversations follows the value.
    var contextUsed: Int? { current?.contextUsed }

    func setContextUsed(_ value: Int?, for id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].contextUsed = value
    }

    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastStreamActivity = Date()
    private var sawFirstToken = false
    private var slotConvID: UUID?
    private var agentContext: AgentRunContext?

    var agentFlowActive: Bool {
        generating || pendingToolPermission != nil || pendingAgentContinuation != nil || agentContext != nil
    }

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ToshLLM")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("conversations.json")
    }

    /// Projects live in their own file so conversations.json keeps its schema
    /// and older builds simply show the flat list.
    private var projectsURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("projects.json")
    }

    init() {
        load()
        Self.live = self
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

    func newConversation(in projectID: UUID? = nil) {
        // Reuse an existing empty conversation in the same scope instead of
        // piling up blanks when the button is clicked repeatedly.
        if let empty = conversations.first(where: { $0.messages.isEmpty && $0.projectID == projectID }) {
            currentID = empty.id
            lastError = nil
            return
        }
        let c = Conversation(title: "", projectID: projectID)
        conversations.insert(c, at: 0)
        currentID = c.id
        lastError = nil
    }

    func delete(_ c: Conversation) {
        if generating && c.id == currentID { stop() }
        if pendingToolPermission?.conversationID == c.id {
            pendingToolPermission = nil
            agentContext = nil
            task?.cancel()
        }
        if pendingAgentContinuation?.conversationID == c.id {
            pendingAgentContinuation = nil
            agentContext = nil
        }
        if queuedMessage?.conversationID == c.id { queuedMessage = nil }
        conversations.removeAll { $0.id == c.id }
        if currentID == c.id { currentID = conversations.first?.id }
        if conversations.isEmpty { newConversation() }
        // Drop its persisted KV slot file too, and forget it if it was loaded.
        try? FileManager.default.removeItem(
            at: ServerSettings.primarySlotCacheDir.appendingPathComponent(Self.slotFile(c.id)))
        if slotConvID == c.id { slotConvID = nil }
        save()
    }

    /// The live store, so the settings window (which has no access to the chat
    /// window's instance) can reach it.
    private(set) static weak var live: ChatStore?

    /// Erases the stored conversations without a store: the settings window can
    /// outlive the chat window, and then nothing holds them in memory.
    static func eraseStoredConversations() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ToshLLM")
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("conversations.json"))
        let slots = ServerSettings.primarySlotCacheDir
        guard let files = try? FileManager.default.contentsOfDirectory(at: slots,
                                                                      includingPropertiesForKeys: nil)
        else { return }
        for f in files where f.pathExtension == "bin"
            && UUID(uuidString: f.deletingPathExtension().lastPathComponent) != nil {
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// Drops every conversation (projects and their prompts stay). Their
    /// persisted KV slots go with them, or they would outlive their chat.
    func deleteAll() {
        if generating { stop() }
        pendingToolPermission = nil
        pendingAgentContinuation = nil
        agentContext = nil
        queuedMessage = nil
        task?.cancel()
        for c in conversations {
            try? FileManager.default.removeItem(
                at: ServerSettings.primarySlotCacheDir.appendingPathComponent(Self.slotFile(c.id)))
        }
        conversations.removeAll()
        slotConvID = nil
        currentID = nil
        newConversation()
        save()
    }

    func rename(_ c: Conversation, to title: String) {
        guard let i = conversations.firstIndex(where: { $0.id == c.id }) else { return }
        conversations[i].title = title.trimmingCharacters(in: .whitespaces)
        save()
    }

    func togglePin(_ c: Conversation) {
        guard let i = conversations.firstIndex(where: { $0.id == c.id }) else { return }
        conversations[i].pinned = !(conversations[i].pinned ?? false)
        save()
    }

    func displayTitle(_ c: Conversation) -> String {
        if !c.title.isEmpty { return c.title }
        if let first = c.messages.first(where: { $0.role == "user" }) {
            let smart = Self.smartTitle(from: first.content)
            if !smart.isEmpty { return smart }
            if let name = first.attachments?.first?.name { return name }
        }
        return "…"
    }

    /// Sidebar title derived from a message: first meaningful line, markdown
    /// markers stripped, cut at a word boundary instead of mid-word.
    nonisolated static func smartTitle(from text: String, limit: Int = 48) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        var clean = line.drop { "#>-*• \t".contains($0) }
            .replacingOccurrences(of: "`", with: "")
        clean = clean.trimmingCharacters(in: .whitespaces)
        guard clean.count > limit else { return clean }
        let cut = String(clean.prefix(limit))
        let word = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? cut
        return (word.count >= limit / 2 ? word : cut) + "…"
    }

    // MARK: projects

    func project(id: UUID?) -> ChatProject? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    @discardableResult
    func newProject(name: String) -> ChatProject {
        let p = ChatProject(name: name.trimmingCharacters(in: .whitespaces))
        projects.insert(p, at: 0)
        save()
        return p
    }

    func renameProject(_ p: ChatProject, to name: String) {
        guard let i = projects.firstIndex(where: { $0.id == p.id }) else { return }
        projects[i].name = name.trimmingCharacters(in: .whitespaces)
        save()
    }

    func togglePinProject(_ p: ChatProject) {
        guard let i = projects.firstIndex(where: { $0.id == p.id }) else { return }
        projects[i].pinned = !(projects[i].pinned ?? false)
        save()
    }

    func setProjectCollapsed(_ p: ChatProject, _ collapsed: Bool) {
        guard let i = projects.firstIndex(where: { $0.id == p.id }) else { return }
        projects[i].collapsed = collapsed
        save()
    }

    func setProjectPrompt(_ p: ChatProject, _ prompt: String) {
        guard let i = projects.firstIndex(where: { $0.id == p.id }) else { return }
        projects[i].systemPrompt = prompt
        save()
    }

    /// Removes the folder; its conversations survive as ungrouped.
    func deleteProject(_ p: ChatProject) {
        for i in conversations.indices where conversations[i].projectID == p.id {
            conversations[i].projectID = nil
        }
        projects.removeAll { $0.id == p.id }
        save()
    }

    func move(_ c: Conversation, toProject projectID: UUID?) {
        guard let i = conversations.firstIndex(where: { $0.id == c.id }) else { return }
        conversations[i].projectID = projectID
        save()
    }

    func setConversationPrompt(_ c: Conversation, _ prompt: String) {
        guard let i = conversations.firstIndex(where: { $0.id == c.id }) else { return }
        conversations[i].systemPrompt = prompt.isEmpty ? nil : prompt
        save()
    }

    func setConversationWorkingDirectory(_ c: Conversation, _ path: String?) {
        guard let i = conversations.firstIndex(where: { $0.id == c.id }) else { return }
        conversations[i].workingDirectory = (path?.isEmpty ?? true) ? nil : path
        save()
    }

    /// Folder picker for a project, so the menu entry is one line at each call site.
    func pickProjectWorkingDirectory(_ p: ChatProject) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let path = panel.url?.path {
            setProjectWorkingDirectory(p, path)
        }
    }

    func setProjectWorkingDirectory(_ p: ChatProject, _ path: String?) {
        guard let i = projects.firstIndex(where: { $0.id == p.id }) else { return }
        projects[i].workingDirectory = (path?.isEmpty ?? true) ? nil : path
        save()
    }

    /// System prompt actually sent: the chat's own, else its project's, else
    /// the global one. First non-empty wins.
    func effectiveSystemPrompt(global: String) -> String {
        guard let c = current else { return global }
        return Self.resolvePrompt(chat: c.systemPrompt,
                                  project: project(id: c.projectID)?.systemPrompt,
                                  global: global)
    }

    /// Working directory sent with tool calls: the chat's own, else its project's.
    func effectiveWorkingDirectory(for id: UUID?) -> String? {
        guard let c = conversations.first(where: { $0.id == (id ?? current?.id) }) else { return nil }
        func meaningful(_ s: String?) -> String? {
            guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return s
        }
        return meaningful(c.workingDirectory) ?? meaningful(project(id: c.projectID)?.workingDirectory)
    }

    nonisolated static func resolvePrompt(chat: String?, project: String?, global: String) -> String {
        func meaningful(_ s: String?) -> String? {
            guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }
        return meaningful(chat) ?? meaningful(project) ?? global
    }

    // MARK: sending

    func send(text: String, attachments: [ChatAttachment] = [], images: [String] = [],
              port: Int, temperature: Double,
              maxTokens: Int, system: String, thinking: Bool,
              sampling: ChatSamplingSettings = ChatSamplingSettings(),
              modalities: ModelModalities? = nil) {
        guard !generating, let i = currentIndex else { return }
        lastError = nil
        pendingAgentContinuation = nil
        queuedMessage = nil
        agentContext = nil
        conversations[i].messages.append(ChatMessage(role: "user", content: text,
                                                     attachments: attachments.isEmpty ? nil : attachments,
                                                     imageURIs: images.isEmpty ? nil : images))
        if conversations[i].title.isEmpty {
            let smart = Self.smartTitle(from: text)
            conversations[i].title = smart.isEmpty ? (attachments.first?.name ?? "…") : smart
        }
        stream(into: i, port: port, temperature: temperature, maxTokens: maxTokens,
               system: system, thinking: thinking, sampling: sampling, modalities: modalities)
    }

    func regenerate(port: Int, temperature: Double, maxTokens: Int, system: String, thinking: Bool,
                    sampling: ChatSamplingSettings = ChatSamplingSettings(),
                    modalities: ModelModalities? = nil) {
        guard !generating, let i = currentIndex,
              conversations[i].messages.last?.role == "assistant" else { return }
        let path = Array(conversations[i].messages.dropLast())
        beginAlternativeBranch(conversationIndex: i, messages: path)
        stream(into: i, port: port, temperature: temperature, maxTokens: maxTokens,
               system: system, thinking: thinking, sampling: sampling, modalities: modalities)
    }

    func continueResponse(port: Int, temperature: Double, maxTokens: Int,
                          system: String, thinking: Bool,
                          sampling: ChatSamplingSettings = ChatSamplingSettings(),
                          modalities: ModelModalities? = nil) {
        guard !generating, let i = currentIndex,
              conversations[i].messages.last?.role == "assistant" else { return }
        stream(into: i, port: port, temperature: temperature, maxTokens: maxTokens,
               system: system, thinking: thinking,
               sampling: sampling, modalities: modalities,
               continuationInstruction: "Continue exactly where the previous response stopped. Do not repeat any text.")
    }

    private func stream(into i: Int, port: Int, temperature: Double, maxTokens: Int,
                        system: String, thinking: Bool,
                        sampling: ChatSamplingSettings = ChatSamplingSettings(),
                        modalities: ModelModalities? = nil,
                        continuationInstruction: String? = nil,
                        agentRun: AgentRunContext? = nil) {
        generating = true
        generatingConvID = conversations[i].id
        live.reset()
        startWatchdog(port: port)
        // The user can switch or delete conversations mid-stream; the result
        // must land in the one this request started from, found by id.
        let convID = conversations[i].id
        let toolCwd = effectiveWorkingDirectory(for: convID)
        let systemWithCwd = toolCwd.map {
            (system.isEmpty ? "" : system + "\n\n")
            + "File tools work inside \($0). Use paths relative to it, and never call them for text that only exists in this conversation."
        } ?? system
        let toolsEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.agentToolsEnabled)
        let javaScriptEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.jsSandboxEnabled)
        let memoryToolsEnabled = ChatMemoryService.isEnabled
        let agentTurnLimit = Self.configuredAgentTurnLimit
        let enabledToolNames = conversations[i].enabledToolNames

        var history = Self.requestHistory(system: systemWithCwd,
                                          summary: conversations[i].summary,
                                          messages: conversations[i].messages,
                                          from: conversations[i].summarizedCount ?? 0,
                                          archived: conversations[i].archived,
                                          modalities: modalities)
        if let continuationInstruction {
            history.append(["role": "user", "content": continuationInstruction])
        }

        // Reasoning off can come from the toggle or a typed /no_think; a typed
        // switch overrides the toggle for this turn. Not persisted to history.
        var reasoningOff = !thinking || sampling.reasoningEffort == "off"
        if let last = history.lastIndex(where: { ($0["role"] as? String) == "user" }) {
            let typed = Self.messageText(history[last]["content"])
            if typed.contains("/no_think") { reasoningOff = true }
            else if typed.contains("/think") { reasoningOff = false }

            if reasoningOff, !typed.contains("/no_think") {
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
        }

        conversations[i].messages.append(ChatMessage(role: "assistant", content: ""))

        let buffer = StreamBuffer()
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

        task = Task.detached(priority: .userInitiated) { [weak self, buffer, pump] in
            var nTokens = 0
            let tSent = Date()
            var tFirst: Date?
            // Token arrival times within the last seconds; drives the live
            // t/s as an instantaneous reading instead of a cumulative average.
            var stamps: [Date] = []
            var accumulator = ChatStreamAccumulator()
            var availableTools = agentRun?.tools ?? []
            var lastFlush = Date.distantPast
            var cancelled = false
            var reportedError = false
            var bytesReceived = 0

            func composed() -> String {
                guard !accumulator.reasoning.isEmpty else { return accumulator.visible }
                return "<think>" + accumulator.reasoning
                    + (accumulator.visible.isEmpty ? "" : "</think>" + accumulator.visible)
            }

            func flush() {
                let now = Date()
                let interval: TimeInterval = {
                    let n = accumulator.visible.count
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
                buffer.write(reasoning: accumulator.reasoning,
                             visible: accumulator.visible, speed: speed)
            }

            func drain(_ bytes: URLSession.AsyncBytes) async throws -> Bool {
                for try await line in bytes.lines {
                    if Task.isCancelled { throw CancellationError() }
                    bytesReceived += line.utf8.count + 1
                    guard let event = try accumulator.consume(line) else { continue }
                    if let progress = event.progress { buffer.writeProgress(progress) }
                    if event.receivedContent {
                        let now = Date()
                        if tFirst == nil { tFirst = now }
                        nTokens += 1
                        stamps.append(now)
                        flush()
                    }
                    if event.completed { return true }
                }
                return false
            }

            do {
                // Restore this conversation's persisted KV (if any) so the slot
                // holds the unchanged history and only the new turn is prefilled.
                await self?.prepareSlot(convID: convID, port: port)

                if availableTools.isEmpty {
                    if toolsEnabled {
                        availableTools = try await ChatToolsService.list(port: port)
                        // without a folder these write wherever the engine happens to run,
                        // and the model invents paths for text that is not a file at all
                        if toolCwd == nil {
                            availableTools.removeAll { $0.usesCwd && $0.writesData }
                        }
                    }
                    if javaScriptEnabled { availableTools.append(JavaScriptSandboxService.tool) }
                    if memoryToolsEnabled { availableTools.append(contentsOf: ChatMemoryService.tools) }
                    availableTools += await ToshMCPService.shared.discoverTools()
                    if ToolSupport.isBlocked(ToolSupport.currentModelIdentity) { availableTools = [] }
                    if let enabledToolNames {
                        let selected = Set(enabledToolNames)
                        availableTools.removeAll { !selected.contains($0.name) }
                    }
                }

                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.timeoutInterval = 600
                if let key = ServerSettings.activeAPIKey() {
                    req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
                }
                let activeModel = ServerSettings.activeRouterModel()
                let streamIdentity = ChatStreamIdentity.value(conversationID: convID, model: activeModel)
                req.setValue(streamIdentity, forHTTPHeaderField: "X-Conversation-Id")
                var body: [String: Any] = [
                    "messages": history,
                    "stream": true,
                    "temperature": temperature,
                    "top_p": sampling.topP,
                    "min_p": sampling.minP,
                    "top_k": sampling.topK,
                    "repeat_penalty": sampling.repeatPenalty,
                    "repeat_last_n": max(0, sampling.repeatLastN),
                    "dynatemp_range": sampling.dynatempRange,
                    "dynatemp_exponent": sampling.dynatempExponent,
                    "xtc_probability": sampling.xtcProbability,
                    "xtc_threshold": sampling.xtcThreshold,
                    "typ_p": sampling.typicalP,
                    "presence_penalty": sampling.presencePenalty,
                    "frequency_penalty": sampling.frequencyPenalty,
                    "dry_multiplier": sampling.dryMultiplier,
                    "dry_base": sampling.dryBase,
                    "dry_allowed_length": sampling.dryAllowedLength,
                    // settings saved before the engine rejected negatives still hold -1
                    "dry_penalty_last_n": max(0, sampling.dryPenaltyLastN),
                    "backend_sampling": sampling.backendSampling,
                    "seed": sampling.seed,
                    "max_tokens": maxTokens,
                    // Reuse the server-side KV cache for the unchanged history
                    // prefix so each turn only processes the new tokens.
                    "cache_prompt": true,
                    // Ask for a final usage chunk to drive the context meter.
                    "stream_options": ["include_usage": true],
                    // Stream prompt-processing progress (in `prompt_progress`).
                    "return_progress": true,
                    "timings_per_token": true,
                ]
                let samplerOrder = sampling.samplers.split(separator: ";")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !samplerOrder.isEmpty { body["samplers"] = samplerOrder }
                if let activeModel { body["model"] = activeModel }
                if !availableTools.isEmpty {
                    body["tools"] = availableTools.compactMap(\.openAIDefinition)
                    body["tool_choice"] = "auto"
                }
                if reasoningOff {
                    body["chat_template_kwargs"] = ["enable_thinking": false]
                    // For templates that ignore enable_thinking (Qwen3.6 still
                    // prefills <think>): 0 forces the reasoning block to close now.
                    body["thinking_budget_tokens"] = 0
                } else {
                    var kwargs: [String: Any] = ["enable_thinking": true]
                    // "default" leaves the value out so the template picks its own.
                    if sampling.reasoningEffort != "default" {
                        kwargs["reasoning_effort"] = sampling.reasoningEffort
                    }
                    body["chat_template_kwargs"] = kwargs
                    if let budget = Self.reasoningBudget(for: sampling.reasoningEffort) {
                        body["thinking_budget_tokens"] = budget
                    }
                    body["reasoning_control"] = true
                }
                // Pin to slot 0 so the saved/restored KV always matches the chat.
                if self?.slotPersistEnabled == true { body["id_slot"] = 0 }
                if let data = sampling.customJSON.data(using: .utf8),
                   let custom = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    body.merge(custom) { _, customValue in customValue }
                }
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

                var completed = false
                var resumeError: Error?
                do {
                    completed = try await drain(bytes)
                } catch {
                    if error is CancellationError { throw error }
                    resumeError = error
                }

                var attempts = 0
                while !completed, attempts < 3, !Task.isCancelled {
                    attempts += 1
                    let before = bytesReceived
                    do {
                        guard let url = ChatStreamIdentity.resumeURL(
                            port: port, identity: streamIdentity, from: bytesReceived)
                        else { throw StreamError(message: "Invalid stream identity") }
                        var resumeRequest = URLRequest(url: url)
                        resumeRequest.timeoutInterval = 30
                        if let key = ServerSettings.activeAPIKey() {
                            resumeRequest.setValue("Bearer " + key,
                                                   forHTTPHeaderField: "Authorization")
                        }
                        let (resumeBytes, resumeResponse) = try await ChatStore.streamingSession.bytes(for: resumeRequest)
                        let resumeStatus = (resumeResponse as? HTTPURLResponse)?.statusCode ?? 0
                        guard resumeStatus == 200 else {
                            throw StreamError(message: "Stream resume failed (HTTP \(resumeStatus))")
                        }
                        completed = try await drain(resumeBytes)
                        if !completed, bytesReceived == before {
                            throw StreamError(message: "Stream resume returned no new data")
                        }
                    } catch {
                        if error is CancellationError { throw error }
                        resumeError = error
                    }
                }
                if !completed {
                    throw resumeError ?? StreamError(message: "The response stream ended before completion")
                }
            } catch {
                if error is CancellationError {
                    cancelled = true
                } else {
                    reportedError = true
                    AppLog.chat.error("stream failed: \(error.localizedDescription)")
                    let store = self
                    let raw = error.localizedDescription
                    // the engine kills the turn when the model writes the call in the wrong
                    // shape, and it does it on every tool, so the model stops getting them
                    let rejected = raw.contains("peg-native") && !availableTools.isEmpty
                    if rejected { ToolSupport.block(ToolSupport.currentModelIdentity) }
                    let message = rejected
                        ? "Este modelo escribe mal las llamadas a herramientas y el motor cortó la respuesta; se le han desactivado, vuelve a enviar / this model writes tool calls in the wrong shape and the engine stopped the answer; they are now off for it, send again"
                        : raw
                    await MainActor.run { store?.lastError = message }
                }
            }

            // Tell the pump to stop; the final transcript is published below.
            buffer.finish()

            let finalSpeed: Double? = tFirst.flatMap { start in
                let dt = Date().timeIntervalSince(start)
                return dt > 0.4 && nTokens > 1 ? Double(nTokens) / dt : nil
            }
            let ttft: Double? = tFirst.map { $0.timeIntervalSince(tSent) * 1000 }
            let hasVisibleAnswer = !accumulator.visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let streamedText = hasVisibleAnswer ? composed() : ""
            let finalUsage = accumulator.usage
            let finalAccept = accumulator.mtpAccept
            let finalTimings: ChatTimings? = {
                var t = accumulator.timings
                t?.timeToFirstTokenMilliseconds = ttft
                return t
            }()
            let finalFinishReason = accumulator.finishReason
            let wasCancelled = cancelled
            let didReportError = reportedError
            let hadReasoning = !accumulator.reasoning.isEmpty
            let finalToolCalls = accumulator.toolCalls.filter { !$0.name.isEmpty }
            let finalText = streamedText
            let nextAgentRun = AgentRunContext(
                port: port, temperature: temperature, maxTokens: maxTokens,
                system: system, thinking: thinking, sampling: sampling,
                modalities: modalities,
                remainingTurns: agentRun?.remainingTurns ?? agentTurnLimit,
                tools: availableTools, workingDirectory: toolCwd)
            let store = self
            let shouldDeliverQueued: Bool = await MainActor.run {
                if !wasCancelled && !didReportError && hadReasoning && !hasVisibleAnswer
                    && finalToolCalls.isEmpty {
                    store?.lastError = Self.emptyResponseMessage(finishReason: finalFinishReason)
                }
                if let finalUsage { store?.setContextUsed(finalUsage.prompt + finalUsage.completion, for: convID) }
                store?.finish(conversation: convID, text: finalText, speed: finalSpeed,
                              mtpAccept: finalAccept, timings: finalTimings,
                              toolCalls: finalToolCalls)
                let shouldDeliverQueued = store?.queuedMessage?.conversationID == convID
                if shouldDeliverQueued {
                    if !finalToolCalls.isEmpty { store?.interruptPendingToolCalls(conversation: convID) }
                } else if !wasCancelled && !didReportError && !finalToolCalls.isEmpty {
                    store?.beginToolPermissions(conversation: convID, context: nextAgentRun)
                } else {
                    store?.agentContext = nil
                    store?.compactIfNeeded(conversation: convID, port: port)
                }
                return shouldDeliverQueued
            }
            // Persist the conversation's KV after a real answer, so reopening it
            // (or restarting the engine) skips re-prefilling the history.
            if !wasCancelled && !didReportError && hasVisibleAnswer {
                await self?.saveSlot(convID: convID, port: port)
            }
            if shouldDeliverQueued {
                await MainActor.run {
                    store?.deliverQueuedMessage(conversation: convID, context: nextAgentRun)
                }
            }
            pump.cancel()
        }
    }

    private func finish(conversation id: UUID, text: String, speed: Double?,
                        mtpAccept: Double? = nil, timings: ChatTimings? = nil,
                        toolCalls: [ChatToolCall] = []) {
        if let i = conversations.firstIndex(where: { $0.id == id }) {
            if let j = conversations[i].messages.indices.last,
               conversations[i].messages[j].role == "assistant" {
                if text.isEmpty && toolCalls.isEmpty {
                    conversations[i].messages.removeLast()
                    Self.clampSummary(&conversations[i])
                } else {
                    conversations[i].messages[j].content = text
                    conversations[i].messages[j].genSpeed = speed
                    conversations[i].messages[j].mtpAccept = mtpAccept
                    conversations[i].messages[j].timings = timings
                    conversations[i].messages[j].toolCalls = toolCalls.isEmpty ? nil : toolCalls
                    conversations[i].messages[j].model = ServerSettings.activeRouterModel()
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

    private func beginToolPermissions(conversation id: UUID, context: AgentRunContext) {
        guard context.remainingTurns > 0 else {
            agentContext = context
            pendingAgentContinuation = PendingAgentContinuation(conversationID: id)
            return
        }
        agentContext = context
        advanceToolPermissions(conversation: id)
    }

    private func advanceToolPermissions(conversation id: UUID) {
        if queuedMessage?.conversationID == id, let context = agentContext {
            interruptPendingToolCalls(conversation: id)
            deliverQueuedMessage(conversation: id, context: context)
            return
        }
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == id }),
              let messageIndex = conversations[conversationIndex].messages.lastIndex(where: {
                  $0.role == "assistant" && !($0.toolCalls ?? []).isEmpty
              }) else {
            agentContext = nil
            return
        }
        let message = conversations[conversationIndex].messages[messageIndex]
        if let call = message.toolCalls?.first(where: { $0.state == .pending }) {
            let info = agentContext?.tools.first(where: { $0.name == call.name })
            let request = PendingToolPermission(
                conversationID: id, messageID: message.id, callID: call.id,
                name: call.name, displayName: info?.displayName ?? call.name,
                arguments: call.arguments, writesData: info?.writesData ?? true,
                serverID: info?.mcpServerID,
                serverName: info?.mcpServerID.flatMap { serverID in
                    MCPServerStore.load().first(where: { $0.id == serverID })?.name
                })
            pendingToolPermission = request
            updateToolCall(request, state: .awaitingPermission)
            if ChatToolsService.isAlwaysAllowed(call.name) {
                respondToToolPermission(.once)
            }
            return
        }

        guard var context = agentContext else { return }
        context.remainingTurns -= 1
        agentContext = context
        guard context.remainingTurns > 0 else {
            pendingAgentContinuation = PendingAgentContinuation(conversationID: id)
            return
        }
        stream(into: conversationIndex, port: context.port, temperature: context.temperature,
               maxTokens: context.maxTokens, system: context.system, thinking: context.thinking,
               sampling: context.sampling, modalities: context.modalities, agentRun: context)
    }

    func queueMessage(text: String, attachments: [ChatAttachment], images: [String]) {
        guard let conversationID = currentID,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty || !images.isEmpty else { return }
        queuedMessage = QueuedChatMessage(conversationID: conversationID, text: text,
                                          attachments: attachments, imageURIs: images)
        if !generating, pendingToolPermission?.conversationID == conversationID,
           let context = agentContext {
            interruptPendingToolCalls(conversation: conversationID)
            deliverQueuedMessage(conversation: conversationID, context: context)
        }
    }

    func cancelQueuedMessage() {
        queuedMessage = nil
    }

    private func interruptPendingToolCalls(conversation id: UUID) {
        pendingToolPermission = nil
        guard let i = conversations.firstIndex(where: { $0.id == id }),
              let j = conversations[i].messages.lastIndex(where: {
                  $0.role == "assistant" && !($0.toolCalls ?? []).isEmpty
              }) else { return }
        let interruption = "Tool execution was interrupted by a new user message."
        var resultMessages: [ChatMessage] = []
        for index in conversations[i].messages[j].toolCalls?.indices ?? 0..<0 {
            guard conversations[i].messages[j].toolCalls?[index].state == .pending
                    || conversations[i].messages[j].toolCalls?[index].state == .awaitingPermission else { continue }
            conversations[i].messages[j].toolCalls?[index].state = .denied
            conversations[i].messages[j].toolCalls?[index].result = interruption
            conversations[i].messages[j].toolCalls?[index].finishedAt = Date()
            if let call = conversations[i].messages[j].toolCalls?[index] {
                resultMessages.append(ChatMessage(role: "tool", content: interruption,
                                                  toolCallID: call.serverID ?? call.id.uuidString))
            }
        }
        conversations[i].messages.append(contentsOf: resultMessages)
        save()
    }

    private func deliverQueuedMessage(conversation id: UUID, context: AgentRunContext) {
        guard let queued = queuedMessage, queued.conversationID == id,
              let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        queuedMessage = nil
        pendingToolPermission = nil
        pendingAgentContinuation = nil
        agentContext = nil
        conversations[i].messages.append(ChatMessage(
            role: "user", content: queued.text,
            attachments: queued.attachments.isEmpty ? nil : queued.attachments,
            imageURIs: queued.imageURIs.isEmpty ? nil : queued.imageURIs))
        stream(into: i, port: context.port, temperature: context.temperature,
               maxTokens: context.maxTokens, system: context.system, thinking: context.thinking,
               sampling: context.sampling, modalities: context.modalities)
    }

    func respondToAgentContinuation(_ shouldContinue: Bool) {
        guard let pending = pendingAgentContinuation else { return }
        pendingAgentContinuation = nil
        lastError = nil
        guard shouldContinue, var context = agentContext,
              let conversationIndex = conversations.firstIndex(where: { $0.id == pending.conversationID }) else {
            agentContext = nil
            return
        }
        context.remainingTurns = Self.configuredAgentTurnLimit
        agentContext = context
        stream(into: conversationIndex, port: context.port, temperature: context.temperature,
               maxTokens: context.maxTokens, system: context.system, thinking: context.thinking,
               sampling: context.sampling, modalities: context.modalities, agentRun: context)
    }

    func respondToToolPermission(_ decision: ToolPermissionDecision) {
        guard let request = pendingToolPermission else { return }
        pendingToolPermission = nil
        if decision == .deny {
            let result = "Tool execution was denied by the user."
            completeToolCall(request, result: result, state: .denied)
            advanceToolPermissions(conversation: request.conversationID)
            return
        }
        if decision == .always {
            ChatToolsService.allowAlways(request.name)
        } else if decision == .alwaysServer, let serverID = request.serverID,
                  let context = agentContext {
            for tool in context.tools where tool.mcpServerID == serverID {
                ChatToolsService.allowAlways(tool.name)
            }
        }
        updateToolCall(request, state: .running, startedAt: Date())
        task = Task { [weak self] in
            do {
                let arguments = try ChatToolsService.parseArguments(request.arguments)
                guard let context = self?.agentContext else { return }
                let result: ToolExecutionResult
                if let tool = context.tools.first(where: { $0.name == request.name }),
                   let serverID = tool.mcpServerID, let remoteName = tool.remoteName {
                    result = try await ToshMCPService.shared.call(
                        serverID: serverID, name: remoteName, arguments: arguments)
                } else if request.name == JavaScriptSandboxService.toolName {
                    result = await JavaScriptSandboxService.execute(arguments: arguments)
                } else if ChatMemoryService.toolNames.contains(request.name) {
                    result = await MainActor.run {
                        self?.runMemoryTool(request.name, arguments: arguments)
                            ?? ToolExecutionResult(content: "No open conversation.", isError: true)
                    }
                } else if request.name == "exec_shell_command" {
                    result = try await ChatToolsService.executeStreaming(
                        name: request.name, arguments: arguments, port: context.port,
                        workingDirectory: context.workingDirectory
                    ) { [weak self] partial in
                        await MainActor.run { self?.updateToolCallResult(request, result: partial) }
                    }
                } else {
                    result = try await ChatToolsService.execute(
                        name: request.name, arguments: arguments, port: context.port,
                        workingDirectory: context.workingDirectory)
                }
                guard !Task.isCancelled else { return }
                self?.completeToolCall(request, result: result.content,
                                       state: result.isError ? .failed : .completed)
                self?.advanceToolPermissions(conversation: request.conversationID)
            } catch {
                guard !Task.isCancelled else { return }
                self?.completeToolCall(request, result: error.localizedDescription, state: .failed)
                self?.advanceToolPermissions(conversation: request.conversationID)
            }
        }
    }

    private func updateToolCall(_ request: PendingToolPermission, state: ChatToolCallState,
                                startedAt: Date? = nil) {
        guard let i = conversations.firstIndex(where: { $0.id == request.conversationID }),
              let j = conversations[i].messages.firstIndex(where: { $0.id == request.messageID }),
              let k = conversations[i].messages[j].toolCalls?.firstIndex(where: { $0.id == request.callID })
        else { return }
        conversations[i].messages[j].toolCalls?[k].state = state
        if let startedAt { conversations[i].messages[j].toolCalls?[k].startedAt = startedAt }
        save()
    }

    private func completeToolCall(_ request: PendingToolPermission, result: String,
                                  state: ChatToolCallState) {
        guard let i = conversations.firstIndex(where: { $0.id == request.conversationID }),
              let j = conversations[i].messages.firstIndex(where: { $0.id == request.messageID }),
              let k = conversations[i].messages[j].toolCalls?.firstIndex(where: { $0.id == request.callID })
        else { return }
        conversations[i].messages[j].toolCalls?[k].state = state
        conversations[i].messages[j].toolCalls?[k].result = result
        conversations[i].messages[j].toolCalls?[k].finishedAt = Date()
        let serverID = conversations[i].messages[j].toolCalls?[k].serverID ?? request.callID.uuidString
        conversations[i].messages.append(ChatMessage(role: "tool", content: result, toolCallID: serverID))
        conversations[i].updated = Date()
        save()
    }

    private func updateToolCallResult(_ request: PendingToolPermission, result: String) {
        guard let i = conversations.firstIndex(where: { $0.id == request.conversationID }),
              let j = conversations[i].messages.firstIndex(where: { $0.id == request.messageID }),
              let k = conversations[i].messages[j].toolCalls?.firstIndex(where: { $0.id == request.callID })
        else { return }
        conversations[i].messages[j].toolCalls?[k].result = result
    }

    // MARK: KV slot persistence

    /// Read live from defaults so toggling it in Settings takes effect next turn.
    nonisolated var slotPersistEnabled: Bool {
        let d = UserDefaults.standard
        guard d.bool(forKey: SettingsKeys.persistCache) else { return false }
        guard d.object(forKey: SettingsKeys.faAmd) as? Bool ?? ServerSettings.defaultFaAmd else { return false }
        // Only an actually loaded projector blocks slot save/restore; with the
        // vision eye off the model runs text-only and persistence works.
        guard d.object(forKey: SettingsKeys.loadVision) as? Bool ?? true else { return true }
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
        // No file yet (new conversation or KV layout change): skip the failing restore.
        let file = ServerSettings.primarySlotCacheDir.appendingPathComponent(Self.slotFile(convID))
        guard FileManager.default.fileExists(atPath: file.path) else { slotConvID = convID; return }
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

    nonisolated static func requestHistory(system: String, summary: String?,
                                           messages: [ChatMessage], from start: Int,
                                           archived: [ArchivedBlock]? = nil,
                                           modalities: ModelModalities? = nil) -> [[String: Any]] {
        var history: [[String: Any]] = []
        var sys = system.trimmingCharacters(in: .whitespaces)
        if let summary, !summary.isEmpty {
            sys += (sys.isEmpty ? "" : "\n\n")
                + "Summary of the earlier part of this conversation:\n" + summary
        }
        if !sys.isEmpty { history.append(["role": "system", "content": sys]) }
        let safeStart = min(max(0, start), messages.count)
        let skipped = ChatMemoryService.archivedIndices(archived)
        history += messages[safeStart...].enumerated().compactMap { offset, m -> [String: Any]? in
            guard !skipped.contains(safeStart + offset) else { return nil }
            if m.role == "tool", let callID = m.toolCallID {
                return ["role": "tool", "tool_call_id": callID, "content": m.content]
            }
            let text = m.role == "assistant" ? m.parts.body : m.wireContent
            if m.role == "assistant", let calls = m.toolCalls, !calls.isEmpty {
                let payload: [[String: Any]] = calls.map { call in
                    ["id": call.serverID ?? call.id.uuidString,
                     "type": "function",
                     "function": ["name": call.name, "arguments": call.arguments]]
                }
                return ["role": "assistant", "content": text, "tool_calls": payload]
            }
            guard m.role != "assistant" || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            // A user turn with images uses the OpenAI multimodal content array
            // (text part + image_url parts); everything else stays a plain string.
            let media = m.attachments?.filter { $0.mediaKind != nil && $0.base64Payload != nil } ?? []
            if m.role == "user", !(m.imageURIs ?? []).isEmpty || !media.isEmpty {
                var parts: [[String: Any]] = []
                if !text.isEmpty { parts.append(["type": "text", "text": text]) }
                if modalities?.vision != false {
                    for uri in m.imageURIs ?? [] {
                        parts.append(["type": "image_url", "image_url": ["url": uri]])
                    }
                }
                for attachment in media {
                    guard let data = attachment.base64Payload else { continue }
                    if attachment.mediaKind == "audio" {
                        guard modalities?.audio != false else { continue }
                        parts.append(["type": "input_audio",
                                      "input_audio": ["data": data, "format": attachment.audioInputFormat]])
                    } else if modalities?.video != false {
                        parts.append(["type": "input_video",
                                      "input_video": ["data": data, "format": attachment.videoInputFormat]])
                    }
                }
                return ["role": m.role, "content": parts]
            }
            return ["role": m.role, "content": text]
        }
        return history
    }

    /// Plain text of a message's content, whether it's a string or the
    /// multimodal parts array. Used to detect a typed /no_think | /think switch.
    private static func messageText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: " ")
        }
        return ""
    }

    nonisolated static func compactionCutoff(messages: [ChatMessage], alreadyCompacted: Int,
                                             keepTokens: Int = 0) -> Int? {
        var cutoff = messages.count - 4
        if keepTokens > 0 {
            var kept = 0
            var i = messages.count - 1
            while i >= 0, kept < keepTokens {
                kept += messages[i].estimatedTokens
                i -= 1
            }
            cutoff = min(cutoff, i + 1)
        }
        while cutoff > 0 && messages[cutoff].role != "user" { cutoff -= 1 }
        guard cutoff >= alreadyCompacted + 2 else { return nil }
        return cutoff
    }


    func runMemoryTool(_ name: String, arguments: [String: Any]) -> ToolExecutionResult {
        guard ChatMemoryService.isEnabled else {
            return ToolExecutionResult(content: "Conversation memory tools are turned off.", isError: true)
        }
        guard let i = currentIndex else {
            return ToolExecutionResult(content: "No open conversation.", isError: true)
        }
        switch name {
        case ChatMemoryService.listName:   return memoryList(i)
        case ChatMemoryService.archiveName: return memoryArchive(i, arguments: arguments)
        case ChatMemoryService.recallName:  return memoryRecall(i, arguments: arguments)
        default:
            return ToolExecutionResult(content: "Unknown memory tool.", isError: true)
        }
    }

    private func memoryList(_ i: Int) -> ToolExecutionResult {
        let c = conversations[i]
        let skipped = ChatMemoryService.archivedIndices(c.archived)
        var lines: [String] = []
        if let covered = c.summarizedCount, covered > 0 {
            lines.append("0-\(covered - 1): already summarized, cannot be archived")
        }
        for (index, m) in c.messages.enumerated() where index >= (c.summarizedCount ?? 0) {
            let text = m.role == "assistant" ? m.parts.body : m.wireContent
            let state = skipped.contains(index) ? " [archived]" : ""
            lines.append("\(index) \(m.role)\(state): \(ChatMemoryService.preview(text))")
        }
        if let blocks = c.archived, !blocks.isEmpty {
            lines.append("")
            lines.append("Archived ranges:")
            for b in blocks { lines.append("  \(b.from)-\(b.to - 1): \(b.note)") }
        }
        return ToolExecutionResult(content: lines.joined(separator: "\n"), isError: false)
    }

    private func memoryArchive(_ i: Int, arguments: [String: Any]) -> ToolExecutionResult {
        guard let from = (arguments["from_index"] as? NSNumber)?.intValue,
              let to = (arguments["to_index"] as? NSNumber)?.intValue else {
            return ToolExecutionResult(content: "from_index and to_index are required.", isError: true)
        }
        let note = (arguments["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let range = ChatMemoryService.validate(from: from, to: to,
                                                     messageCount: conversations[i].messages.count,
                                                     summarized: conversations[i].summarizedCount ?? 0) else {
            return ToolExecutionResult(
                content: "That range cannot be archived: it must be inside the conversation and leave the last exchange in place.",
                isError: true)
        }
        var blocks = conversations[i].archived ?? []
        blocks.append(ArchivedBlock(from: range.from, to: range.to,
                                    note: note.isEmpty ? "archived" : note))
        conversations[i].archived = blocks
        conversations[i].updated = Date()
        save()
        AppLog.chat.info("archived messages \(range.from)..<\(range.to)")
        // The turns leave the context here, so this is the one moment an external index can
        // still see them without reading the transcript file.
        MemoryArchiveHook.send(
            conversationID: conversations[i].id.uuidString,
            title: conversations[i].title,
            from: range.from, to: range.to,
            note: note.isEmpty ? "archived" : note,
            messages: conversations[i].messages[range.from..<range.to].enumerated().map {
                (index: range.from + $0.offset,
                 role: $0.element.role,
                 content: $0.element.role == "assistant" ? $0.element.parts.body : $0.element.wireContent)
            })
        let freed = conversations[i].messages[range.from..<range.to]
            .reduce(0) { $0 + $1.estimatedTokens }
        return ToolExecutionResult(
            content: "Archived turns \(range.from)-\(range.to - 1), about \(freed) tokens freed. Use memory_recall to bring them back.",
            isError: false)
    }

    private func memoryRecall(_ i: Int, arguments: [String: Any]) -> ToolExecutionResult {
        guard let query = (arguments["query"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return ToolExecutionResult(content: "query is required.", isError: true)
        }
        let limit = max(1, min(20, (arguments["max_results"] as? NSNumber)?.intValue ?? 4))
        let c = conversations[i]
        guard let blocks = c.archived, !blocks.isEmpty else {
            return ToolExecutionResult(content: "Nothing has been archived in this conversation.",
                                       isError: false)
        }
        var texts: [Int: String] = [:]
        for index in ChatMemoryService.archivedIndices(blocks) where index < c.messages.count {
            let m = c.messages[index]
            texts[index] = m.role == "assistant" ? m.parts.body : m.wireContent
        }
        let hits = ChatMemoryService.matches(query: query, in: blocks, texts: texts, limit: limit)
        guard !hits.isEmpty else {
            return ToolExecutionResult(content: "No archived turn matches \"\(query)\".", isError: false)
        }
        var out = ""
        for index in hits {
            let line = "[\(index)] \(c.messages[index].role): \(texts[index] ?? "")\n\n"
            if out.count + line.count > ChatMemoryService.maximumRecallCharacters { break }
            out += line
        }
        return ToolExecutionResult(content: out, isError: false)
    }

    private func compactIfNeeded(conversation id: UUID, port: Int) {
        let d = UserDefaults.standard
        let enabled = d.object(forKey: SettingsKeys.chatAutoCompact) == nil
            ? true : d.bool(forKey: SettingsKeys.chatAutoCompact)
        let limit = d.object(forKey: SettingsKeys.ctx) == nil
            ? 16384 : d.integer(forKey: SettingsKeys.ctx)
        guard enabled, !generating, !compacting, limit > 0,
              let i = conversations.firstIndex(where: { $0.id == id }),
              let used = conversations[i].contextUsed, Double(used) / Double(limit) > 0.7 else { return }
        let start = conversations[i].summarizedCount ?? 0
        guard let cutoff = Self.compactionCutoff(messages: conversations[i].messages,
                                                 alreadyCompacted: start,
                                                 keepTokens: limit / 4) else { return }
        compact(conversation: id, index: i, from: start, through: cutoff, port: port)
    }

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
        var body: [String: Any] = [
            "messages": [["role": "system", "content": instructions],
                         ["role": "user", "content": prompt]],
            "stream": false,
            "temperature": 0.3,
            "max_tokens": 512,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        if let model = ServerSettings.activeRouterModel() { body["model"] = model }
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
        if message.lowercased().contains("reasoning effort")
            || message.lowercased().contains("reasoning_effort") {
            return "El modelo no acepta ese esfuerzo de razonamiento; elige otro o «Predeterminado del modelo» en los ajustes del chat. El motor respondió: \(message.prefix(200)) / the model does not accept that reasoning effort; pick another one or “Model default” in the chat settings. The engine answered: \(message.prefix(200))"
        }
        if message.lowercased().contains("context") {
            return "Contexto lleno: el mensaje, los archivos adjuntos y el historial juntos superan el contexto. Sube el contexto en Ajustes, adjunta menos o inicia un chat nuevo / context full: your message, attached files and history together exceed the context. Raise the context size in Settings, attach less, or start a new chat"
        }
        // std::bad_function_call comes from both a context overflow on a tool turn
        // and a missing ffmpeg/ffprobe on video; name both, not just video.
        if message.contains("bad_function_call") {
            return "La solicitud falló. Con herramientas activas suele ser que el archivo o la conversación superan el contexto: súbelo en Ajustes o usa un archivo más pequeño. Si adjuntaste un video, verifica que ffmpeg y ffprobe estén disponibles / the request failed. With tools enabled this is usually the file or conversation exceeding the context: raise it in Settings or use a smaller file. If you attached a video, make sure ffmpeg and ffprobe are available"
        }
        return "HTTP \(status): \(message.prefix(300))"
    }

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
        Self.clampSummary(&conversations[i])
        save()
        return message
    }

    nonisolated static func clampSummary(_ c: inout Conversation) {
        c.archived = ChatMemoryService.clamped(c.archived, toCount: c.messages.count)
        guard let covered = c.summarizedCount else { return }
        if covered > c.messages.count { c.summarizedCount = c.messages.count }
        if c.summarizedCount == 0 { c.summary = nil; c.summarizedCount = nil }
    }

    func editMessage(_ messageID: UUID) -> ChatMessage? {
        guard !generating, let i = currentIndex,
              let j = conversations[i].messages.firstIndex(where: { $0.id == messageID }),
              conversations[i].messages[j].role == "user" else { return nil }
        let message = conversations[i].messages[j]
        beginAlternativeBranch(conversationIndex: i,
                               messages: Array(conversations[i].messages[..<j]))
        conversations[i].summary = nil
        conversations[i].summarizedCount = nil
        conversations[i].archived = nil
        conversations[i].updated = Date()
        conversations[i].contextUsed = nil
        save()
        return message
    }

    func deleteMessageAndFollowing(_ messageID: UUID) {
        guard !generating, let i = currentIndex,
              let j = conversations[i].messages.firstIndex(where: { $0.id == messageID }) else { return }
        conversations[i].messages.removeSubrange(j...)
        conversations[i].summary = nil
        conversations[i].summarizedCount = nil
        conversations[i].archived = nil
        conversations[i].updated = Date()
        conversations[i].contextUsed = nil
        save()
    }

    var currentBranchPosition: (index: Int, count: Int)? {
        guard let c = current, let branches = c.branches, branches.count > 1,
              let active = c.activeBranchID,
              let index = branches.firstIndex(where: { $0.id == active }) else { return nil }
        return (index + 1, branches.count)
    }

    func switchBranch(_ branchID: UUID) {
        guard !generating, let i = currentIndex,
              conversations[i].activateBranch(branchID) else { return }
        conversations[i].summary = nil
        conversations[i].summarizedCount = nil
        conversations[i].archived = nil
        conversations[i].updated = Date()
        conversations[i].contextUsed = nil
        save()
    }

    func toggleTool(_ name: String, allTools: [BuiltinToolInfo]) {
        guard let i = currentIndex else { return }
        var selected = Set(conversations[i].enabledToolNames ?? allTools.map(\.name))
        if selected.contains(name) { selected.remove(name) } else { selected.insert(name) }
        conversations[i].enabledToolNames = selected.sorted()
        save()
    }

    func enableAllTools() {
        guard let i = currentIndex else { return }
        conversations[i].enabledToolNames = nil
        save()
    }

    private func beginAlternativeBranch(conversationIndex i: Int, messages: [ChatMessage]) {
        conversations[i].beginAlternativeBranch(messages: messages)
    }

    @discardableResult
    func forkConversation(at messageID: UUID, title: String? = nil,
                          includeAttachments: Bool = true) -> Conversation? {
        guard let source = current,
              let j = source.messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        var messages = Array(source.messages[...j])
        if !includeAttachments {
            for index in messages.indices {
                messages[index].attachments = nil
                messages[index].imageURIs = nil
            }
        }
        let proposed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = proposed?.isEmpty == false ? proposed! : "Fork of \(displayTitle(source))"
        let fork = Conversation(title: name, messages: messages, created: Date(), updated: Date(),
                                projectID: source.projectID, systemPrompt: source.systemPrompt)
        conversations.insert(fork, at: 0)
        currentID = fork.id
        save()
        return fork
    }

    func updateDraft(conversationID: UUID, text: String,
                     attachments: [ChatAttachment], imageURIs: [String]) {
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        let draft = ChatDraft(text: text, attachments: attachments, imageURIs: imageURIs)
        conversations[i].draft = draft.isEmpty ? nil : draft
        save()
    }

    // MARK: persistence

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([Conversation].self, from: data) {
            conversations = list
        }
        if let data = try? Data(contentsOf: projectsURL),
           let list = try? JSONDecoder().decode([ChatProject].self, from: data) {
            projects = list
        }
    }

    // Serial queue: keeps writes ordered while encoding off the main thread,
    // since the full history JSON grows with use and would cause hitches.
    private static let saveQueue = DispatchQueue(label: "dev.engel.toshllm.chat-save", qos: .utility)

    func save() {
        for i in conversations.indices {
            guard let active = conversations[i].activeBranchID,
                  let j = conversations[i].branches?.firstIndex(where: { $0.id == active }) else { continue }
            conversations[i].branches?[j].messages = conversations[i].messages
        }
        let snapshot = conversations
        let projectsSnapshot = projects
        let url = fileURL
        let pURL = projectsURL
        Self.saveQueue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
            if let data = try? JSONEncoder().encode(projectsSnapshot) {
                try? data.write(to: pURL, options: .atomic)
            }
        }
    }

    func exportText(_ c: Conversation, _ loc: Localizer) -> String {
        let user = loc.t("Tú", "You")
        let assistant = loc.t("Asistente", "Assistant")
        return c.messages.map { m in
            let who = m.role == "user" ? user : assistant
            return "## \(who)\n\n\(m.role == "assistant" ? m.parts.body : m.content)"
        }.joined(separator: "\n\n---\n\n")
    }

    func exportArchiveData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(ChatArchive(conversations: conversations, projects: projects))
    }

    func exportJSONLData() throws -> Data {
        try ChatJSONL.encode(conversations)
    }

    func importArchiveData(_ data: Data) throws -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let imported: ChatArchive
        if let archive = try? decoder.decode(ChatArchive.self, from: data) {
            imported = archive
        } else if let legacy = try? JSONDecoder().decode([Conversation].self, from: data) {
            imported = ChatArchive(conversations: legacy, projects: [])
        } else if let jsonl = try? ChatJSONL.decode(data) {
            imported = ChatArchive(conversations: jsonl, projects: [])
        } else {
            throw ChatArchiveError.unsupported
        }

        let existingConversationIDs = Set(conversations.map(\.id))
        let additions = imported.conversations.filter { !existingConversationIDs.contains($0.id) }
        let existingProjectIDs = Set(projects.map(\.id))
        projects.append(contentsOf: imported.projects.filter { !existingProjectIDs.contains($0.id) })
        conversations.insert(contentsOf: additions, at: 0)
        if currentID == nil { currentID = conversations.first?.id }
        save()
        return additions.count
    }
}

// MARK: - Main chat view

/// How far the conversation's end sits past the bottom of the view, in points.
private struct EndOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

/// When the reader last turned the wheel. A reference type so wheel events do
/// not re-render the transcript, and not @Published for the same reason.
final class ScrollGestureClock {
    var last = Date.distantPast
    var isRecent: Bool { Date().timeIntervalSince(last) < 0.4 }
}

private struct ChatComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let fontSize: CGFloat
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.font = .systemFont(ofSize: fontSize)
        textView.textContainerInset = NSSize(width: 5, height: 7)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.string = text
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerTextView else { return }
        context.coordinator.parent = self
        textView.onSubmit = onSubmit
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        // Assigning the string ends an input method's composition, even with the same value.
        if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        if isFocused.wrappedValue,
           textView.window?.firstResponder !== textView {
            DispatchQueue.main.async { [weak textView] in
                guard let textView, textView.window?.firstResponder !== textView else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposerTextEditor

        init(parent: ChatComposerTextEditor) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused.wrappedValue = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }

    final class ComposerTextView: NSTextView {
        var onSubmit: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            guard isReturn, !hasMarkedText() else {
                super.keyDown(with: event)
                return
            }

            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                insertNewline(nil)
            } else {
                onSubmit?()
            }
        }
    }
}

struct NativeChatView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.chatFontScale) private var chatFontScale
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var chat: ChatStore
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var control: ControlPanelState
    @AppStorage(SettingsKeys.chatTemp) private var temperature = 0.7
    @AppStorage(SettingsKeys.chatMaxTokens) private var maxTokens = 2048
    @AppStorage(SettingsKeys.chatSystem) private var systemPrompt = ""
    @AppStorage(SettingsKeys.chatThinking) private var thinkingEnabled = true
    @AppStorage(SettingsKeys.chatReasoningEffort) private var reasoningEffort = "medium"
    @AppStorage(SettingsKeys.chatTopP) private var topP = 0.95
    @AppStorage(SettingsKeys.chatMinP) private var minP = 0.05
    @AppStorage(SettingsKeys.chatTopK) private var topK = 40
    @AppStorage(SettingsKeys.chatRepeatPenalty) private var repeatPenalty = 1.0
    @AppStorage(SettingsKeys.chatRepeatLastN) private var repeatLastN = 64
    @AppStorage(SettingsKeys.chatSeed) private var seed = -1
    @AppStorage(SettingsKeys.chatDynatempRange) private var dynatempRange = 0.0
    @AppStorage(SettingsKeys.chatDynatempExponent) private var dynatempExponent = 1.0
    @AppStorage(SettingsKeys.chatXTCProbability) private var xtcProbability = 0.0
    @AppStorage(SettingsKeys.chatXTCThreshold) private var xtcThreshold = 0.1
    @AppStorage(SettingsKeys.chatTypicalP) private var typicalP = 1.0
    @AppStorage(SettingsKeys.chatPresencePenalty) private var presencePenalty = 0.0
    @AppStorage(SettingsKeys.chatFrequencyPenalty) private var frequencyPenalty = 0.0
    @AppStorage(SettingsKeys.chatDryMultiplier) private var dryMultiplier = 0.0
    @AppStorage(SettingsKeys.chatDryBase) private var dryBase = 1.75
    @AppStorage(SettingsKeys.chatDryAllowedLength) private var dryAllowedLength = 2
    @AppStorage(SettingsKeys.chatDryPenaltyLastN) private var dryPenaltyLastN = 0
    @AppStorage(SettingsKeys.chatSamplers) private var samplers = ""
    @AppStorage(SettingsKeys.chatBackendSampling) private var backendSampling = false
    @AppStorage(SettingsKeys.chatCustomJSON) private var customJSON = ""
    @AppStorage(SettingsKeys.chatAgenticMaxTurns) private var agenticMaxTurns = 10
    @AppStorage(SettingsKeys.chatPasteLongTextLength) private var pasteLongTextLength = 2500
    @AppStorage(SettingsKeys.chatMaxImageMegapixels) private var maxImageMegapixels = 1.0
    @AppStorage(SettingsKeys.chatPDFAsImages) private var pdfAsImages = false
    @AppStorage(SettingsKeys.chatShowSystemMessage) private var showSystemMessage = true
    @AppStorage(SettingsKeys.port) private var port = 8080
    @AppStorage(SettingsKeys.ctx) private var contextLimit = 16384
    @AppStorage(SettingsKeys.routerMode) private var routerMode = false
    @AppStorage(SettingsKeys.chatSelectedModel) private var chatSelectedModel = ""
    @State private var draft = ""
    @State private var attachments: [ChatAttachment] = []
    @State private var images: [String] = []   // attached images as data URIs (vision models)
    @State private var attachError: String?
    @State private var ocrPending = 0
    @State private var transcriptionPending = 0
    @State private var transcriptionQueue: [PendingSpeechTranscription] = []
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""
    @AppStorage(SettingsKeys.gpuIndex) private var gpuIndex = -1
    @AppStorage(SettingsKeys.whisperModel) private var whisperModelID = WhisperModel.recommendedID
    @AppStorage(SettingsKeys.speechInputMethod) private var speechInputMethodRaw = ""
    @AppStorage(SettingsKeys.whisperLoadPolicy) private var whisperLoadPolicyRaw = WhisperLoadPolicy.onDemand.rawValue
    @State private var showSystem = false
    @State private var promptConversation: Conversation?
    @State private var promptProject: ChatProject?
    @State private var headerTitle = ""
    @AppStorage(SettingsKeys.appAccent) private var accentRaw = AppTheme.defaultKey
    @AppStorage(SettingsKeys.agentToolsEnabled) private var agentToolsEnabled = false
    // True while the conversation's end is on screen (inverted scroll rests here).
    @State private var atBottom = true
    // Set when the reader scrolls away mid-answer; the bubble renders it until
    // they come back, so the transcript stops moving under them.
    @State private var frozenStream: StreamSnapshot?
    @FocusState private var inputFocused: Bool
    @State private var pasteMonitor: Any?
    @State private var scrollMonitor: Any?
    @State private var scrollGesture = ScrollGestureClock()
    @State private var draftOwnerID: UUID?
    @State private var draftSaveTask: Task<Void, Never>?
    @State private var showMCPBrowser = false
    @State private var showAttachments = false
    @State private var showTools = false
    @State private var showVoiceOptions = false
    @StateObject private var audioRecorder = AudioRecorderController()
    @StateObject private var dictation = SpeechDictationController.shared
    @StateObject private var appleDictation = AppleSpeechDictationController.shared
    @State private var dictationBase = ""
    @State private var previewAttachment: ChatAttachment?
    @State private var availableTools: [BuiltinToolInfo] = []
    @State private var loadingTools = false
    @State private var forkMessage: ChatMessage?
    @State private var modelModalities: ModelModalities?
    @State private var loadingModalities = false
    @State private var capabilitiesAreComplete = false

    private var maxTokenOptions: [Int] {
        [512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072].filter { $0 <= contextLimit }
    }

    private var whisperLoadPolicy: WhisperLoadPolicy {
        WhisperLoadPolicy(rawValue: whisperLoadPolicyRaw) ?? .onDemand
    }

    private var whisperResidencyTaskID: String {
        let model = WhisperModel.model(id: whisperModelID)
        return "\(whisperLoadPolicyRaw)-\(whisperModelID)-\(gpuIndex)-\(models.whisperModelInstalled(model))-\(String(describing: server.state))"
    }

    private var maxTokensIsLarge: Bool {
        contextLimit > 0 && Double(maxTokens) / Double(contextLimit) > 0.5
    }

    /// Levels the loaded model's template validates; the usual four when it
    /// validates nothing or the template could not be read.
    private var reasoningEffortLevels: [String] {
        let detected = modelModalities?.reasoning?.levels ?? []
        return detected.isEmpty ? ["low", "medium", "high", "max"] : detected
    }

    private func reasoningEffortIsSupported(_ effort: String) -> Bool {
        effort == "off" || effort == "default" || reasoningEffortLevels.contains(effort)
    }

    /// A level the model would reject never reaches the request: the template
    /// raises and the server answers HTTP 500.
    private func supportedReasoningEffort(_ effort: String) -> String {
        if reasoningEffortIsSupported(effort) { return effort }
        return ReasoningEffortDetector.closest(to: effort, in: reasoningEffortLevels) ?? "default"
    }

    private var effectiveReasoningEffort: String { supportedReasoningEffort(reasoningEffort) }

    private var modelDefaultEffortLabel: String {
        let label = loc.t("Predeterminado del modelo", "Model default")
        guard let value = modelModalities?.reasoning?.modelDefault, !value.isEmpty else { return label }
        return label + " · " + value
    }

    private func reasoningEffortLabel(_ level: String) -> String {
        switch level {
        case "none", "no_think": loc.t("Sin razonamiento", "No reasoning")
        case "minimal": loc.t("Mínimo · sin presupuesto", "Minimal · no budget")
        case "low": loc.t("Bajo · 512 tokens", "Low · 512 tokens")
        case "medium": loc.t("Medio · 2.048 tokens", "Medium · 2,048 tokens")
        case "high": loc.t("Alto · 8.192 tokens", "High · 8,192 tokens")
        case "xhigh": loc.t("Muy alto · sin presupuesto", "Very high · no budget")
        case "max": loc.t("Máximo · sin presupuesto", "Maximum · no budget")
        default: level
        }
    }

    private var samplingSettings: ChatSamplingSettings {
        ChatSamplingSettings(reasoningEffort: effectiveReasoningEffort,
                             topP: topP, minP: minP, topK: topK,
                             repeatPenalty: repeatPenalty, repeatLastN: repeatLastN, seed: seed,
                             dynatempRange: dynatempRange, dynatempExponent: dynatempExponent,
                             xtcProbability: xtcProbability, xtcThreshold: xtcThreshold,
                             typicalP: typicalP, presencePenalty: presencePenalty,
                             frequencyPenalty: frequencyPenalty, dryMultiplier: dryMultiplier,
                             dryBase: dryBase, dryAllowedLength: dryAllowedLength,
                             dryPenaltyLastN: dryPenaltyLastN, samplers: samplers,
                             backendSampling: backendSampling, customJSON: customJSON)
    }

    private var capabilityTaskID: String {
        "\(String(describing: server.state))-\(port)-\(routerMode ? chatSelectedModel : modelPath)-\(chat.generating)"
    }

    private var contextMaySlowGeneration: Bool {
        guard !ServerSettings.isAppleSilicon, let used = chat.contextUsed, contextLimit > 0 else {
            return false
        }
        return used >= 2560 || Double(used) / Double(contextLimit) >= 0.15
    }

    var body: some View {
        chatColumn
            .onAppear {
                inputFocused = true
                loadDraft(for: chat.currentID)
                pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard inputFocused,
                          event.modifierFlags.contains(.command),
                          event.charactersIgnoringModifiers?.lowercased() == "v",
                          clipboardHasAttachables else { return event }
                    pasteFromClipboard()
                    return nil
                }
                scrollMonitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.scrollWheel, .leftMouseDragged]) { event in
                    scrollGesture.last = Date()
                    return event
                }
            }
            .onDisappear {
                saveDraftNow()
                draftSaveTask?.cancel()
                if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
                pasteMonitor = nil
                if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
                scrollMonitor = nil
            }
            .onChange(of: chat.currentID) { oldID, newID in
                saveDraftNow(for: oldID)
                loadDraft(for: newID)
            }
            .onChange(of: server.state) { _, state in
                switch state {
                case .stopped, .failed:
                    stopSpeechSubsystem()
                case .starting, .running:
                    break
                }
            }
            .task(id: "\(chat.currentID?.uuidString ?? "")-\(String(describing: server.state))") {
                await refreshAvailableTools()
            }
            .task(id: capabilityTaskID) {
                await refreshModelModalities()
            }
            .task(id: whisperResidencyTaskID) {
                configureWhisperResidency()
            }
            .sheet(item: $promptConversation) { c in
                PromptEditorSheet(
                    title: loc.t("Prompt de esta conversación", "This conversation's prompt"),
                    hint: loc.t("Sustituye al prompt del proyecto y al global solo en esta conversación. Vacío = heredar.",
                                "Overrides the project and global prompts for this conversation only. Empty = inherit."),
                    initial: c.systemPrompt ?? ""
                ) { chat.setConversationPrompt(c, $0) }
            }
            .sheet(item: $promptProject) { p in
                PromptEditorSheet(
                    title: loc.t("Prompt del proyecto \"%@\"", "Project prompt for \"%@\"", "\(p.name)"),
                    hint: loc.t("Lo heredan todas las conversaciones del proyecto que no tengan prompt propio.",
                                "Inherited by every conversation in the project without its own prompt."),
                    initial: p.systemPrompt
                ) { chat.setProjectPrompt(p, $0) }
            }
            .sheet(isPresented: $showMCPBrowser) {
                MCPBrowserView(
                    addAttachment: { attachment in
                        if !attachments.contains(where: { $0.name == attachment.name && $0.content == attachment.content }) {
                            attachments.append(attachment)
                        }
                    },
                    insertPrompt: { value in
                        draft = [draft, value].filter { !$0.isEmpty }.joined(separator: "\n\n")
                    })
                    .environmentObject(loc)
            }
            .sheet(item: $previewAttachment) { attachment in
                MediaAttachmentPreview(attachment: attachment)
            }
            .sheet(item: $forkMessage) { message in
                ForkConversationSheet(sourceTitle: chat.current.map(chat.displayTitle) ?? "") {
                    title, includeAttachments in
                    chat.forkConversation(at: message.id, title: title,
                                          includeAttachments: includeAttachments)
                }
                .environmentObject(loc)
            }
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
            conversationHeader
            messagesScroll
            inputArea
        }
    }

    private func directoryIsMissing(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        var isDir: ObjCBool = false
        return !(FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue)
    }

    /// Shows the folder the tools are actually using, own or inherited, so it is
    /// readable without opening the chat parameters. Clicking it changes the chat's.
    @ViewBuilder private var workingDirectoryChip: some View {
        let own = chat.current?.workingDirectory
        let inherited = chat.current.flatMap { chat.project(id: $0.projectID)?.workingDirectory }
        let active = own ?? inherited
        let missing = directoryIsMissing(active)
        if agentToolsEnabled || active != nil {
            Menu {
                if let active {
                    Text(active)
                    if missing {
                        Text(loc.t("La carpeta ya no existe", "That folder no longer exists"))
                    }
                    Divider()
                }
                Button(loc.t("Elegir carpeta de este chat…", "Pick this chat's folder…")) {
                    guard let c = chat.current else { return }
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let path = panel.url?.path {
                        chat.setConversationWorkingDirectory(c, path)
                    }
                }
                if own != nil {
                    Button(inherited == nil
                           ? loc.t("Quitar carpeta", "Clear folder")
                           : loc.t("Heredar la del proyecto", "Inherit the project's")) {
                        if let c = chat.current { chat.setConversationWorkingDirectory(c, nil) }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: missing ? "folder.badge.questionmark"
                          : active == nil ? "folder.badge.questionmark" : "folder.fill")
                        .font(.system(size: 10, weight: .medium))
                    Text(active.map { URL(fileURLWithPath: $0).lastPathComponent }
                         ?? loc.t("Sin carpeta", "No folder"))
                        .lineLimit(1)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(missing ? AnyShapeStyle(.red)
                                 : own == nil && active != nil ? AnyShapeStyle(.tertiary)
                                 : AnyShapeStyle(.secondary))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .glassSurface(in: Capsule(), interactive: true)
                .overlay(Capsule().strokeBorder(.primary.opacity(0.07)))
                .contentShape(Capsule())
            }
            .menuStyle(.button).buttonStyle(.plain)
            .menuIndicator(.hidden).fixedSize()
            .tint(.secondary)
            .help(missing
                  ? loc.t("La carpeta ya no existe: las herramientas fallarán hasta que elijas otra.",
                          "That folder no longer exists: the tools will fail until you pick another.")
                  : own != nil
                  ? loc.t("Carpeta de esta conversación para las herramientas.",
                          "This conversation's folder for the tools.")
                  : active != nil
                    ? loc.t("Carpeta heredada del proyecto. Haz clic para fijar una propia.",
                            "Folder inherited from the project. Click to pin its own.")
                    : loc.t("Sin carpeta para las herramientas. Haz clic para elegir una.",
                            "No folder for the tools. Click to pick one."))
        }
    }

    private var conversationHeader: some View {
        HStack(spacing: 8) {
            if let p = chat.project(id: chat.current?.projectID) {
                Menu {
                    Button(loc.t("Quitar del proyecto", "Remove from project")) {
                        if let c = chat.current { chat.move(c, toProject: nil) }
                    }
                    Button(loc.t("Prompt del proyecto…", "Project prompt…")) { promptProject = p }
                    Button(p.workingDirectory == nil
                           ? loc.t("Carpeta del proyecto…", "Project folder…")
                           : loc.t("Cambiar carpeta del proyecto…", "Change project folder…")) {
                        chat.pickProjectWorkingDirectory(p)
                    }
                    if p.workingDirectory != nil {
                        Button(loc.t("Quitar carpeta del proyecto", "Clear project folder")) {
                            chat.setProjectWorkingDirectory(p, nil)
                        }
                    }
                } label: {
                    // Chrome lives inside the label so the menu's hit area is the whole chip.
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .medium))
                        Text(p.name).lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold)).opacity(0.7)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .glassSurface(in: Capsule(), interactive: true)
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.07)))
                    .contentShape(Capsule())
                }
                .menuStyle(.button).buttonStyle(.plain)
                .menuIndicator(.hidden).fixedSize()
                .tint(.secondary)
                .help(loc.t("Proyecto de esta conversación.", "This conversation's project."))
            }
            TextField(loc.t("Título de la conversación", "Conversation title"),
                      text: $headerTitle)
                .textFieldStyle(.plain)
                .font(.callout.weight(.medium))
                .onSubmit {
                    if let c = chat.current { chat.rename(c, to: headerTitle) }
                }
                .task(id: chat.currentID) { syncHeaderTitle() }
                .onChange(of: chat.current?.title) { syncHeaderTitle() }
                .help(loc.t("Haz clic para renombrar la conversación (Enter guarda).",
                            "Click to rename the conversation (Enter saves)."))
            Spacer()
            workingDirectoryChip
            if let branches = chat.current?.branches, branches.count > 1,
               let position = chat.currentBranchPosition {
                Menu {
                    ForEach(Array(branches.enumerated()), id: \.element.id) { index, branch in
                        Button {
                            chat.switchBranch(branch.id)
                        } label: {
                            if branch.id == chat.current?.activeBranchID {
                                Label(loc.t("Rama %@", "Branch %@", "\(index + 1)"),
                                      systemImage: "checkmark")
                            } else {
                                Text(loc.t("Rama %@", "Branch %@", "\(index + 1)"))
                            }
                        }
                    }
                } label: {
                    Label("\(position.index)/\(position.count)", systemImage: "arrow.triangle.branch")
                        .font(.caption)
                }
                .menuStyle(.button)
                .help(loc.t("Cambiar entre respuestas y ediciones alternativas sin salir del chat.",
                            "Switch between alternate responses and edits without leaving the chat."))
            }
            if !(chat.current?.systemPrompt ?? "").isEmpty {
                Button {
                    promptConversation = chat.current
                } label: {
                    Image(systemName: "text.bubble.fill").font(.caption)
                }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .accessibilityLabel(loc.t("Prompt de esta conversación", "This conversation's prompt"))
                .help(loc.t("Esta conversación tiene prompt propio; clic para editarlo.",
                            "This conversation has its own prompt; click to edit it."))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// Header shows the stored title; a brand-new empty chat starts blank
    /// instead of the "…" placeholder so typing sets a real title.
    private func syncHeaderTitle() {
        guard let c = chat.current else { headerTitle = ""; return }
        headerTitle = c.title.isEmpty
            ? (c.messages.isEmpty ? "" : chat.displayTitle(c))
            : c.title
    }

    /// First message not covered by the compaction summary; the transcript
    /// shows a marker above it.
    private var compactionBoundaryID: UUID? {
        guard let c = chat.current, c.summary != nil,
              let n = c.summarizedCount, n > 0, n < c.messages.count else { return nil }
        return c.messages[n].id
    }

    private var messagesScroll: some View {
        // Tool results are shown inside the assistant's tool-call card, so the
        // separate tool-role message is display-only noise and is hidden here.
        let messages = (chat.current?.messages ?? []).filter { $0.role != "tool" }
        let newestID = messages.last?.id
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    endProbe
                    transcript(messages, newestID: newestID)
                }
            }
            .coordinateSpace(name: Self.scrollSpace)
            .flippedUpsideDown()
            .overlay {
                if messages.isEmpty { emptyChatState }
            }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    jumpToBottomButton(writingBehind: frozenStream != nil) { followEnd(proxy) }
                }
            }
            // Only a real wheel gesture may change this: layout settling after a
            // turn ends also moves the probe, and that must not scroll anyone.
            .onPreferenceChange(EndOffsetKey.self) { offset in
                guard let offset, scrollGesture.isRecent else { return }
                if atBottom {
                    if offset < -Self.leaveSlack { atBottom = false; freezeStream() }
                } else if offset > -Self.returnSlack {
                    atBottom = true
                    followEnd(proxy, animated: false)
                }
            }
            .onChange(of: chat.currentID) { _, _ in
                followEnd(proxy, animated: false)
                inputFocused = true
            }
            // A new turn (send/regenerate) jumps to the bottom, unless the reader
            // stepped away: then it keeps writing off screen.
            .onChange(of: chat.current?.messages.last?.id) { _, _ in
                if atBottom { followEnd(proxy, animated: false) } else { freezeStream() }
            }
            .onChange(of: chat.generating) { _, generating in
                if generating { if !atBottom { freezeStream() } } else { frozenStream = nil }
            }
        }
    }

    private var endProbe: some View {
        Color.clear.frame(height: 1).id(Self.bottomID)
            .background {
                GeometryReader { g in
                    // Quantized: sub-pixel changes would fire on every frame.
                    let y = g.frame(in: .named(Self.scrollSpace)).minY
                    Color.clear.preference(key: EndOffsetKey.self, value: (y / 4).rounded() * 4)
                }
            }
    }

    @ViewBuilder
    private func transcript(_ messages: [ChatMessage], newestID: UUID?) -> some View {
        LazyVStack(spacing: 14) {
            if chat.pendingAgentContinuation?.conversationID == chat.currentID {
                AgentContinuationCard(
                    continueAction: { chat.respondToAgentContinuation(true) },
                    stopAction: { chat.respondToAgentContinuation(false) })
                    .environmentObject(loc)
                    .flippedUpsideDown()
            }
            if let request = chat.pendingToolPermission,
               request.conversationID == chat.currentID {
                ToolPermissionCard(request: request) { chat.respondToToolPermission($0) }
                    .environmentObject(loc)
                    .flippedUpsideDown()
            }
            if let err = chat.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                    .flippedUpsideDown()
            }
            ForEach(messages.reversed()) { msg in
                messageRow(msg, isNewest: msg.id == newestID)
                    .flippedUpsideDown()
                    .id(msg.id)
            }
            if showSystemMessage {
                let prompt = chat.effectiveSystemPrompt(global: systemPrompt)
                if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    SystemPromptCard(prompt: prompt) { promptConversation = chat.current }
                        .flippedUpsideDown()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: 1120)
        .frame(maxWidth: .infinity)
    }

    /// Pins the transcript back to the end and resumes following the answer.
    private func followEnd(_ proxy: ScrollViewProxy, animated: Bool = true) {
        atBottom = true
        frozenStream = nil
        if animated {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.bottomID) }
        } else {
            proxy.scrollTo(Self.bottomID)
        }
    }

    private func freezeStream() {
        guard frozenStream == nil, chat.generating, chat.current?.id == chat.generatingConvID else { return }
        frozenStream = chat.live.snapshot
    }

    private static let bottomID = "convBottom"
    private static let scrollSpace = "chatScroll"
    /// Freezing only once the answer's last lines are well out of view: doing it
    /// while they are still on screen reads as the generation having stalled.
    private static let leaveSlack: CGFloat = 120
    /// Coming back, on the other hand, means actually reaching the end.
    private static let returnSlack: CGFloat = 12

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
                StreamingBubble(live: chat.live, message: msg, frozen: frozenStream)
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
                                        maxTokens: maxTokens,
                                        system: chat.effectiveSystemPrompt(global: systemPrompt),
                                        thinking: thinkingEnabled, sampling: samplingSettings,
                                        modalities: modelModalities)
                    },
                    onContinue: {
                        chat.continueResponse(port: port, temperature: temperature,
                                              maxTokens: maxTokens,
                                              system: chat.effectiveSystemPrompt(global: systemPrompt),
                                              thinking: thinkingEnabled, sampling: samplingSettings,
                                              modalities: modelModalities)
                    },
                    onEdit: {
                        if let m = chat.editMessage(msg.id) {
                            draft = m.content
                            attachments = m.attachments ?? []
                            images = m.imageURIs ?? []
                            inputFocused = true
                        }
                    },
                    onFork: {
                        forkMessage = msg
                    },
                    onDelete: {
                        chat.deleteMessageAndFollowing(msg.id)
                    })
                    .equatable()
            }
        }
    }

    private func jumpToBottomButton(writingBehind: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(writingBehind ? Color.appAccent : .secondary)
                .frame(width: 34, height: 34)
                // Without this only the glyph takes the click, so presses landing
                // on the empty part of the circle do nothing.
                .contentShape(Circle())
                .glassSurface(in: Circle(), interactive: true)
                .overlay(alignment: .topTrailing) {
                    if writingBehind {
                        Circle().fill(Color.appAccent)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(.background, lineWidth: 1.5))
                            .offset(x: 1, y: -1)
                    }
                }
        }
        .buttonStyle(.plain)
        .padding(14)
        .help(writingBehind
              ? loc.t("La respuesta sigue escribiéndose fuera de pantalla; ir al final y volver a seguirla.",
                      "The answer is still being written off screen; jump to the end and follow it again.")
              : loc.t("Ir al final de la conversación y seguir la respuesta.",
                      "Jump to the end of the conversation and follow the response."))
    }

    private var emptyChatState: some View {
        ChatEmptyState { action in
            switch action {
            case .ask:
                draft = loc.t("Ayúdame a explorar una idea.", "Help me explore an idea.")
                inputFocused = true
            case .code:
                draft = loc.t("Ayúdame a escribir y mejorar este código:", "Help me write and improve this code:")
                inputFocused = true
            case .files:
                showAttachments = true
            case .summarize:
                draft = loc.t("Resume este contenido y destaca las ideas principales:",
                              "Summarize this content and highlight the main ideas:")
                inputFocused = true
            case .explore:
                control.openSettings(.chat)
                openWindow(id: "control")
            }
        }
    }

    // MARK: input

    private var inputArea: some View {
        VStack(spacing: 8) {
            if let queued = chat.queuedMessage, queued.conversationID == chat.currentID {
                QueuedMessageBanner(message: queued, cancel: chat.cancelQueuedMessage)
                    .environmentObject(loc)
            }
            if !attachments.isEmpty { attachmentChips }
            if !images.isEmpty { imageChips }
            if ocrPending > 0 {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(loc.t("Procesando PDF en el dispositivo…",
                               "Processing PDF on device…"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let status = dictation.statusText {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(status)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let attachError {
                Label(attachError, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            composerShell
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 16)
        // Files dropped anywhere on the composer become attachments.
        .dropDestination(for: URL.self) { urls, _ in
            addAttachments(urls: urls)
            return true
        }
        .onChange(of: attachments) { scheduleDraftSave() }
        .onChange(of: images) { scheduleDraftSave() }
            .alert(loc.t("Problema con la voz", "Voice problem"),
               isPresented: Binding(
                   get: { audioRecorder.error != nil || dictation.error != nil || appleDictation.error != nil },
                   set: {
                       if !$0 {
                           audioRecorder.error = nil
                           dictation.error = nil
                           appleDictation.error = nil
                       }
                   })) {
        } message: { Text(audioRecorder.error ?? dictation.error ?? appleDictation.error ?? "") }
    }

    private var composerShell: some View {
        VStack(spacing: 8) {
            if server.state != .running {
                serverAvailabilityBar
                    .background(WorkspaceStyle.surface,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(WorkspaceStyle.border))
            }
            if server.state == .running || chat.generating || chat.compacting {
                statusStrip
                    .padding(.horizontal, 10)
            }
            composerRow
                .background(WorkspaceStyle.surface,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(WorkspaceStyle.border))
        }
    }

    private var serverAvailabilityBar: some View {
        HStack(spacing: 10) {
            switch server.state {
            case .starting:
                ProgressView().controlSize(.small)
                Text(loc.t("Iniciando el servidor… Puedes seguir consultando tus chats.",
                           "Starting the server… You can keep browsing your chats."))
                    .foregroundStyle(.secondary)
            case .failed(let error):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(loc.half(error)).lineLimit(2)
                Spacer(minLength: 8)
                Button(loc.t("Reintentar", "Try again")) { server.start(.fromDefaults()) }
                    .buttonStyle(.borderedProminent)
                    .disabled(modelPath.isEmpty)
            case .stopped:
                Image(systemName: "circle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(modelPath.isEmpty
                     ? loc.t("Elige un modelo para poder enviar mensajes.",
                             "Choose a model before sending messages.")
                     : loc.t("El servidor está detenido. Puedes consultar y organizar tus chats.",
                             "The server is stopped. You can browse and organize your chats."))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if modelPath.isEmpty {
                    Button(loc.t("Elegir modelo", "Choose model")) {
                        control.section = .models
                        openWindow(id: "control")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(loc.t("Iniciar servidor", "Start server"), systemImage: "play.fill") {
                        server.start(.fromDefaults())
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .running:
                EmptyView()
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var composerRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            messageField
            HStack(alignment: .center, spacing: 10) {
                paramsButton
                attachButton
                if !availableTools.isEmpty { toolsButton }
                voiceButton
                Spacer(minLength: 8)
                sendControls
            }
        }
        .padding(14)
        .frame(minHeight: 104)
    }

    private var messageField: some View {
        ZStack(alignment: .topLeading) {
            if draft.isEmpty {
                Text(loc.t("Escribe tu mensaje…", "Type your message…"))
                    .chatFont(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 7)
                    .allowsHitTesting(false)
            }
            ChatComposerTextEditor(
                text: $draft,
                isFocused: $inputFocused,
                fontSize: ChatFont.Base.body.points * chatFontScale,
                onSubmit: send)
        }
            .frame(height: 64)
            .onChange(of: draft) { _, value in
                absorbLargeDraft(value)
                scheduleDraftSave()
            }
            .onPasteCommand(of: [.image, .png, .tiff, .fileURL]) { _ in
                pasteFromClipboard()
            }
            .help(loc.t("Intro envía; Mayús+Intro inserta un salto de línea. Los textos pegados grandes se convierten en un adjunto; pegar una imagen (captura) la adjunta si el modelo tiene visión.",
                        "Return sends; Shift+Return inserts a line break. Large pasted text becomes an attachment; pasting an image (screenshot) attaches it if the model has vision."))
    }

    @ViewBuilder
    private var sendControls: some View {
        if chat.generating {
            Button(loc.t("Intervenir", "Steer"), systemImage: "arrow.up.circle.fill",
                   action: send)
                       .labelStyle(.iconOnly)
                .font(.system(size: 26))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, canSend ? AppTheme.accent(accentRaw) : Color.secondary.opacity(0.45))
                .buttonStyle(.borderless)
                .padding(.bottom, 2)
                .disabled(!canSend)
                .help(loc.t("Enviar una intervención: se aplicará al terminar el turno actual del agente.",
                            "Send a steering message after the agent's current turn."))
            Button(loc.t("Detener", "Stop"), systemImage: "stop.circle.fill",
                   action: chat.stop)
                       .labelStyle(.iconOnly)
                .font(.system(size: 26))
                .foregroundStyle(.red)
                .buttonStyle(.borderless)
                .padding(.bottom, 2)
                .help(loc.t("Detener la generación.", "Stop generation."))
        } else {
            Button(loc.t("Enviar", "Send"), systemImage: "arrow.up.circle.fill", action: send)
                .labelStyle(.iconOnly)
                .font(.system(size: 26))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, canSend ? AppTheme.accent(accentRaw) : Color.secondary.opacity(0.45))
                .buttonStyle(.borderless)
                .padding(.bottom, 2)
                .disabled(!canSend)
                .help(loc.t("Enviar mensaje (Intro).", "Send message (Return)."))
        }
    }

    private var canSend: Bool {
        server.state == .running
            && ocrPending == 0 && transcriptionPending == 0
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty || !images.isEmpty)
    }

    private func loadDraft(for conversationID: UUID?) {
        draftSaveTask?.cancel()
        draftOwnerID = conversationID
        let saved = chat.conversations.first(where: { $0.id == conversationID })?.draft
        draft = saved?.text ?? ""
        attachments = saved?.attachments ?? []
        images = saved?.imageURIs ?? []
    }

    private func scheduleDraftSave() {
        let owner = draftOwnerID
        let text = draft
        let files = attachments
        let imageValues = images
        draftSaveTask?.cancel()
        draftSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let owner else { return }
            chat.updateDraft(conversationID: owner, text: text,
                             attachments: files, imageURIs: imageValues)
        }
    }

    private func saveDraftNow(for conversationID: UUID? = nil) {
        guard let owner = conversationID ?? draftOwnerID else { return }
        chat.updateDraft(conversationID: owner, text: draft,
                         attachments: attachments, imageURIs: images)
    }

    private var paramsButton: some View {
        Button {
            showSystem.toggle()
        } label: {
            ComposerCircleLabel(
                title: loc.t("Parámetros del chat", "Chat parameters"),
                systemImage: "slider.horizontal.3",
                active: showSystem)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showSystem, arrowEdge: .top) { paramsPopover }
        .help(loc.t("Parámetros del chat: razonamiento, creatividad, longitud de respuesta y prompt de sistema.",
                    "Chat parameters: reasoning, creativity, response length and system prompt."))
    }

    /// Folder the server tools run in. Shown here because it is per chat and the
    /// user has to see which one is active before sending.
    @ViewBuilder private var workingDirectoryRow: some View {
        let own = chat.current?.workingDirectory
        let inherited = chat.current.flatMap { chat.project(id: $0.projectID)?.workingDirectory }
        VStack(alignment: .leading, spacing: 6) {
            Label(loc.t("Directorio de trabajo", "Working directory"), systemImage: "folder")
                .font(.subheadline.weight(.medium))
                .infoTip(loc.t("Carpeta en la que se ejecutan las herramientas del servidor en esta conversación. Si no fijas una, hereda la del proyecto.",
                               "Folder the server tools run in for this conversation. With none set, it inherits the project's."))
            HStack(spacing: 8) {
                if directoryIsMissing(own ?? inherited) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.red)
                        .help(loc.t("La carpeta ya no existe.", "That folder no longer exists."))
                }
                Text(own ?? inherited ?? loc.t("Sin carpeta", "None"))
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.head)
                    .foregroundStyle(directoryIsMissing(own ?? inherited) ? AnyShapeStyle(.red)
                                     : own == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Spacer()
                if own == nil, inherited != nil {
                    Text(loc.t("del proyecto", "from project"))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Button(loc.t("Elegir…", "Choose…")) {
                    guard let c = chat.current else { return }
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let path = panel.url?.path {
                        chat.setConversationWorkingDirectory(c, path)
                    }
                }
                .help(loc.t("Elegir la carpeta de esta conversación.", "Pick this conversation's folder."))
                Button(loc.t("Quitar", "Clear")) {
                    if let c = chat.current { chat.setConversationWorkingDirectory(c, nil) }
                }
                .disabled(own == nil)
                .help(loc.t("Vuelve a heredar la carpeta del proyecto.", "Go back to inheriting the project's folder."))
            }
        }
    }

    private var paramsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc.t("Parámetros del chat", "Chat parameters")).font(.headline)

            if routerMode {
                Picker(selection: $chatSelectedModel) {
                    ForEach(ModelFamilyGroup.grouped(models.models)) { group in
                        Section(group.isOther ? loc.t("Otros", "Others") : group.family) {
                            ForEach(group.models) { m in
                                Text(ModelName.forPath(m.url.path).display
                                     + (ModelTraitsCache.cached(for: m.url.path)?.pickerSuffix(spanish: loc.isSpanish) ?? ""))
                                    .tag(ServerSettings.routerAlias(for: m.url.path))
                            }
                        }
                    }
                } label: {
                    Label(loc.t("Modelo", "Model"), systemImage: "shippingbox")
                }
                .infoTip(loc.t("Modelo para el próximo mensaje. El router lo carga solo (y descarga el anterior si hace falta), sin reiniciar el servidor.",
                            "Model for the next message. The router loads it on demand (unloading the previous one if needed), no server restart."))
                .task(id: models.models.map(\.url.path)) {
                    guard chatSelectedModel.isEmpty || !models.models.contains(where: {
                        ServerSettings.routerAlias(for: $0.url.path) == chatSelectedModel
                    }) else { return }
                    if let first = models.models.first {
                        chatSelectedModel = ServerSettings.routerAlias(for: first.url.path)
                    }
                }
            }

            modalityBadges

            Divider()

            workingDirectoryRow

            Divider()

            Picker(selection: $reasoningEffort) {
                Text(loc.t("Desactivado", "Off")).tag("off")
                Text(modelDefaultEffortLabel).tag("default")
                ForEach(reasoningEffortLevels, id: \.self) { level in
                    Text(reasoningEffortLabel(level)).tag(level)
                }
            } label: {
                Label(loc.t("Esfuerzo de razonamiento", "Reasoning effort"), systemImage: "brain")
            }
            .disabled(modelModalities?.thinking == false)
            .onChange(of: reasoningEffort) { _, value in thinkingEnabled = value != "off" }
            .onChange(of: modelModalities?.reasoning) { _, _ in
                let supported = supportedReasoningEffort(reasoningEffort)
                if supported != reasoningEffort { reasoningEffort = supported }
            }
            .infoTip(loc.t("Los modelos razonadores piensan antes de responder (esos tokens cuentan dentro del límite de respuesta). La lista muestra los niveles que acepta la plantilla del modelo cargado, y «Predeterminado del modelo» deja que la elija él. Al desactivarlo se envía enable_thinking:false y /no_think; algunos modelos entrenados solo para razonar (p. ej. R1) pueden seguir pensando de todos modos.",
                        "Reasoning models think before answering (those tokens count toward the response limit). The list shows the levels the loaded model's template accepts, and “Model default” lets the model choose. Turning it off sends enable_thinking:false and /no_think; some reasoning-only models (e.g. R1) may still think regardless."))

            Toggle(isOn: $showSystemMessage) {
                Label(loc.t("Mostrar prompt de sistema", "Show system prompt"),
                      systemImage: "text.bubble")
            }

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

            if false { DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    samplingSlider(loc.t("Top P", "Top P"), value: $topP, range: 0...1)
                    samplingSlider(loc.t("Min P", "Min P"), value: $minP, range: 0...1)
                    samplingSlider(loc.t("Typical P", "Typical P"), value: $typicalP, range: 0...1)
                    Stepper(value: $topK, in: 0...200) {
                        parameterValue(loc.t("Top K", "Top K"), value: topK.formatted())
                    }
                    samplingSlider(loc.t("Penalización de repetición", "Repeat penalty"),
                                   value: $repeatPenalty, range: 0.5...2)
                    samplingSlider(loc.t("Penalización de presencia", "Presence penalty"),
                                   value: $presencePenalty, range: -2...2)
                    samplingSlider(loc.t("Penalización de frecuencia", "Frequency penalty"),
                                   value: $frequencyPenalty, range: -2...2)
                    Stepper(value: $repeatLastN, in: 0...4096, step: 16) {
                        parameterValue(loc.t("Ventana de repetición", "Repeat window"),
                                       value: repeatLastN.formatted())
                    }
                    HStack {
                        Text(loc.t("Semilla", "Seed"))
                        Spacer()
                        DeferredNumberField("-1", value: $seed, width: 90)
                    }
                    GroupBox(loc.t("Temperatura dinámica y XTC", "Dynamic temperature and XTC")) {
                        VStack(alignment: .leading, spacing: 8) {
                            samplingSlider(loc.t("Rango dinámico", "Dynamic range"),
                                           value: $dynatempRange, range: 0...2)
                            samplingSlider(loc.t("Exponente dinámico", "Dynamic exponent"),
                                           value: $dynatempExponent, range: 0.1...4)
                            samplingSlider(loc.t("Probabilidad XTC", "XTC probability"),
                                           value: $xtcProbability, range: 0...1)
                            samplingSlider(loc.t("Umbral XTC", "XTC threshold"),
                                           value: $xtcThreshold, range: 0...1)
                        }
                    }
                    GroupBox("DRY") {
                        VStack(alignment: .leading, spacing: 8) {
                            samplingSlider(loc.t("Multiplicador", "Multiplier"),
                                           value: $dryMultiplier, range: 0...2)
                            samplingSlider(loc.t("Base", "Base"), value: $dryBase, range: 1...3)
                            Stepper(value: $dryAllowedLength, in: 0...32) {
                                parameterValue(loc.t("Longitud permitida", "Allowed length"),
                                               value: dryAllowedLength.formatted())
                            }
                            Stepper(value: $dryPenaltyLastN, in: 0...32768, step: 64) {
                                parameterValue(loc.t("Ventana DRY", "DRY window"),
                                               value: dryPenaltyLastN.formatted())
                            }
                        }
                    }
                    TextField(loc.t("Orden: top_k;typ_p;top_p;min_p;temperature",
                                    "Order: top_k;typ_p;top_p;min_p;temperature"),
                              text: $samplers)
                        .workspaceTextField()
                    Toggle(loc.t("Muestreo en backend", "Backend sampling"),
                           isOn: $backendSampling)
                    Stepper(value: $agenticMaxTurns, in: 1...100) {
                        parameterValue(loc.t("Turnos máximos del agente", "Maximum agent turns"),
                                       value: agenticMaxTurns.formatted())
                    }
                    Stepper(value: $pasteLongTextLength, in: 0...100_000, step: 500) {
                        parameterValue(loc.t("Texto pegado a archivo", "Paste text to file"),
                                       value: pasteLongTextLength == 0
                                           ? loc.t("Desactivado", "Off")
                                           : pasteLongTextLength.formatted())
                    }
                    HStack {
                        Text(loc.t("Máximo de imagen (MP)", "Maximum image size (MP)"))
                        Spacer()
                        DeferredNumberField("0", value: $maxImageMegapixels, width: 80)
                    }
                    Toggle(loc.t("PDF como imágenes para modelos con visión",
                                 "PDF as images for vision models"), isOn: $pdfAsImages)
                    DisclosureGroup(loc.t("JSON personalizado de la petición",
                                          "Custom request JSON")) {
                        TextEditor(text: $customJSON)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 80)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        Text(loc.t("Las claves válidas reemplazan los parámetros anteriores para esta petición.",
                                   "Valid keys override the parameters above for this request."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Button(loc.t("Restaurar muestreo", "Reset sampling"),
                           systemImage: "arrow.counterclockwise") {
                        topP = 0.95
                        minP = 0.05
                        topK = 40
                        repeatPenalty = 1
                        repeatLastN = 64
                        seed = -1
                        dynatempRange = 0
                        dynatempExponent = 1
                        xtcProbability = 0
                        xtcThreshold = 0.1
                        typicalP = 1
                        presencePenalty = 0
                        frequencyPenalty = 0
                        dryMultiplier = 0
                        dryBase = 1.75
                        dryAllowedLength = 2
                        dryPenaltyLastN = 0
                        samplers = ""
                        backendSampling = false
                        customJSON = ""
                        agenticMaxTurns = 10
                        pasteLongTextLength = 2500
                        maxImageMegapixels = 1
                        pdfAsImages = false
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                .padding(.top, 8)
            } label: {
                Label(loc.t("Muestreo avanzado", "Advanced sampling"),
                      systemImage: "slider.horizontal.2.square")
            }

            Divider()

            Label(loc.t("Prompt de sistema global", "Global system prompt"), systemImage: "gearshape")
                .font(.subheadline.weight(.medium))
                .infoTip(loc.t("Instrucciones permanentes para el modelo. Prioridad: prompt de la conversación, luego el del proyecto, luego este global.",
                               "Permanent instructions for the model. Priority: the conversation's prompt, then the project's, then this global one."))
            TextEditor(text: $systemPrompt)
                .font(.system(size: 12))
                .frame(height: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
            }

            Button {
                showSystem = false
                control.openSettings(.chat)
                openWindow(id: "control")
            } label: {
                Label(loc.t("Abrir ajustes avanzados del chat…", "Open advanced chat settings…"),
                      systemImage: "gearshape.2")
            }
            .glassButton()

            HStack(spacing: 10) {
                Button {
                    showSystem = false
                    promptConversation = chat.current
                } label: {
                    Label(loc.t("De esta conversación…", "This conversation's…"),
                          systemImage: (chat.current?.systemPrompt ?? "").isEmpty ? "text.bubble" : "text.bubble.fill")
                }
                .buttonStyle(.link).font(.caption)
                .help(loc.t("Prompt propio de esta conversación; sustituye al del proyecto y al global.",
                            "This conversation's own prompt; overrides the project and global ones."))
                if let p = chat.project(id: chat.current?.projectID) {
                    Button {
                        showSystem = false
                        promptProject = p
                    } label: {
                        Label(loc.t("Del proyecto…", "Project's…"),
                              systemImage: p.systemPrompt.isEmpty ? "folder" : "folder.fill")
                    }
                    .buttonStyle(.link).font(.caption)
                    .help(loc.t("Prompt compartido por las conversaciones del proyecto \"%@\".",
                                "Prompt shared by the conversations in project \"%@\".", p.name))
                }
            }
            Text(activePromptCaption)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 380)
    }

    private func samplingSlider(_ title: String, value: Binding<Double>,
                                range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Slider(value: value, in: range)
            Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 38, alignment: .trailing)
        }
    }

    private func parameterValue(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).font(.system(.caption, design: .monospaced))
        }
    }

    /// Which system prompt actually applies to the open conversation.
    private var activePromptCaption: String {
        if !(chat.current?.systemPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return loc.t("Activo: el prompt de esta conversación.", "Active: this conversation's prompt.")
        }
        if let p = chat.project(id: chat.current?.projectID),
           !p.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return loc.t("Activo: el prompt del proyecto \"%@\".", "Active: project \"%@\"'s prompt.", "\(p.name)")
        }
        return systemPrompt.isEmpty
            ? loc.t("Sin prompt de sistema.", "No system prompt.")
            : loc.t("Activo: el prompt global.", "Active: the global prompt.")
    }

    private var attachButton: some View {
        Button {
            showAttachments.toggle()
        } label: {
            ComposerCircleLabel(
                title: loc.t("Adjuntar", "Attach"),
                systemImage: "paperclip",
                active: showAttachments || !attachments.isEmpty || !images.isEmpty)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showAttachments, arrowEdge: .top) { attachmentsPopover }
        .help(loc.t("Adjuntar archivos: texto, código y PDF (se extrae su texto; los PDF escaneados por OCR); de otros binarios se extraen las cadenas legibles. Imágenes solo si el modelo tiene visión (su mmproj). También puedes arrastrarlos al área de escritura.",
                    "Attach files: text, code and PDF (text is extracted; scanned PDFs via OCR); other binaries contribute their readable strings. Images only if the model has vision (its mmproj). You can also drag them onto the input area."))
    }

    private var attachmentsPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc.t("Adjuntar", "Attach")).font(.headline)
            Button(loc.t("Archivos del Mac…", "Files from Mac…"), systemImage: "doc.badge.plus") {
                showAttachments = false
                pickAttachments()
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
            if MCPServerStore.load().contains(where: \.enabled) {
                Divider()
                Button(loc.t("Recursos MCP…", "MCP resources…"),
                       systemImage: "point.3.connected.trianglepath.dotted") {
                    showAttachments = false
                    showMCPBrowser = true
                }
                .buttonStyle(.plain)
                .padding(.vertical, 6)
            }
        }
        .padding(14)
        .frame(width: 240)
    }

    private var voiceButton: some View {
        Button(action: primaryVoiceAction) {
            ComposerCircleLabel(
                title: voiceButtonTitle,
                systemImage: dictation.isTranscribing ? "xmark"
                    : (dictation.isDictating || appleDictation.isDictating || audioRecorder.isRecording)
                    ? "stop.fill" : "mic.fill",
                active: dictation.isTranscribing || dictation.isDictating
                    || appleDictation.isDictating || audioRecorder.isRecording)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .popover(isPresented: $showVoiceOptions, arrowEdge: .top) {
            VoiceInputOptionsView(
                methodRaw: $speechInputMethodRaw,
                loadPolicyRaw: $whisperLoadPolicyRaw,
                whisperModelID: $whisperModelID,
                dismiss: { showVoiceOptions = false })
                .environmentObject(loc)
                .environmentObject(models)
        }
        .contextMenu { voiceContextMenu }
        .help(voiceButtonHelp)
    }

    @ViewBuilder
    private var voiceContextMenu: some View {
        Picker(loc.t("Método del micrófono", "Microphone method"), selection: $speechInputMethodRaw) {
            Text(loc.t("Dictado de Apple", "Apple Dictation")).tag(SpeechInputMethod.apple.rawValue)
            Text("Whisper.cpp · GPU").tag(SpeechInputMethod.whisper.rawValue)
        }

        if speechInputMethodRaw == SpeechInputMethod.whisper.rawValue {
            let selected = WhisperModel.model(id: whisperModelID)
            Picker(loc.t("Carga de Whisper", "Whisper loading"), selection: $whisperLoadPolicyRaw) {
                Text(loc.t("Bajo demanda", "On demand")).tag(WhisperLoadPolicy.onDemand.rawValue)
                Text(loc.t("Siempre cargado", "Always loaded")).tag(WhisperLoadPolicy.alwaysLoaded.rawValue)
            }
            Menu(loc.t("Modelo Whisper", "Whisper model"), systemImage: "waveform.badge.magnifyingglass") {
                Picker(loc.t("Modelo Whisper", "Whisper model"), selection: $whisperModelID) {
                    ForEach(WhisperModel.catalog) { model in
                        Text("\(model.name) · \(model.sizeMB) MB").tag(model.id)
                    }
                }
            }
            if dictation.isModelKeptLoaded {
                Label(loc.t("Modelo listo en la GPU", "Model ready on the GPU"),
                      systemImage: "memorychip.fill")
                Button(loc.t("Detener y liberar Whisper", "Stop and unload Whisper"),
                       systemImage: "stop.circle") {
                    dictation.shutdown()
                }
            }
            if !models.whisperModelInstalled(selected) {
                if let download = models.whisperDownload(selected) {
                    if download.error != nil {
                        Button(loc.t("Reintentar descarga", "Retry download"),
                               systemImage: "arrow.clockwise") {
                            models.retryWhisperDownload(download)
                        }
                    } else if download.phase == .paused {
                        Button(loc.t("Reanudar descarga", "Resume download"),
                               systemImage: "arrow.down.circle", action: download.resume)
                    } else {
                        Label(loc.t("Descargando %@…", "Downloading %@…", "\(selected.name)"),
                              systemImage: "arrow.down.circle")
                    }
                } else {
                    Button(loc.t("Descargar %@", "Download %@", "\(selected.name)"),
                           systemImage: "arrow.down.circle") {
                        models.downloadWhisperModel(selected)
                    }
                }
            }
        }

        Divider()
        Button(loc.t("Mostrar opciones de voz…", "Show voice options…"),
               systemImage: "slider.horizontal.3") {
            showVoiceOptions = true
        }
        if audioAvailable {
            Button(loc.t("Grabar para el modelo", "Record for the model"),
                   systemImage: "waveform", action: startRecording)
        }
    }

    private var voiceButtonTitle: String {
        if dictation.isTranscribing { return loc.t("Cancelar transcripción", "Cancel transcription") }
        if dictation.isDictating { return loc.t("Transcribir", "Transcribe") }
        if appleDictation.isDictating { return loc.t("Detener dictado", "Stop dictation") }
        if audioRecorder.isRecording { return loc.t("Detener grabación", "Stop recording") }
        return loc.t("Voz", "Voice")
    }

    private var voiceButtonHelp: String {
        if dictation.isTranscribing {
            return loc.t("Whisper.cpp está transcribiendo en la GPU; clic para cancelar.",
                         "Whisper.cpp is transcribing on the GPU; click to cancel.")
        }
        if dictation.isDictating {
            return loc.t("Escuchando con Whisper… clic para transcribir.",
                         "Listening with Whisper… click to transcribe.")
        }
        if appleDictation.isDictating {
            return loc.t("Dictado de Apple activo; clic para detener.",
                         "Apple Dictation is active; click to stop.")
        }
        if speechInputMethodRaw.isEmpty {
            return loc.t("Configura la entrada de voz. Después: clic para dictar, clic derecho para cambiar.",
                         "Set up voice input. Then: click to dictate, right-click to change it.")
        }
        return loc.t("Clic para dictar; clic derecho para método, modelo y carga.",
                     "Click to dictate; right-click for method, model, and loading.")
    }

    private func primaryVoiceAction() {
        if dictation.isDictating || dictation.isTranscribing
            || appleDictation.isDictating || audioRecorder.isRecording {
            stopVoice()
            return
        }
        guard let method = SpeechInputMethod(rawValue: speechInputMethodRaw) else {
            showVoiceOptions = true
            return
        }
        switch method {
        case .apple: startAppleDictation()
        case .whisper: startWhisperDictation()
        }
    }

    private func prepareDictationBase() {
        attachError = nil
        let base = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        dictationBase = base.isEmpty ? "" : base + " "
    }

    private func startAppleDictation() {
        prepareDictationBase()
        appleDictation.toggle { draft = dictationBase + $0 }
    }

    private func startWhisperDictation() {
        prepareDictationBase()
        let model = WhisperModel.model(id: whisperModelID)
        guard models.whisperModelInstalled(model) else {
            showVoiceOptions = true
            return
        }
        dictation.toggle(modelURL: model.url(in: models.whisperDirectory),
                         gpuIndex: gpuIndex,
                         loadPolicy: whisperLoadPolicy) {
            draft = dictationBase + $0
        }
    }

    private func startRecording() {
        attachError = nil
        audioRecorder.toggle { attachments.append($0) }
    }

    private func stopVoice() {
        if dictation.isDictating {
            let model = WhisperModel.model(id: whisperModelID)
            dictation.toggle(modelURL: model.url(in: models.whisperDirectory),
                             gpuIndex: gpuIndex,
                             loadPolicy: whisperLoadPolicy) {
                draft = dictationBase + $0
            }
        } else if dictation.isTranscribing {
            dictation.cancel()
        }
        if appleDictation.isDictating { appleDictation.stop() }
        if audioRecorder.isRecording { audioRecorder.toggle { attachments.append($0) } }
    }

    private func configureWhisperResidency() {
        guard whisperLoadPolicy == .alwaysLoaded else {
            dictation.unloadPersistentModel()
            return
        }
        // Do not reload Whisper after an explicit engine stop.
        guard server.state == .starting || server.state == .running else {
            dictation.unloadPersistentModel()
            return
        }
        let model = WhisperModel.model(id: whisperModelID)
        guard models.whisperModelInstalled(model) else { return }
        dictation.preload(modelURL: model.url(in: models.whisperDirectory), gpuIndex: gpuIndex)
    }

    private func stopSpeechSubsystem() {
        let pendingAttachmentIDs = Set(transcriptionQueue.map(\.attachmentID))
        transcriptionQueue.removeAll()
        transcriptionPending = 0
        attachments.removeAll { pendingAttachmentIDs.contains($0.id) }
        dictation.shutdown()
        appleDictation.shutdown()
        if audioRecorder.isRecording {
            audioRecorder.cancel()
        }
    }

    private var toolsButton: some View {
        Button {
            showTools.toggle()
        } label: {
            ComposerCircleLabel(
                title: loc.t("Herramientas", "Tools"),
                systemImage: "wrench.and.screwdriver",
                active: showTools)
        }
        .buttonStyle(.plain)
        .disabled(chat.generating)
        .popover(isPresented: $showTools, arrowEdge: .top) { toolsPopover }
        .help(loc.t("Herramientas disponibles para esta conversación",
                    "Tools available to this conversation"))
    }

    private var toolsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(loc.t("Herramientas del chat", "Chat tools"),
                      systemImage: "wrench.and.screwdriver")
                    .font(.headline)
                Spacer()
                Button(loc.t("Activar todas", "Enable all"), systemImage: "checkmark.circle") {
                    chat.enableAllTools()
                }
                .buttonStyle(.borderless)
            }
            Divider()
            ForEach(availableTools) { tool in
                let enabled = chat.current?.enabledToolNames.map { $0.contains(tool.name) } ?? true
                Button {
                    chat.toggleTool(tool.name, allTools: availableTools)
                } label: {
                    HStack {
                        Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(enabled ? Color.appAccent : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.displayName)
                            Text(tool.name).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func refreshAvailableTools() async {
        loadingTools = true
        var tools: [BuiltinToolInfo] = []
        if UserDefaults.standard.bool(forKey: SettingsKeys.agentToolsEnabled),
           let builtins = try? await ChatToolsService.list(port: port) {
            tools += builtins
        }
        if UserDefaults.standard.bool(forKey: SettingsKeys.jsSandboxEnabled) {
            tools.append(JavaScriptSandboxService.tool)
        }
        if ChatMemoryService.isEnabled { tools += ChatMemoryService.tools }
        tools += await ToshMCPService.shared.discoverTools()
        var seen = Set<String>()
        availableTools = tools.filter { seen.insert($0.name).inserted }
        loadingTools = false
    }

    private func refreshModelModalities() async {
        guard server.state == .running else {
            modelModalities = nil
            loadingModalities = false
            return
        }
        loadingModalities = true
        let selected = routerMode && !chatSelectedModel.isEmpty ? chatSelectedModel : nil
        if let fetched = try? await ModelCapabilitiesService.fetch(port: port, model: selected) {
            modelModalities = fetched
            capabilitiesAreComplete = true
        } else if routerMode,
                  let local = models.models.first(where: {
                      ServerSettings.routerAlias(for: $0.url.path) == chatSelectedModel
                  }) {
            modelModalities = ModelModalities(
                vision: ServerSettings.mmprojPath(forModel: local.url.path) != nil,
                audio: false, video: false, thinking: nil)
            capabilitiesAreComplete = false
        } else {
            modelModalities = nil
            capabilitiesAreComplete = false
        }
        loadingModalities = false
    }

    @ViewBuilder
    private var modalityBadges: some View {
        HStack(spacing: 6) {
            if loadingModalities {
                ProgressView().controlSize(.small)
                Text(loc.t("Detectando capacidades…", "Detecting capabilities…"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let modelModalities {
                modalityBadge(loc.t("Texto", "Text"), icon: "text.alignleft", enabled: true)
                modalityBadge(loc.t("Visión", "Vision"), icon: "eye", enabled: modelModalities.vision)
                if capabilitiesAreComplete {
                    modalityBadge(loc.t("Audio", "Audio"), icon: "waveform", enabled: modelModalities.audio)
                    modalityBadge(loc.t("Video", "Video"), icon: "film", enabled: modelModalities.video)
                } else {
                    Label(loc.t("Se completan al cargar", "Complete after loading"),
                          systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label(loc.t("Capacidades no disponibles", "Capabilities unavailable"),
                      systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func modalityBadge(_ title: String, icon: String, enabled: Bool) -> some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background((enabled ? Color.accentColor : Color.secondary).opacity(enabled ? 0.14 : 0.07),
                        in: Capsule())
            .help(enabled
                  ? loc.t("Compatible", "Supported")
                  : loc.t("No compatible con el modelo seleccionado", "Not supported by the selected model"))
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
                        .iconHelp(loc.t("Quitar esta imagen", "Remove this image"))
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
                        Image(systemName: a.mediaKind == "audio" ? "waveform"
                              : a.mediaKind == "video" ? "film" : "doc.text")
                        Text(a.name).lineLimit(1)
                        if a.mediaKind == nil {
                            Text("~\(a.estimatedTokens)t")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                        } else {
                            Button(loc.t("Vista previa", "Preview"), systemImage: "play.circle") {
                                previewAttachment = a
                            }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                        }
                        Button {
                            attachments.removeAll { $0.id == a.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .iconHelp(loc.t("Quitar este archivo.", "Remove this file."))
                    }
                    .font(.caption)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                    .help(loc.t("Se enviará al modelo junto con tu mensaje (~%@ tokens).",
                                "Sent to the model along with your message (~%@ tokens).",
                                String(a.estimatedTokens)))
                }
                if attachmentsExceedContext {
                    Label(loc.t("Adjuntos ~%@k tokens > contexto %@k: sube el contexto en Ajustes o quita archivos", "Attachments ~%@k tokens > context %@k: raise the context in Settings or remove files", "\(attachmentTokens / 1000)", "\(contextLimit / 1000)"),
                          systemImage: "exclamationmark.octagon.fill")
                        .font(.caption2).foregroundStyle(.red)
                        .help(loc.t("Lo adjunto no cabe en el contexto configurado, así que el envío fallará con 'contexto lleno'. Sube el contexto en Ajustes, quita archivos o inicia un chat nuevo.",
                                    "The attachments don't fit the configured context, so sending will fail with 'context full'. Raise the context in Settings, remove files or start a new chat."))
                } else if attachmentsTooLarge {
                    Label(loc.t("Adjuntos ~%@k tokens: pueden llenar el contexto (%@k)", "Attachments ~%@k tokens: may fill the context (%@k)", "\(attachmentTokens / 1000)", "\(contextLimit / 1000)"),
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

    private func absorbLargeDraft(_ value: String) {
        guard pasteLongTextLength > 0, value.count > pasteLongTextLength else { return }
        let base = loc.t("Texto pegado", "Pasted text")
        let existing = attachments.filter { $0.name.hasPrefix(base) }.count
        let name = existing == 0 ? base + ".txt" : "\(base) \(existing + 1).txt"
        attachments.append(ChatAttachment(name: name, content: value))
        draft = ""
    }

    /// Whether the clipboard holds something we attach instead of pasting as text.
    /// NSImage covers every readable image type (PNG, JPEG, TIFF, HEIC…).
    private var clipboardHasAttachables: Bool {
        let pb = NSPasteboard.general
        return (pb.types ?? []).contains(.fileURL) || NSImage.canInit(with: pb)
    }

    /// Cmd+V with an image (screenshot) or copied files on the clipboard attaches
    /// them like a drop; plain text keeps the field's normal paste.
    private func pasteFromClipboard() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            addAttachments(urls: urls)
            return
        }
        guard let img = NSImage(pasteboard: pb), let data = img.tiffRepresentation else { return }
        guard visionAvailable else {
            attachError = loc.t("Imagen pegada: el modelo actual no admite imágenes (carga un modelo con visión y su mmproj)",
                                "Pasted image: the current model can't read images (load a vision model with its mmproj)")
            return
        }
        guard let uri = Self.imageDataURI(from: data, maxMegapixels: maxImageMegapixels) else {
            attachError = loc.t("No se pudo procesar la imagen pegada", "Couldn't process the pasted image")
            return
        }
        attachError = nil
        images.append(uri)
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { addAttachments(urls: panel.urls) }
    }

    private func loadVideoDuration(url: URL, attachmentID: UUID) {
        Task { @MainActor in
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration) else { return }
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else { return }
            var area: Int? = nil
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize) {
                area = Int(abs(size.width) * abs(size.height))
            }
            guard let idx = attachments.firstIndex(where: { $0.id == attachmentID }) else { return }
            attachments[idx].durationSeconds = seconds
            attachments[idx].videoFrameArea = area
        }
    }

    // Read cap (raw bytes) and extracted-text cap. Text beyond the latter is
    // truncated with a note; the proactive context warning catches huge totals.
    private static let maxAttachBytes = 40 * 1024 * 1024
    private static let maxAttachChars = 400_000

    private func addAttachments(urls: [URL]) {
        var errors: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()

            if ["wav", "mp3", "m4a", "aac", "flac", "ogg", "oga", "mp4", "mov", "webm", "mkv"].contains(ext) {
                // Microphone dictation cannot advance the file queue.
                if (dictation.isDictating || dictation.isTranscribing || appleDictation.isDictating),
                   transcriptionPending == 0 {
                    errors.append(loc.t("%@: termina primero el dictado del micrófono", "%@: finish microphone dictation first", "\(name)"))
                    continue
                }
                let model = WhisperModel.model(id: whisperModelID)
                guard models.whisperModelInstalled(model) else {
                    models.downloadWhisperModel(model)
                    errors.append(loc.t("%@: descarga primero %@ para transcribirlo", "%@: download %@ first to transcribe it", "\(name)", "\(model.name)"))
                    continue
                }
                let pendingID = UUID()
                attachments.append(ChatAttachment(
                    id: pendingID, name: name,
                    content: loc.t("(transcribiendo localmente con Whisper.cpp…)",
                                   "(transcribing locally with Whisper.cpp…)")))
                transcriptionQueue.append(PendingSpeechTranscription(
                    id: UUID(), fileURL: url, modelURL: model.url(in: models.whisperDirectory),
                    attachmentID: pendingID, name: name))
                transcriptionPending += 1
                startNextFileTranscription()
                continue
            }

            guard let data = try? Data(contentsOf: url) else {
                errors.append(loc.t("%@: no se pudo leer", "%@: couldn't read it", "\(name)")); continue
            }
            guard data.count <= Self.maxAttachBytes else {
                errors.append(loc.t("%@: demasiado grande (máx 40 MB)", "%@: too large (max 40 MB)", "\(name)")); continue
            }

            // Images → vision (only if the loaded model has a multimodal projector).
            if ["png", "jpg", "jpeg", "heic", "heif", "gif", "bmp", "tiff", "tif", "webp"].contains(ext) {
                guard visionAvailable else {
                    errors.append(loc.t("%@: el modelo actual no admite imágenes (carga un modelo con visión y su mmproj)", "%@: the current model can't read images (load a vision model with its mmproj)", "\(name)")); continue
                }
                guard let uri = Self.imageDataURI(from: data, maxMegapixels: maxImageMegapixels) else {
                    errors.append(loc.t("%@: no se pudo procesar la imagen", "%@: couldn't process the image", "\(name)")); continue
                }
                images.append(uri); continue
            }

            var text: String
            if ext == "pdf" || data.prefix(5) == Data("%PDF-".utf8) {
                guard let pdf = PDFDocument(data: data) else {
                    errors.append(loc.t("%@: no se pudo abrir el PDF", "%@: couldn't open the PDF", "\(name)")); continue
                }
                if pdfAsImages && visionAvailable {
                    ocrPending += 1
                    Task { @MainActor in
                        let pages = Self.pdfImageURIs(pdf, maxPages: 20,
                                                      maxMegapixels: maxImageMegapixels)
                        images.append(contentsOf: pages)
                        ocrPending -= 1
                        if pages.isEmpty {
                            attachError = (attachError.map { $0 + "\n" } ?? "")
                                + loc.t("%@: no se pudieron renderizar sus páginas", "%@: its pages couldn't be rendered", "\(name)")
                        }
                    }
                    continue
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
                                + loc.t("%@: el OCR no encontró texto", "%@: OCR found no text", "\(name)")
                        } else {
                            attachments[idx].content = loc.t("[Texto extraído por OCR — %@]\n\n", "[Text extracted via OCR — %@]\n\n", "\(name)") + ocr
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
                    errors.append(loc.t("%@: binario sin texto legible", "%@: binary with no readable text", "\(name)")); continue
                }
                text = loc.t("[Cadenas extraídas de un binario — %@]\n\n", "[Strings extracted from a binary — %@]\n\n", "\(name)") + s
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

    private func startNextFileTranscription() {
        guard !dictation.isTranscribing, !dictation.isDictating, !appleDictation.isDictating,
              let pending = transcriptionQueue.first else { return }
        dictation.transcribe(fileURL: pending.fileURL,
                             modelURL: pending.modelURL,
                             gpuIndex: gpuIndex,
                             loadPolicy: whisperLoadPolicy) { transcript in
            completeFileTranscription(pending, transcript: transcript)
        } onFailure: {
            failFileTranscription(pending)
        }
    }

    private func completeFileTranscription(_ pending: PendingSpeechTranscription,
                                           transcript: String) {
        transcriptionQueue.removeAll { $0.id == pending.id }
        transcriptionPending = max(0, transcriptionPending - 1)
        if let idx = attachments.firstIndex(where: { $0.id == pending.attachmentID }) {
            let clipped = transcript.count > Self.maxAttachChars
                ? String(transcript.prefix(Self.maxAttachChars))
                    + loc.t("\n\n[…transcripción truncada…]", "\n\n[…transcript truncated…]")
                : transcript
            attachments[idx].content = loc.t("[Transcripción local — %@]\n\n", "[Local transcript — %@]\n\n", "\(pending.name)") + clipped
        }
        startNextFileTranscription()
    }

    private func failFileTranscription(_ pending: PendingSpeechTranscription) {
        transcriptionQueue.removeAll { $0.id == pending.id }
        transcriptionPending = max(0, transcriptionPending - 1)
        attachments.removeAll { $0.id == pending.attachmentID }
        startNextFileTranscription()
    }

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

    private var visionAvailable: Bool {
        modelModalities?.vision ?? (!routerMode && ServerSettings.mmprojPath(forModel: modelPath) != nil)
    }

    private var audioAvailable: Bool { modelModalities?.audio ?? false }
    private var videoAvailable: Bool { modelModalities?.video ?? false }

    private static func imageDataURI(from data: Data, maxMegapixels: Double) -> String? {
        guard let img = NSImage(data: data),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let pixelLimit = maxMegapixels > 0 ? maxMegapixels * 1_000_000 : Double.greatestFiniteMagnitude
        let scale = min(1, sqrt(pixelLimit / Double(w * h)))
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

    @MainActor
    private static func pdfImageURIs(_ document: PDFDocument, maxPages: Int,
                                     maxMegapixels: Double) -> [String] {
        var output: [String] = []
        for index in 0..<min(document.pageCount, maxPages) {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let aspect = max(0.1, bounds.width / max(1, bounds.height))
            let pixels = maxMegapixels > 0 ? maxMegapixels * 1_000_000 : 4_000_000
            let height = sqrt(pixels / Double(aspect))
            let size = CGSize(width: max(1, height * Double(aspect)), height: max(1, height))
            let thumbnail = page.thumbnail(of: size, for: .mediaBox)
            guard let data = thumbnail.tiffRepresentation,
                  let uri = imageDataURI(from: data, maxMegapixels: 0) else { continue }
            output.append(uri)
        }
        return output
    }

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

    private var statusStrip: some View {
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

                if server.state == .running && contextLimit > 0 {
                    let used = chat.contextUsed ?? 0
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

                if server.state == .running && contextMaySlowGeneration && chat.canCompactCurrent {
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
        .frame(minHeight: 24)
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
        frozenStream = nil
        if chat.agentFlowActive {
            chat.queueMessage(text: text, attachments: files, images: imgs)
            return
        }
        chat.send(text: text, attachments: files, images: imgs, port: port, temperature: temperature,
                  maxTokens: maxTokens, system: chat.effectiveSystemPrompt(global: systemPrompt),
                  thinking: thinkingEnabled, sampling: samplingSettings,
                  modalities: modelModalities)
    }
}

// MARK: - Conversation list (split-view sidebar)

enum ConversationSortOrder: String, CaseIterable {
    case lastUsed, created, title

    func label(_ loc: Localizer) -> String {
        switch self {
        case .lastUsed: return loc.t("Uso reciente", "Recently used")
        case .created: return loc.t("Fecha de creación", "Date created")
        case .title: return loc.t("Título (A-Z)", "Title (A-Z)")
        }
    }
}

struct ConversationListView: View {
    @EnvironmentObject var chat: ChatStore
    @EnvironmentObject var loc: Localizer
    @AppStorage(SettingsKeys.appAccent) private var accentRaw = AppTheme.defaultKey
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var renaming: Conversation?
    @State private var renameText = ""
    @State private var renamingProject: ChatProject?
    @State private var creatingProject = false
    @State private var newProjectName = ""
    @State private var promptProject: ChatProject?
    @State private var promptConversation: Conversation?
    @State private var archiveMessage: String?
    @State private var confirmDeleteAll = false
    @State private var hoveredConversationID: UUID?
    @State private var dropTargetProjectID: UUID?
    @State private var ungroupedDropIsTargeted = false
    @AppStorage(SettingsKeys.chatSortOrder) private var sortOrderRaw = ConversationSortOrder.lastUsed.rawValue

    private var sortOrder: ConversationSortOrder {
        ConversationSortOrder(rawValue: sortOrderRaw) ?? .lastUsed
    }

    private var searching: Bool { !debouncedSearchText.trimmingCharacters(in: .whitespaces).isEmpty }

    private func sorted(_ base: [Conversation]) -> [Conversation] {
        base.sorted { a, b in
            switch sortOrder {
            case .lastUsed: return a.updated > b.updated
            case .created: return a.created > b.created
            case .title: return chat.displayTitle(a).localizedCaseInsensitiveCompare(chat.displayTitle(b)) == .orderedAscending
            }
        }
    }

    private var searchResults: [Conversation] {
        let query = debouncedSearchText.trimmingCharacters(in: .whitespaces)
        return sorted(chat.conversations.filter { c in
            chat.displayTitle(c).localizedCaseInsensitiveContains(query) ||
            c.messages.contains { $0.content.localizedCaseInsensitiveContains(query) }
        })
    }

    /// Pinned chats surface in their own section; the rest stay in their group.
    private var pinnedChats: [Conversation] { sorted(chat.conversations.filter { $0.pinned ?? false }) }
    private var ungroupedChats: [Conversation] {
        sorted(chat.conversations.filter { !($0.pinned ?? false) && $0.projectID == nil })
    }
    private func projectChats(_ p: ChatProject) -> [Conversation] {
        sorted(chat.conversations.filter { !($0.pinned ?? false) && $0.projectID == p.id })
    }
    private var sortedProjects: [ChatProject] {
        chat.projects.sorted { a, b in
            if (a.pinned ?? false) != (b.pinned ?? false) { return a.pinned ?? false }
            return a.created > b.created
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
                chat.newConversation(in: chat.current?.projectID)
            } label: {
                HStack(spacing: 8) {
                    Label(loc.t("Nueva conversación", "New chat"), systemImage: "plus")
                    Spacer(minLength: 8)
                    Text("⌘ N")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassPillButtonStyle(prominent: true))
            .keyboardShortcut("n", modifiers: .command)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .help(loc.t("Empieza una conversación nueva en el proyecto actual (⌘N).",
                        "Start a new conversation in the current project (⌘N)."))

            HStack(spacing: 8) {
                GlassSearchField(placeholder: loc.t("Buscar conversaciones…", "Search conversations…"), text: $searchText)

                Menu {
                    ForEach(ConversationSortOrder.allCases, id: \.self) { order in
                        Button {
                            sortOrderRaw = order.rawValue
                        } label: {
                            if order == sortOrder {
                                Label(order.label(loc), systemImage: "checkmark")
                            } else {
                                Text(order.label(loc))
                            }
                        }
                    }
                    Divider()
                    Button(loc.t("Importar archivo…", "Import archive…"),
                           systemImage: "square.and.arrow.down") { importArchive() }
                    Button(loc.t("Exportar todo…", "Export all…"),
                           systemImage: "square.and.arrow.up") { exportArchive() }
                    Button(loc.t("Exportar JSONL para llama.cpp…", "Export JSONL for llama.cpp…"),
                           systemImage: "doc.text") { exportJSONL() }
                    Divider()
                    Button(loc.t("Borrar todas las conversaciones…", "Delete all conversations…"),
                           systemImage: "trash", role: .destructive) { confirmDeleteAll = true }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .tint(.secondary)
                .frame(width: 28, height: 28)
                .glassSurface(in: Circle(), interactive: true)
                .overlay(Circle().strokeBorder(.primary.opacity(0.07)))
                .accessibilityLabel(loc.t("Acciones de conversaciones", "Conversation actions"))
                .help(loc.t("Ordenar, importar, exportar y borrar conversaciones",
                            "Sort, import, export and delete conversations"))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            List {
                if searching {
                    ForEach(searchResults) { chatRow($0, showsProject: true) }
                } else {
                    if !pinnedChats.isEmpty {
                        Section {
                            ForEach(pinnedChats) { chatRow($0, showsProject: true) }
                        } header: {
                            sidebarHeader(loc.t("Fijados", "Pinned"))
                        }
                    }
                    if !chat.projects.isEmpty {
                        Section {
                            ForEach(sortedProjects) { p in
                                DisclosureGroup(isExpanded: expandBinding(p)) {
                                    let rows = projectChats(p)
                                    if rows.isEmpty {
                                        Text(loc.t("Sin conversaciones", "No conversations"))
                                            .font(.caption).foregroundStyle(.tertiary)
                                    } else {
                                        ForEach(rows) { chatRow($0, showsProject: false) }
                                    }
                                } label: {
                                    projectRow(p)
                                }
                            }
                        } header: {
                            sidebarHeader(loc.t("Proyectos", "Projects"), actionIcon: "plus") {
                                newProjectName = ""
                                creatingProject = true
                            }
                        }
                    } else {
                        Section {
                            EmptyView()
                        } header: {
                            sidebarHeader(loc.t("Proyectos", "Projects"), actionIcon: "plus") {
                                newProjectName = ""
                                creatingProject = true
                            }
                        }
                    }
                    Section {
                        ForEach(ungroupedChats) { chatRow($0, showsProject: false) }
                    } header: {
                        chatsHeader
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Text("ToshLLM · macOS")
                .font(.system(size: 10, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        }
        .navigationSplitViewColumnWidth(min: 270, ideal: 330, max: 390)
        .task(id: searchText) {
            let value = searchText
            if value.trimmingCharacters(in: .whitespaces).isEmpty {
                debouncedSearchText = ""
                return
            }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            debouncedSearchText = value
        }
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
        .alert(loc.t("Nuevo proyecto", "New project"), isPresented: $creatingProject) {
            TextField(loc.t("Nombre", "Name"), text: $newProjectName)
            Button(loc.t("Crear", "Create")) {
                let name = newProjectName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                let p = chat.newProject(name: name)
                chat.newConversation(in: p.id)
            }
            Button(loc.t("Cancelar", "Cancel"), role: .cancel) {}
        } message: {
            Text(loc.t("Una carpeta para tus conversaciones. Si le defines un prompt de sistema al proyecto, todas las conversaciones dentro lo heredan.",
                       "A folder for your conversations. If you set a system prompt on the project, every conversation inside inherits it."))
        }
        .sheet(item: $renamingProject) { project in
            ProjectRenameSheet(initial: project.name) { name in
                chat.renameProject(project, to: name)
            }
            .environmentObject(loc)
        }
        .sheet(item: $promptProject) { p in
            PromptEditorSheet(
                title: loc.t("Prompt del proyecto \"%@\"", "Project prompt for \"%@\"", "\(p.name)"),
                hint: loc.t("Lo heredan todas las conversaciones del proyecto que no tengan prompt propio.",
                            "Inherited by every conversation in the project without its own prompt."),
                initial: p.systemPrompt
            ) { chat.setProjectPrompt(p, $0) }
        }
        .sheet(item: $promptConversation) { c in
            PromptEditorSheet(
                title: loc.t("Prompt de esta conversación", "This conversation's prompt"),
                hint: loc.t("Sustituye al prompt del proyecto y al global solo en esta conversación. Vacío = heredar.",
                            "Overrides the project and global prompts for this conversation only. Empty = inherit."),
                initial: c.systemPrompt ?? ""
            ) { chat.setConversationPrompt(c, $0) }
        }
        .alert(loc.t("Conversaciones", "Conversations"),
               isPresented: Binding(get: { archiveMessage != nil },
                                    set: { if !$0 { archiveMessage = nil } })) {
            Button(loc.t("Aceptar", "OK")) { archiveMessage = nil }
        } message: {
            Text(archiveMessage ?? "")
        }
        .confirmationDialog(
            loc.t("¿Borrar las %@ conversaciones?", "Delete all %@ conversations?", "\(chat.conversations.count)"),
            isPresented: $confirmDeleteAll, titleVisibility: .visible
        ) {
            Button(loc.t("Borrar todas", "Delete all"), role: .destructive) { chat.deleteAll() }
            Button(loc.t("Cancelar", "Cancel"), role: .cancel) {}
        } message: {
            Text(loc.t("No se puede deshacer. Tus proyectos y sus prompts se conservan; exporta antes si quieres una copia.",
                       "This cannot be undone. Your projects and their prompts are kept; export first if you want a copy."))
        }
    }

    private func expandBinding(_ p: ChatProject) -> Binding<Bool> {
        Binding(get: { !(p.collapsed ?? false) },
                set: { chat.setProjectCollapsed(p, !$0) })
    }

    @ViewBuilder
    private func sidebarHeader(_ title: String, actionIcon: String? = nil,
                               action: @escaping () -> Void = {}) -> some View {
        HStack {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
            Spacer()
            if let actionIcon {
                Button(action: action) {
                    Image(systemName: actionIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc.t("Nuevo proyecto", "New project"))
            }
        }
    }

    private var chatsHeader: some View {
        HStack {
            Text(loc.t("Conversaciones", "Chats"))
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
            Spacer()
            Text(ungroupedDropIsTargeted
                 ? loc.t("Soltar aquí", "Drop here")
                 : sortOrder.label(loc))
                .font(.caption)
                .foregroundStyle(ungroupedDropIsTargeted
                                 ? AnyShapeStyle(Color.appAccent)
                                 : AnyShapeStyle(.tertiary))
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { ids, _ in
            let moved = conversations(for: ids)
            guard !moved.isEmpty else { return false }
            moved.forEach { chat.move($0, toProject: nil) }
            return true
        } isTargeted: { ungroupedDropIsTargeted = $0 }
    }

    private func conversations(for ids: [String]) -> [Conversation] {
        ids.compactMap(UUID.init(uuidString:))
            .compactMap { id in chat.conversations.first { $0.id == id } }
    }

    private func conversationTitle(_ conversation: Conversation) -> String {
        if conversation.title.isEmpty && conversation.messages.isEmpty {
            return loc.t("Nueva conversación", "New chat")
        }
        return chat.displayTitle(conversation)
    }

    private func importArchive() {
        let panel = NSOpenPanel()
        var allowedTypes: [UTType] = [.json]
        if let jsonl = UTType(filenameExtension: "jsonl") { allowedTypes.append(jsonl) }
        panel.allowedContentTypes = allowedTypes
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try chat.importArchiveData(Data(contentsOf: url))
            archiveMessage = loc.t("Se importaron %@ conversaciones nuevas.", "Imported %@ new conversations.", "\(count)")
        } catch {
            archiveMessage = error.localizedDescription
        }
    }

    private func exportArchive() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ToshLLM-conversations.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try chat.exportArchiveData().write(to: url, options: .atomic)
            archiveMessage = loc.t("Historial exportado correctamente.",
                                   "Conversation history exported successfully.")
        } catch {
            archiveMessage = error.localizedDescription
        }
    }

    private func exportJSONL() {
        let panel = NSSavePanel()
        if let jsonl = UTType(filenameExtension: "jsonl") { panel.allowedContentTypes = [jsonl] }
        panel.nameFieldStringValue = "ToshLLM-conversations.jsonl"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try chat.exportJSONLData().write(to: url, options: .atomic)
            archiveMessage = loc.t("Historial JSONL compatible con llama.cpp exportado correctamente.",
                                   "llama.cpp-compatible JSONL history exported successfully.")
        } catch {
            archiveMessage = error.localizedDescription
        }
    }

    // MARK: rows

    @ViewBuilder private func projectRow(_ p: ChatProject) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.accent(accentRaw))
                .frame(width: 32, height: 32)
                .background(AppTheme.accent(accentRaw).opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 9))
            Text(p.name)
                .font(.callout.weight(.medium)).lineLimit(1)
            if p.pinned ?? false {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
            }
            if !p.systemPrompt.trimmingCharacters(in: .whitespaces).isEmpty {
                Image(systemName: "text.bubble")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .help(loc.t("Este proyecto tiene prompt de sistema propio.",
                                "This project has its own system prompt."))
            }
            Spacer(minLength: 4)
            Text("\(chat.conversations.filter { $0.projectID == p.id }.count)")
                .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.quaternary.opacity(0.6), in: Capsule())
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dropTargetProjectID == p.id ? Color.appAccent.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(dropTargetProjectID == p.id ? Color.appAccent.opacity(0.7) : .clear))
        .contentShape(Rectangle())
        // The disclosure only toggles from its chevron; open from the whole row.
        .onTapGesture { withAnimation { expandBinding(p).wrappedValue.toggle() } }
        .dropDestination(for: String.self) { ids, _ in
            let moved = conversations(for: ids)
            guard !moved.isEmpty else { return false }
            moved.forEach { chat.move($0, toProject: p.id) }
            return true
        } isTargeted: { targeted in
            dropTargetProjectID = targeted ? p.id : (dropTargetProjectID == p.id ? nil : dropTargetProjectID)
        }
        .contextMenu {
            Button(loc.t("Nueva conversación aquí", "New chat here")) {
                chat.setProjectCollapsed(p, false)
                chat.newConversation(in: p.id)
            }
            Button(loc.t("Prompt del proyecto…", "Project prompt…")) { promptProject = p }
            Button(p.workingDirectory == nil
                   ? loc.t("Carpeta del proyecto…", "Project folder…")
                   : loc.t("Cambiar carpeta del proyecto…", "Change project folder…")) {
                chat.pickProjectWorkingDirectory(p)
            }
            if p.workingDirectory != nil {
                Button(loc.t("Quitar carpeta del proyecto", "Clear project folder")) {
                    chat.setProjectWorkingDirectory(p, nil)
                }
            }
            Button(loc.t("Renombrar…", "Rename…")) {
                renamingProject = p
            }
            Button((p.pinned ?? false) ? loc.t("Desfijar proyecto", "Unpin project")
                                       : loc.t("Fijar proyecto", "Pin project")) {
                chat.togglePinProject(p)
            }
            Divider()
            Button(loc.t("Eliminar proyecto", "Delete project"), role: .destructive) {
                chat.deleteProject(p)
            }
        }
    }

    @ViewBuilder private func chatRow(_ c: Conversation, showsProject: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(WorkspaceStyle.inset, in: Circle())
            if c.pinned ?? false {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9)).foregroundStyle(AppTheme.accent(accentRaw).opacity(0.7))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(conversationTitle(c))
                    .font(.callout).lineLimit(1)
                HStack(spacing: 5) {
                    if showsProject, let p = chat.project(id: c.projectID) {
                        Label(p.name, systemImage: "folder")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .labelStyle(.titleAndIcon).lineLimit(1)
                    }
                    Text(relativeDate(c.updated))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            if !(c.systemPrompt ?? "").isEmpty {
                Image(systemName: "text.bubble")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .help(loc.t("Esta conversación tiene prompt propio.",
                                "This conversation has its own prompt."))
            }
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hoveredConversationID == c.id || chat.currentID == c.id
                                 ? AnyShapeStyle(Color.appAccent)
                                 : AnyShapeStyle(.quaternary))
                .frame(width: 18, height: 26)
                .help(loc.t("Puedes arrastrar toda la fila a un proyecto.",
                            "You can drag the entire row into a project."))
            Menu {
                Button((c.pinned ?? false) ? loc.t("Desfijar", "Unpin") : loc.t("Fijar", "Pin")) {
                    chat.togglePin(c)
                }
                Button(loc.t("Renombrar…", "Rename…")) {
                    renameText = conversationTitle(c)
                    renaming = c
                }
                Button(loc.t("Prompt de esta conversación…", "This conversation's prompt…")) {
                    promptConversation = c
                }
                Divider()
                Button(loc.t("Eliminar", "Delete"), role: .destructive) { chat.delete(c) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .opacity(hoveredConversationID == c.id || chat.currentID == c.id ? 1 : 0)
            .accessibilityLabel(loc.t("Acciones de la conversación", "Conversation actions"))
        }
        .padding(.leading, 0)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.interaction, RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture { chat.currentID = c.id }
        .onHover { inside in
            if inside {
                hoveredConversationID = c.id
            } else if hoveredConversationID == c.id {
                hoveredConversationID = nil
            }
        }
        .onDrag {
            NSItemProvider(object: c.id.uuidString as NSString)
        } preview: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.fill")
                Text(conversationTitle(c)).lineLimit(1)
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(WorkspaceStyle.surface,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.appAccent.opacity(0.6)))
        }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8)
                .fill(chat.currentID == c.id
                      ? AppTheme.accent(accentRaw).opacity(0.26) : Color.clear)
                .padding(.horizontal, 13))
        .contextMenu {
            Button((c.pinned ?? false) ? loc.t("Desfijar", "Unpin") : loc.t("Fijar", "Pin")) {
                chat.togglePin(c)
            }
            Button(loc.t("Renombrar…", "Rename…")) {
                renameText = conversationTitle(c)
                renaming = c
            }
            Button(loc.t("Prompt de esta conversación…", "This conversation's prompt…")) {
                promptConversation = c
            }
            Menu(loc.t("Mover a proyecto", "Move to project")) {
                Button(loc.t("Ninguno", "None")) { chat.move(c, toProject: nil) }
                ForEach(sortedProjects) { p in
                    Button(p.name + (c.projectID == p.id ? " ✓" : "")) {
                        chat.move(c, toProject: p.id)
                    }
                }
            }
            Divider()
            Button(loc.t("Copiar conversación", "Copy conversation")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(chat.exportText(c, loc), forType: .string)
            }
            Button(loc.t("Exportar a Markdown…", "Export to Markdown…")) {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = chat.displayTitle(c)
                    .replacingOccurrences(of: "/", with: "-") + ".md"
                if panel.runModal() == .OK, let url = panel.url {
                    try? chat.exportText(c, loc).write(to: url, atomically: true, encoding: .utf8)
                }
            }
            Button(loc.t("Eliminar", "Delete"), role: .destructive) { chat.delete(c) }
        }
    }
}

/// Shared editor for project and per-conversation system prompts.
struct PromptEditorSheet: View {
    @EnvironmentObject var loc: Localizer
    @Environment(\.dismiss) private var dismiss
    let title: String
    let hint: String
    let initial: String
    let onSave: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                SectionGlyph(systemName: "text.bubble")
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(loc.t("Instrucciones para esta parte del chat.",
                               "Instructions for this part of Chat."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .background(WorkspaceStyle.surface)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .focused($focused)
                    .frame(height: 190)
                    .workspaceFieldSurface(cornerRadius: 10)
                Label(hint, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(WorkspaceStyle.inset,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(WorkspaceStyle.border))
            }
            .padding(18)

            Divider()

            HStack(spacing: 10) {
                Spacer()
                Button(loc.t("Cancelar", "Cancel")) { dismiss() }
                    .glassButton()
                    .keyboardShortcut(.cancelAction)
                Button(loc.t("Guardar", "Save"), systemImage: "checkmark") {
                    onSave(text)
                    dismiss()
                }
                .glassButton(prominent: true)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(WorkspaceStyle.surface)
        }
        .frame(width: 540)
        .background(WorkspaceStyle.canvas)
        .onAppear {
            text = initial
            Task { await Task.yield(); focused = true }
        }
    }
}

/// Compact project-name editor using the same surfaces as the rest of Chat.
private struct ProjectRenameSheet: View {
    @EnvironmentObject private var loc: Localizer
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var focused: Bool
    let onSave: (String) -> Void

    init(initial: String, onSave: @escaping (String) -> Void) {
        _name = State(initialValue: initial)
        self.onSave = onSave
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                SectionGlyph(systemName: "folder")
                VStack(alignment: .leading, spacing: 3) {
                    Text(loc.t("Renombrar proyecto", "Rename project"))
                        .font(.title3.weight(.semibold))
                    Text(loc.t("El nuevo nombre aparecerá en la barra lateral.",
                               "The new name will appear in the sidebar."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .background(WorkspaceStyle.surface)

            Divider()

            SettingsRowGroup {
                SettingsRow(icon: "tag", title: loc.t("Nombre", "Name")) {
                    TextField(loc.t("Nombre del proyecto", "Project name"), text: $name)
                        .focused($focused)
                        .workspaceTextField(width: 280)
                }
            }
            .padding(18)

            Divider()

            HStack(spacing: 10) {
                Spacer()
                Button(loc.t("Cancelar", "Cancel")) { dismiss() }
                    .glassButton()
                    .keyboardShortcut(.cancelAction)
                Button(loc.t("Guardar", "Save"), systemImage: "checkmark", action: saveName)
                    .glassButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(WorkspaceStyle.surface)
        }
        .frame(width: 520)
        .background(WorkspaceStyle.canvas)
        .onAppear {
            Task { await Task.yield(); focused = true }
        }
    }

    private func saveName() {
        guard !trimmedName.isEmpty else { return }
        onSave(trimmedName)
        dismiss()
    }
}
