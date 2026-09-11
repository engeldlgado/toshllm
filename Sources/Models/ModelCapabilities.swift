// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct ModelModalities: Codable, Equatable, Sendable {
    var vision: Bool
    var audio: Bool
    var video: Bool
    var thinking: Bool?
    var reasoning: ReasoningEffortSupport?

    init(vision: Bool, audio: Bool, video: Bool, thinking: Bool? = nil,
         reasoning: ReasoningEffortSupport? = nil) {
        self.vision = vision
        self.audio = audio
        self.video = video
        self.thinking = thinking
        self.reasoning = reasoning
    }

    static let textOnly = ModelModalities(vision: false, audio: false, video: false)
}

enum ModelCapabilitiesService {
    private struct Props: Decodable {
        let modalities: ModelModalities?
        let chatTemplate: String?

        enum CodingKeys: String, CodingKey {
            case modalities
            case chatTemplate = "chat_template"
        }
    }

    static func fetch(port: Int, model: String?) async throws -> ModelModalities? {
        var components = URLComponents(string: "http://127.0.0.1:\(port)/props")!
        if let model, !model.isEmpty {
            components.queryItems = [
                URLQueryItem(name: "model", value: model),
                URLQueryItem(name: "autoload", value: "false"),
            ]
        }
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        if let key = ServerSettings.activeAPIKey() {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        let props = try JSONDecoder().decode(Props.self, from: data)
        var capabilities = props.modalities ?? .textOnly
        capabilities.thinking = props.chatTemplate.map(ThinkingSupportDetector.supportsThinking)
        capabilities.reasoning = props.chatTemplate.map(ReasoningEffortDetector.detect)
        capabilities.video = capabilities.video && VideoRuntimeAvailability.isAvailable
        return capabilities
    }
}

enum ThinkingSupportDetector {
    static func supportsThinking(_ template: String) -> Bool {
        guard !template.isEmpty else { return false }
        let lowered = template.lowercased()
        for variable in ["enable_thinking", "reasoning_effort", "thinking_budget"]
        where lowered.contains(variable) {
            return true
        }
        for pair in [("<think>", "</think>"),
                     ("<|think|>", "</|think|>"),
                     ("<seed:think|>", "</seed:think|>")]
        where lowered.contains(pair.0) && lowered.contains(pair.1) {
            return true
        }
        return lowered.contains("<|channel>thought") || lowered.contains("<think></think>")
    }
}

/// What a chat template accepts in `reasoning_effort`. Templates that validate
/// the value raise a Jinja exception on anything else, which reaches the app as
/// an HTTP 500.
struct ReasoningEffortSupport: Codable, Equatable, Sendable {
    /// Empty when the template never validates the value: anything is accepted.
    var levels: [String] = []
    var modelDefault: String?
}

enum ReasoningEffortDetector {
    // Only a membership test guarding a raise_exception is the accepted set:
    // templates also branch on the value to word the prompt, with partial lists.
    private static let guardPattern = try! NSRegularExpression(
        pattern: "[\\w.]*reasoning_effort\\s+not\\s+in\\s*[\\[(]([^\\])]*)[\\])]")
    private static let assignmentPattern = try! NSRegularExpression(
        pattern: "set\\s+[\\w.]*reasoning_effort\\s*=([^\\n]*)")
    // Some templates only name the default in the error they raise.
    private static let defaultMarkerPattern = try! NSRegularExpression(
        pattern: "([A-Za-z_][\\w-]*)\\s*\\(default\\)")
    private static let literalPattern = try! NSRegularExpression(pattern: "['\"]([^'\"]+)['\"]")

    /// Ladder of the levels llama.cpp names in --reasoning-effort, so the picker
    /// can order them and fall back to a lower one the model does accept.
    private static let ranks = ["none": 0, "no_think": 0, "minimal": 1, "low": 2,
                                "medium": 3, "high": 4, "xhigh": 5, "max": 6]

    static func rank(of level: String) -> Int? { ranks[level.lowercased()] }

    /// The level to use when the model rejects `effort`: the closest one it
    /// accepts at or below it, so its token budget is not lifted along the way.
    static func closest(to effort: String, in levels: [String]) -> String? {
        if levels.contains(effort) { return effort }
        guard let wanted = rank(of: effort) else { return nil }
        let ranked = levels.compactMap { level in rank(of: level).map { (level: level, rank: $0) } }
        let below = ranked.filter { $0.rank <= wanted }.max { $0.rank < $1.rank }
        return (below ?? ranked.min { $0.rank < $1.rank })?.level
    }

    static func detect(_ template: String) -> ReasoningEffortSupport {
        guard template.contains("reasoning_effort") else { return ReasoningEffortSupport() }
        let levels = validatedLevels(template)
        var fallback = defaultLevel(template)
        if let value = fallback, !levels.isEmpty, !levels.contains(value) { fallback = nil }
        return ReasoningEffortSupport(levels: levels, modelDefault: fallback)
    }

    private static func validatedLevels(_ template: String) -> [String] {
        let text = template as NSString
        let whole = NSRange(location: 0, length: text.length)
        for match in guardPattern.matches(in: template, range: whole) {
            let tail = NSRange(location: match.range.upperBound,
                               length: min(500, text.length - match.range.upperBound))
            guard text.substring(with: tail).contains("raise_exception") else { continue }
            let levels = literals(in: text.substring(with: match.range(at: 1)))
            if !levels.isEmpty { return ordered(levels) }
        }
        return []
    }

    private static func defaultLevel(_ template: String) -> String? {
        let text = template as NSString
        let whole = NSRange(location: 0, length: text.length)
        for match in assignmentPattern.matches(in: template, range: whole) {
            var statement = text.substring(with: match.range(at: 1))
            if let end = statement.range(of: "%}") { statement = String(statement[..<end.lowerBound]) }
            let before = NSRange(location: max(0, match.range.location - 160),
                                 length: min(160, match.range.location))
            // Only an assignment filling in a missing value is the default.
            guard text.substring(with: before).contains("defined")
                    || statement.contains("defined") || statement.contains("default")
            else { continue }
            if let literal = literals(in: statement).first { return literal }
        }
        if let match = defaultMarkerPattern.firstMatch(in: template, range: whole) {
            return text.substring(with: match.range(at: 1))
        }
        return nil
    }

    private static func literals(in fragment: String) -> [String] {
        let text = fragment as NSString
        return literalPattern
            .matches(in: fragment, range: NSRange(location: 0, length: text.length))
            .map { text.substring(with: $0.range(at: 1)) }
    }

    private static func ordered(_ levels: [String]) -> [String] {
        var seen = Set<String>()
        return levels.filter { seen.insert($0).inserted }
            .enumerated()
            .sorted {
                let left = ranks[$0.element.lowercased()] ?? 99
                let right = ranks[$1.element.lowercased()] ?? 99
                return left == right ? $0.offset < $1.offset : left < right
            }
            .map(\.element)
    }
}
