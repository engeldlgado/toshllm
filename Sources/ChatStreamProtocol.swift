import Foundation

struct ChatStreamEvent {
    var receivedContent = false
    var receivedToolCall = false
    var progress: Double?
    var completed = false
}

struct ChatStreamAccumulator {
    var reasoning = ""
    var visible = ""
    var usage: (prompt: Int, completion: Int)?
    var timings: ChatTimings?
    var mtpAccept: Double?
    var finishReason: String?
    private(set) var toolCalls: [ChatToolCall] = []

    mutating func consume(_ line: String) throws -> ChatStreamEvent? {
        guard line.hasPrefix("data: ") else { return nil }
        let payload = String(line.dropFirst(6))
        if payload == "[DONE]" { return ChatStreamEvent(completed: true) }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let message = ChatStore.streamedError(from: object) {
            throw StreamError(message: message)
        }

        if let value = object["usage"] as? [String: Any],
           let prompt = (value["prompt_tokens"] as? NSNumber)?.intValue,
           let completion = (value["completion_tokens"] as? NSNumber)?.intValue {
            usage = (prompt, completion)
        }

        if let value = object["timings"] as? [String: Any] {
            if let parsed = ChatTimings(json: value) { timings = parsed }
            if let drafted = (value["draft_n"] as? NSNumber)?.intValue, drafted > 0,
               let accepted = (value["draft_n_accepted"] as? NSNumber)?.intValue {
                mtpAccept = Double(accepted) / Double(drafted)
            }
        }

        var event = ChatStreamEvent()
        if let value = object["prompt_progress"] as? [String: Any],
           let processed = (value["processed"] as? NSNumber)?.intValue,
           let total = (value["total"] as? NSNumber)?.intValue, total > 0 {
            event.progress = min(1, Double(processed) / Double(total))
        }

        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return event }
        if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
            finishReason = reason
        }
        if let delta = choice["delta"] as? [String: Any] {
            if let text = delta["reasoning_content"] as? String, !text.isEmpty {
                reasoning += text
                event.receivedContent = true
            }
            if let text = delta["content"] as? String, !text.isEmpty {
                visible += text
                event.receivedContent = true
            }
            if let fragments = delta["tool_calls"] as? [[String: Any]] {
                mergeToolCalls(fragments)
                event.receivedToolCall = !fragments.isEmpty
            }
        }
        return event
    }

    private mutating func mergeToolCalls(_ fragments: [[String: Any]]) {
        for fragment in fragments {
            let index = (fragment["index"] as? NSNumber)?.intValue ?? toolCalls.count
            while toolCalls.count <= index {
                toolCalls.append(ChatToolCall(name: "", arguments: ""))
            }
            if let id = fragment["id"] as? String, !id.isEmpty { toolCalls[index].serverID = id }
            guard let function = fragment["function"] as? [String: Any] else { continue }
            if let name = function["name"] as? String { toolCalls[index].name += name }
            if let arguments = function["arguments"] as? String { toolCalls[index].arguments += arguments }
        }
    }
}

enum ChatStreamIdentity {
    static func value(conversationID: UUID, model: String?) -> String {
        guard let model, !model.isEmpty else { return conversationID.uuidString }
        return "\(conversationID.uuidString)::\(model)"
    }

    static func resumeURL(port: Int, identity: String, from offset: Int) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let encoded = identity.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/v1/stream/\(encoded)?from=\(offset)")
    }
}
