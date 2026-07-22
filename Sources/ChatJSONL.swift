import Foundation

enum ChatJSONL {
    static func encode(_ conversations: [Conversation]) throws -> Data {
        var lines: [String] = []
        for conversation in conversations {
            lines += try records(for: conversation).map { record in
                let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                return String(decoding: data, as: UTF8.self)
            }
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    static func decode(_ data: Data) throws -> [Conversation] {
        guard let text = String(data: data, encoding: .utf8) else { throw ChatArchiveError.unsupported }
        var sessions: [(header: [String: Any], messages: [[String: Any]])] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            guard let lineData = String(raw).data(using: .utf8),
                  let record = try JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = record["type"] as? String else { throw ChatArchiveError.unsupported }
            if type == "session" {
                sessions.append((record, []))
            } else if type == "message", let message = record["message"] as? [String: Any], !sessions.isEmpty {
                sessions[sessions.count - 1].messages.append(message)
            }
        }
        guard !sessions.isEmpty else { throw ChatArchiveError.unsupported }
        return sessions.map(makeConversation)
    }

    private static func records(for conversation: Conversation) throws -> [[String: Any]] {
        var paths = conversation.branches?.map(\.messages) ?? []
        if !paths.contains(conversation.messages) { paths.append(conversation.messages) }
        if paths.isEmpty { paths = [conversation.messages] }

        let rootID = UUID().uuidString
        var messagesByID: [UUID: ChatMessage] = [:]
        var parentByID: [UUID: String] = [:]
        var childrenByID: [String: Set<String>] = [rootID: []]
        for path in paths {
            var parent = rootID
            for message in path {
                messagesByID[message.id] = message
                if parentByID[message.id] == nil { parentByID[message.id] = parent }
                childrenByID[parent, default: []].insert(message.id.uuidString)
                childrenByID[message.id.uuidString, default: []] = childrenByID[message.id.uuidString, default: []]
                parent = message.id.uuidString
            }
        }

        var header: [String: Any] = [
            "type": "session", "harness": "llama.app", "id": conversation.id.uuidString,
            "name": conversation.title, "lastModified": conversation.updated.timeIntervalSince1970 * 1000,
            "currNode": conversation.messages.last?.id.uuidString ?? rootID,
            "pinned": conversation.pinned ?? false,
            "toshCreated": conversation.created.timeIntervalSince1970 * 1000,
        ]
        if let value = conversation.systemPrompt { header["toshSystemPrompt"] = value }
        if let value = conversation.summary { header["toshSummary"] = value }
        if let value = conversation.summarizedCount { header["toshSummarizedCount"] = value }
        if let value = conversation.enabledToolNames { header["toshEnabledToolNames"] = value }

        let root: [String: Any] = [
            "id": rootID, "convId": conversation.id.uuidString, "type": "root",
            "timestamp": conversation.created.timeIntervalSince1970 * 1000,
            "role": "system", "content": "", "parent": NSNull(),
            "children": Array(childrenByID[rootID] ?? []).sorted(),
        ]
        var records: [[String: Any]] = [header, ["type": "message", "message": root]]
        let ordered = messagesByID.values.sorted { $0.date < $1.date }
        for message in ordered {
            var value: [String: Any] = [
                "id": message.id.uuidString, "convId": conversation.id.uuidString, "type": "text",
                "timestamp": message.date.timeIntervalSince1970 * 1000, "role": message.role,
                "content": message.parts.body, "parent": parentByID[message.id] ?? rootID,
                "children": Array(childrenByID[message.id.uuidString] ?? []).sorted(),
            ]
            if let thinking = message.parts.thinking { value["reasoningContent"] = thinking }
            if let model = message.model { value["model"] = model }
            if let callID = message.toolCallID { value["toolCallId"] = callID }
            if let calls = message.toolCalls, !calls.isEmpty {
                value["toolCalls"] = calls.map { call in
                    ["id": call.serverID ?? call.id.uuidString, "type": "function",
                     "function": ["name": call.name, "arguments": call.arguments]]
                }
            }
            let extras = extras(for: message)
            if !extras.isEmpty { value["extra"] = extras }
            records.append(["type": "message", "message": value])
        }
        return records
    }

    private static func extras(for message: ChatMessage) -> [[String: Any]] {
        var values: [[String: Any]] = (message.imageURIs ?? []).enumerated().map { index, uri in
            ["type": "IMAGE", "name": "image-\(index + 1).jpg", "base64Url": uri]
        }
        for attachment in message.attachments ?? [] {
            if let kind = attachment.mediaKind, let payload = attachment.base64Payload {
                values.append(["type": kind == "audio" ? "AUDIO" : "VIDEO",
                               "name": attachment.name, "size": attachment.byteCount ?? 0,
                               "base64Data": payload, "mimeType": attachment.mimeType ?? "application/octet-stream"])
            } else {
                values.append(["type": "TEXT", "name": attachment.name,
                               "size": attachment.byteCount ?? attachment.content.utf8.count,
                               "content": attachment.content])
            }
        }
        return values
    }

    private static func makeConversation(_ session: (header: [String: Any], messages: [[String: Any]])) -> Conversation {
        let header = session.header
        let records = session.messages.filter { ($0["type"] as? String) != "root" }
        var idMap: [String: UUID] = [:]
        for record in records {
            if let id = record["id"] as? String { idMap[id] = UUID(uuidString: id) ?? UUID() }
        }
        let byID = Dictionary(uniqueKeysWithValues: records.compactMap { record -> (String, [String: Any])? in
            guard let id = record["id"] as? String else { return nil }
            return (id, record)
        })
        let parentIDs = Set(records.compactMap { $0["parent"] as? String })
        var leaves = records.compactMap { $0["id"] as? String }.filter { !parentIDs.contains($0) }
        if let current = header["currNode"] as? String, byID[current] != nil, !leaves.contains(current) {
            leaves.append(current)
        }

        func path(to leaf: String) -> [ChatMessage] {
            var chain: [[String: Any]] = []
            var cursor: String? = leaf
            var visited = Set<String>()
            while let id = cursor, let record = byID[id], visited.insert(id).inserted {
                chain.append(record)
                cursor = record["parent"] as? String
            }
            return chain.reversed().map { message(from: $0, id: idMap[$0["id"] as? String ?? ""] ?? UUID()) }
        }

        let currentID = header["currNode"] as? String
        let currentMessages = currentID.flatMap { byID[$0] == nil ? nil : path(to: $0) }
            ?? leaves.first.map(path) ?? []
        let allPaths = leaves.map(path).filter { !$0.isEmpty }
        let createdMS = header["toshCreated"] as? Double
        let modifiedMS = header["lastModified"] as? Double
        var conversation = Conversation(
            id: UUID(uuidString: header["id"] as? String ?? "") ?? UUID(),
            title: header["name"] as? String ?? "Imported conversation",
            messages: currentMessages,
            created: createdMS.map { Date(timeIntervalSince1970: $0 / 1000) } ?? currentMessages.first?.date ?? .now,
            updated: modifiedMS.map { Date(timeIntervalSince1970: $0 / 1000) } ?? currentMessages.last?.date ?? .now,
            summary: header["toshSummary"] as? String,
            summarizedCount: header["toshSummarizedCount"] as? Int,
            pinned: header["pinned"] as? Bool,
            systemPrompt: header["toshSystemPrompt"] as? String,
            enabledToolNames: header["toshEnabledToolNames"] as? [String])
        if allPaths.count > 1 {
            let branches = allPaths.enumerated().map { ChatBranch(name: "Branch \($0.offset + 1)", messages: $0.element) }
            conversation.branches = branches
            conversation.activeBranchID = zip(branches, allPaths).first(where: { $0.1 == currentMessages })?.0.id
        }
        return conversation
    }

    private static func message(from record: [String: Any], id: UUID) -> ChatMessage {
        let body = record["content"] as? String ?? ""
        let reasoning = record["reasoningContent"] as? String
        let content = reasoning.map { "<think>\($0)</think>\(body)" } ?? body
        let timestamp = record["timestamp"] as? Double ?? Date().timeIntervalSince1970 * 1000
        var attachments: [ChatAttachment] = []
        var images: [String] = []
        for extra in record["extra"] as? [[String: Any]] ?? [] {
            let type = extra["type"] as? String ?? ""
            if type == "IMAGE", let uri = extra["base64Url"] as? String {
                images.append(uri)
            } else if type == "AUDIO" || type == "VIDEO", let payload = extra["base64Data"] as? String {
                let mime = extra["mimeType"] as? String ?? (type == "AUDIO" ? "audio/mpeg" : "video/mp4")
                attachments.append(ChatAttachment(name: extra["name"] as? String ?? type.lowercased(),
                                                  content: "", mimeType: mime,
                                                  dataURI: "data:\(mime);base64,\(payload)",
                                                  byteCount: extra["size"] as? Int))
            } else if let text = extra["content"] as? String {
                attachments.append(ChatAttachment(name: extra["name"] as? String ?? "attachment.txt",
                                                  content: text, byteCount: extra["size"] as? Int))
            }
        }
        var toolCalls: [ChatToolCall] = []
        for raw in record["toolCalls"] as? [[String: Any]] ?? [] {
            let function = raw["function"] as? [String: Any]
            toolCalls.append(ChatToolCall(serverID: raw["id"] as? String,
                                          name: function?["name"] as? String ?? "",
                                          arguments: function?["arguments"] as? String ?? "{}"))
        }
        return ChatMessage(id: id, role: record["role"] as? String ?? "user", content: content,
                           date: Date(timeIntervalSince1970: timestamp / 1000),
                           model: record["model"] as? String,
                           toolCalls: toolCalls.isEmpty ? nil : toolCalls,
                           toolCallID: record["toolCallId"] as? String,
                           attachments: attachments.isEmpty ? nil : attachments,
                           imageURIs: images.isEmpty ? nil : images)
    }
}
