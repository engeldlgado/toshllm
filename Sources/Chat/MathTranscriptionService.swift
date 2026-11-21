// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Sends a math tool call together with the user's own words, so the helper can refuse a call
/// that does not say what the user asked. The text comes from the conversation, never from the
/// model: any argument the model starts with "_" is dropped before the app adds its own.
enum MathTranscriptionService {
    static let reviewInstructions = "You check a transcription. Do not solve anything. REQUEST is what the user asked. CALL is what will be computed. Answer consistent if CALL states the same mathematical problem as REQUEST: the same formulas, numbers, limits, conditions and data, even when written differently or with other variable names. Answer inconsistent if CALL changes, drops or adds any of them. Answer uncertain if REQUEST does not say enough to tell."
    static let reviewGrammar = #"root ::= "consistent" | "inconsistent" | "uncertain""#
    static let contextLimit = 6000

    static func isMathTool(_ name: String) -> Bool {
        SymPyToolsService.isTool(name) || ScientificToolsService.isTool(name)
    }

    /// The last user message is the request; earlier user messages and the results of calls that
    /// succeeded are context. A refused or failed call stays out, or its own numbers would vouch for it.
    static func source(messages: [ChatMessage]) -> [String: Any]? {
        guard let last = messages.lastIndex(where: { $0.role == "user" }) else { return nil }
        let calls = Dictionary(messages.flatMap { $0.toolCalls ?? [] }.map { ($0.serverID ?? $0.id.uuidString, $0) },
                               uniquingKeysWith: { first, _ in first })
        let earlier = messages.enumerated().compactMap { index, message -> String? in
            guard index != last else { return nil }
            if message.role == "user" { return message.wireContent }
            guard message.role == "tool" else { return nil }
            guard let call = message.toolCallID.flatMap({ calls[$0] }) else {
                return reply(message.content)?["success"] as? Bool == true ? message.content : nil
            }
            let trusted = isMathTool(call.name) ? succeeded(call) : call.state == .completed
            return trusted ? message.content : nil
        }.joined(separator: "\n")
        return ["request": messages[last].wireContent, "context": String(earlier.suffix(contextLimit))]
    }

    /// A math call that ran and gave a result; refused, failed and unfinished calls did not.
    static func succeeded(_ call: ChatToolCall) -> Bool {
        call.state == .completed && call.result.flatMap(reply)?["success"] as? Bool == true
    }

    static func execute(name: String, arguments: [String: Any], source: [String: Any]?, port: Int,
                        workingDirectory: String? = nil) async throws -> ToolExecutionResult {
        var plain = arguments.filter { !$0.key.hasPrefix("_") }
        guard let source else {
            return try await ChatToolsService.execute(name: name, arguments: plain, port: port,
                                                      workingDirectory: workingDirectory)
        }
        plain["_source"] = source
        plain["_trust"] = SymPyToolsService.trustKey
        let first = try await ChatToolsService.execute(name: name, arguments: plain, port: port,
                                                       workingDirectory: workingDirectory)
        guard let reply = reply(first.content), errorCode(reply) == "needs_review" else { return first }
        let verdict = try await review(source: source, reply: reply, operation: arguments["operation"] as? String,
                                       port: port)
        guard verdict == "consistent" else { return first }
        plain["_reviewed"] = "consistent"
        return try await ChatToolsService.execute(name: name, arguments: plain, port: port,
                                                  workingDirectory: workingDirectory)
    }

    /// The model compares the request with what the helper read; it never sees a result to defend.
    static func review(source: [String: Any], reply: [String: Any], operation: String?, port: Int) async throws -> String {
        let lines = (reply["interpreted_input"] as? [String]) ?? []
        let user = "REQUEST:\n\(source["request"] as? String ?? "")\n\nCALL: \(operation ?? "")\n"
            + lines.joined(separator: "\n") + " /no_think"
        var body: [String: Any] = [
            "messages": [["role": "system", "content": reviewInstructions], ["role": "user", "content": user]],
            "max_tokens": 4, "temperature": 0, "grammar": reviewGrammar, "cache_prompt": false,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        if let model = ServerSettings.activeRouterModel() { body["model"] = model }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = ServerSettings.activeAPIKey() { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = ((object?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
        return ((message?["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func reply(_ content: String) -> [String: Any]? {
        guard let start = content.firstIndex(of: "{") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(content[start...].utf8)) as? [String: Any]
    }

    /// Replies that mean the call was not computed because it did not match the request.
    static let rejectionCodes: Set<String> = ["transcription_mismatch", "needs_review"]
    static let clarifyToolName = "ask_user_to_clarify"

    /// Offered only after a rejected math call, next to the math tools, with a tool call required:
    /// the model can correct the call or ask, but not answer from memory.
    static let clarifyTool: [String: Any] = [
        "type": "function",
        "function": [
            "name": clarifyToolName,
            "description": "Ask the user to restate the problem when the math call cannot be written from the request.",
            "parameters": [
                "type": "object",
                "properties": ["missing": ["type": "string",
                                           "enum": ["formula", "data", "limits", "conditions", "method", "other"]]],
                "required": ["missing"],
            ] as [String: Any],
        ] as [String: Any],
    ]

    static func unresolvedMessage(missing: String? = nil) -> String {
        let loc = Localizer()
        let base = loc.t("No pude validar cómo interpretar matemáticamente la petición. Reformúlala o escribe la expresión explícitamente.",
                         "I couldn't validate the mathematical interpretation of that request. Please rephrase it or provide the expression explicitly.")
        let hint: String?
        switch missing {
        case "formula": hint = loc.t("Escribe la fórmula o ecuación completa.", "Write out the complete formula or equation.")
        case "data": hint = loc.t("Indica todos los datos o muestras.", "Give every data value or sample.")
        case "limits": hint = loc.t("Indica los límites o el intervalo.", "Give the limits or the interval.")
        case "conditions": hint = loc.t("Indica las condiciones iniciales, si las hay.", "Give the initial conditions, if there are any.")
        case "method": hint = loc.t("Indica el método que quieres usar.", "Say which method you want.")
        default: hint = nil
        }
        return hint.map { base + " " + $0 } ?? base
    }

    /// What the helper read from the call, for the card: the user checks it against the request.
    static func interpreted(_ reply: [String: Any]) -> [String] {
        ((reply["interpreted_input"] as? [String]) ?? []).map { "▸ " + $0 }
    }

    static func errorCode(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }
}

/// Per turn: once a math call has been refused for not matching the request, the turn may end only
/// with a validated math result, a request for clarification, or the fixed unresolved message.
struct MathTurnGuard: Equatable {
    private(set) var rejections = 0
    private(set) var pending = false

    enum Next: Equatable { case free, mathOnly, stop }

    /// One corrected call is allowed after a refusal; a second refusal ends the turn.
    var next: Next { !pending ? .free : rejections >= 2 ? .stop : .mathOnly }

    mutating func record(tool: String, result: String) {
        guard MathTranscriptionService.isMathTool(tool),
              let reply = MathTranscriptionService.reply(result) else { return }
        if reply["success"] as? Bool == true {
            pending = false
        } else if let code = MathTranscriptionService.errorCode(reply),
                  MathTranscriptionService.rejectionCodes.contains(code) {
            rejections += 1
            pending = true
        }
    }

    /// The text a mathOnly round may end with: a clarification or, with no tool call, the fixed message.
    /// Nil means the round made a math call and the turn goes on.
    func closing(toolNames: [String], arguments: [String]) -> String? {
        guard pending else { return nil }
        if let index = toolNames.firstIndex(of: MathTranscriptionService.clarifyToolName) {
            let missing = (try? ChatToolsService.parseArguments(arguments[index]))?["missing"] as? String
            return MathTranscriptionService.unresolvedMessage(missing: missing)
        }
        return toolNames.contains(where: MathTranscriptionService.isMathTool) ? nil
            : MathTranscriptionService.unresolvedMessage()
    }
}
