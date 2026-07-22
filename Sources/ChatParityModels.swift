import Foundation

struct ChatSamplingSettings: Equatable {
    var reasoningEffort = "medium"
    var topP = 0.95
    var minP = 0.05
    var topK = 40
    var repeatPenalty = 1.0
    var repeatLastN = 64
    var seed = -1
    var dynatempRange = 0.0
    var dynatempExponent = 1.0
    var xtcProbability = 0.0
    var xtcThreshold = 0.1
    var typicalP = 1.0
    var presencePenalty = 0.0
    var frequencyPenalty = 0.0
    var dryMultiplier = 0.0
    var dryBase = 1.75
    var dryAllowedLength = 2
    var dryPenaltyLastN = -1
    var samplers = ""
    var backendSampling = false
    var customJSON = ""
}

struct ChatTimings: Codable, Equatable {
    var cachedTokens: Int?
    var promptTokens: Int?
    var promptMilliseconds: Double?
    var generatedTokens: Int?
    var generationMilliseconds: Double?

    var promptTokensPerSecond: Double? {
        rate(tokens: promptTokens, milliseconds: promptMilliseconds)
    }

    var generationTokensPerSecond: Double? {
        rate(tokens: generatedTokens, milliseconds: generationMilliseconds)
    }

    private func rate(tokens: Int?, milliseconds: Double?) -> Double? {
        guard let tokens, let milliseconds, tokens > 0, milliseconds > 0 else { return nil }
        return Double(tokens) * 1_000 / milliseconds
    }

    init(cachedTokens: Int? = nil, promptTokens: Int? = nil,
         promptMilliseconds: Double? = nil, generatedTokens: Int? = nil,
         generationMilliseconds: Double? = nil) {
        self.cachedTokens = cachedTokens
        self.promptTokens = promptTokens
        self.promptMilliseconds = promptMilliseconds
        self.generatedTokens = generatedTokens
        self.generationMilliseconds = generationMilliseconds
    }

    init?(json: [String: Any]) {
        func int(_ key: String) -> Int? { (json[key] as? NSNumber)?.intValue }
        func double(_ key: String) -> Double? { (json[key] as? NSNumber)?.doubleValue }
        cachedTokens = int("cache_n")
        promptTokens = int("prompt_n")
        promptMilliseconds = double("prompt_ms")
        generatedTokens = int("predicted_n")
        generationMilliseconds = double("predicted_ms")
        if cachedTokens == nil, promptTokens == nil, generatedTokens == nil { return nil }
    }
}

enum ChatToolCallState: String, Codable {
    case pending
    case awaitingPermission
    case running
    case completed
    case failed
    case denied
}

struct ChatToolCall: Identifiable, Codable, Equatable {
    var id = UUID()
    var serverID: String?
    var name: String
    var arguments: String
    var result: String?
    var state: ChatToolCallState = .pending
    var startedAt: Date?
    var finishedAt: Date?
}

struct PendingToolPermission: Identifiable, Equatable {
    let id = UUID()
    let conversationID: UUID
    let messageID: UUID
    let callID: UUID
    let name: String
    let displayName: String
    let arguments: String
    let writesData: Bool
    let serverID: UUID?
    let serverName: String?
}

enum ToolPermissionDecision: Equatable {
    case once
    case always
    case alwaysServer
    case deny
}

struct ChatDraft: Codable, Equatable {
    var text = ""
    var attachments: [ChatAttachment] = []
    var imageURIs: [String] = []

    var isEmpty: Bool {
        text.isEmpty && attachments.isEmpty && imageURIs.isEmpty
    }
}

struct ChatArchive: Codable {
    var version = 1
    var exportedAt = Date()
    var conversations: [Conversation]
    var projects: [ChatProject]
}

enum ChatArchiveError: LocalizedError {
    case unsupported

    var errorDescription: String? {
        "The selected file is not a compatible ToshLLM conversation archive."
    }
}
