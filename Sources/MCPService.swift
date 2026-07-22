import Foundation

actor ToshMCPService {
    static let shared = ToshMCPService()

    private struct Session {
        var server: MCPServer
        var sessionID: String?
        var nextID = 1
        var webSocket: URLSessionWebSocketTask?
        var legacyEndpoint: URL?
    }

    private var sessions: [UUID: Session] = [:]
    private var legacyListeners: [UUID: Task<Void, Never>] = [:]
    private var legacyReady: [UUID: CheckedContinuation<URL, Error>] = [:]
    private var legacyResponses: [UUID: [Int: CheckedContinuation<WireResponse, Error>]] = [:]

    func discoverTools() async -> [BuiltinToolInfo] {
        var output: [BuiltinToolInfo] = []
        for server in MCPServerStore.load() where server.enabled {
            do {
                try await connect(server)
                let result = try await request(serverID: server.id, method: "tools/list", params: [:])
                guard let tools = result["tools"] as? [[String: Any]] else { continue }
                for tool in tools {
                    guard let remoteName = tool["name"] as? String else { continue }
                    let exposedName = Self.exposedName(server: server, tool: remoteName)
                    var function: [String: Any] = [
                        "name": exposedName,
                        "parameters": tool["inputSchema"] as? [String: Any] ?? ["type": "object"]
                    ]
                    if let description = tool["description"] as? String { function["description"] = description }
                    let definition: [String: Any] = ["type": "function", "function": function]
                    if let info = try? BuiltinToolInfo(
                        displayName: (tool["title"] as? String) ?? remoteName,
                        name: exposedName, definition: definition,
                        mcpServerID: server.id, remoteName: remoteName) {
                        output.append(info)
                    }
                }
            } catch {
                AppLog.chat.error("MCP \(server.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return output
    }

    func call(serverID: UUID, name: String, arguments: [String: Any]) async throws -> ToolExecutionResult {
        guard sessions[serverID] != nil else {
            guard let server = MCPServerStore.load().first(where: { $0.id == serverID }) else {
                throw MCPError.invalidResponse
            }
            try await connect(server)
            return try await call(serverID: serverID, name: name, arguments: arguments)
        }
        let result = try await request(serverID: serverID, method: "tools/call", params: [
            "name": name, "arguments": arguments
        ])
        let items = result["content"] as? [[String: Any]] ?? []
        let content = items.compactMap { item -> String? in
            if let text = item["text"] as? String { return text }
            if let resource = item["resource"] as? [String: Any] {
                return resource["text"] as? String ?? resource["blob"] as? String
            }
            if let data = item["data"] as? String { return data }
            return nil
        }.joined(separator: "\n")
        return ToolExecutionResult(content: content, isError: result["isError"] as? Bool ?? false)
    }

    func catalog() async -> MCPCatalog {
        var catalog = MCPCatalog()
        for server in MCPServerStore.load() where server.enabled {
            do {
                try await connect(server)
                if let result = try? await request(serverID: server.id, method: "resources/list", params: [:]),
                   let resources = result["resources"] as? [[String: Any]] {
                    catalog.resources += resources.compactMap { item in
                        guard let uri = item["uri"] as? String,
                              let name = item["name"] as? String else { return nil }
                        return MCPResourceItem(serverID: server.id, serverName: server.name,
                                               uri: uri, name: name,
                                               description: item["description"] as? String,
                                               mimeType: item["mimeType"] as? String)
                    }
                }
                if let result = try? await request(serverID: server.id,
                                                   method: "resources/templates/list", params: [:]),
                   let templates = result["resourceTemplates"] as? [[String: Any]] {
                    catalog.templates += templates.compactMap { item in
                        guard let uriTemplate = item["uriTemplate"] as? String,
                              let name = item["name"] as? String else { return nil }
                        return MCPResourceTemplateItem(
                            serverID: server.id, serverName: server.name,
                            uriTemplate: uriTemplate, name: name,
                            description: item["description"] as? String,
                            mimeType: item["mimeType"] as? String)
                    }
                }
                if let result = try? await request(serverID: server.id, method: "prompts/list", params: [:]),
                   let prompts = result["prompts"] as? [[String: Any]] {
                    catalog.prompts += prompts.compactMap { item in
                        guard let name = item["name"] as? String else { return nil }
                        let arguments = (item["arguments"] as? [[String: Any]] ?? []).compactMap { argument -> MCPPromptArgument? in
                            guard let name = argument["name"] as? String else { return nil }
                            return MCPPromptArgument(name: name,
                                                     description: argument["description"] as? String,
                                                     required: argument["required"] as? Bool ?? false)
                        }
                        return MCPPromptItem(serverID: server.id, serverName: server.name,
                                             name: name, title: item["title"] as? String,
                                             description: item["description"] as? String,
                                             arguments: arguments)
                    }
                }
            } catch {
                AppLog.chat.error("MCP catalog \(server.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return catalog
    }

    func readResource(_ resource: MCPResourceItem) async throws -> ChatAttachment {
        let result = try await request(serverID: resource.serverID, method: "resources/read",
                                       params: ["uri": resource.uri])
        let contents = result["contents"] as? [[String: Any]] ?? []
        let text = contents.compactMap { item -> String? in
            if let text = item["text"] as? String { return text }
            if let blob = item["blob"] as? String { return "[Base64]\n\(blob)" }
            return nil
        }.joined(separator: "\n\n")
        return ChatAttachment(name: resource.name, content: text,
                              mimeType: resource.mimeType, byteCount: text.utf8.count)
    }

    func readTemplate(_ template: MCPResourceTemplateItem,
                      arguments: [String: String]) async throws -> ChatAttachment {
        let uri = MCPURITemplate.expand(template.uriTemplate, values: arguments)
        return try await readResource(MCPResourceItem(
            serverID: template.serverID, serverName: template.serverName,
            uri: uri, name: template.name, description: template.description,
            mimeType: template.mimeType))
    }

    func getPrompt(_ prompt: MCPPromptItem, arguments: [String: String]) async throws -> String {
        let result = try await request(serverID: prompt.serverID, method: "prompts/get",
                                       params: ["name": prompt.name, "arguments": arguments])
        let messages = result["messages"] as? [[String: Any]] ?? []
        return messages.compactMap { message -> String? in
            let role = message["role"] as? String ?? "user"
            guard let content = message["content"] as? [String: Any] else { return nil }
            let value = content["text"] as? String ?? content["data"] as? String
            return value.map { "\(role.capitalized): \($0)" }
        }.joined(separator: "\n\n")
    }

    func disconnect(_ serverID: UUID) async {
        guard let session = sessions.removeValue(forKey: serverID) else { return }
        session.webSocket?.cancel(with: .goingAway, reason: nil)
        legacyListeners.removeValue(forKey: serverID)?.cancel()
        legacyReady.removeValue(forKey: serverID)?.resume(throwing: CancellationError())
        for continuation in legacyResponses.removeValue(forKey: serverID)?.values ?? [:].values {
            continuation.resume(throwing: CancellationError())
        }
        if session.sessionID != nil {
            _ = try? await sendHTTP(server: session.server, sessionID: session.sessionID,
                                    payload: ["jsonrpc": "2.0", "method": "notifications/cancelled",
                                              "params": ["requestId": NSNull(), "reason": "Client disconnected"]])
        }
    }

    private func connect(_ server: MCPServer) async throws {
        if sessions[server.id] != nil { return }
        var connected = server
        if connected.transport == .automatic {
            let scheme = URL(string: connected.url)?.scheme?.lowercased()
            connected.transport = scheme == "ws" || scheme == "wss" ? .webSocket : .streamableHTTP
        }
        sessions[server.id] = Session(server: connected)
        do {
            if connected.transport == .webSocket { try await startWebSocket(connected) }
            if connected.transport == .serverSentEvents { try await startLegacySSE(connected) }
            let result = try await request(serverID: server.id, method: "initialize", params: [
                "protocolVersion": "2025-06-18",
                "capabilities": ["roots": ["listChanged": false]],
                "clientInfo": ["name": "ToshLLM", "version": "1"]
            ])
            guard result["protocolVersion"] is String else { throw MCPError.invalidResponse }
            try await notify(serverID: server.id, method: "notifications/initialized", params: [:])
        } catch {
            if server.transport == .automatic && connected.transport == .streamableHTTP {
                sessions.removeValue(forKey: server.id)
                connected.transport = .serverSentEvents
                try await connect(connected)
                return
            }
            sessions.removeValue(forKey: server.id)
            throw error
        }
    }

    private func request(serverID: UUID, method: String,
                         params: [String: Any]) async throws -> [String: Any] {
        guard var session = sessions[serverID] else { throw MCPError.invalidResponse }
        let id = session.nextID
        session.nextID += 1
        sessions[serverID] = session
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id,
                                      "method": method, "params": params]
        let response: WireResponse
        switch session.server.transport {
        case .webSocket: response = try await sendWebSocket(serverID: serverID, payload: payload, id: id)
        case .serverSentEvents: response = try await sendLegacy(serverID: serverID, payload: payload, id: id)
        case .automatic, .streamableHTTP:
            response = try await sendHTTP(server: session.server, sessionID: session.sessionID,
                                          payload: payload)
        }
        if let newSession = response.sessionID {
            sessions[serverID]?.sessionID = newSession
        }
        guard let object = response.object else { throw MCPError.invalidResponse }
        if let error = object["error"] as? [String: Any] {
            throw MCPError.remote(error["message"] as? String ?? "MCP JSON-RPC error")
        }
        guard let result = object["result"] as? [String: Any] else { throw MCPError.invalidResponse }
        return result
    }

    private struct WireResponse {
        var object: [String: Any]?
        var sessionID: String?
    }

    private func notify(serverID: UUID, method: String, params: [String: Any]) async throws {
        guard let session = sessions[serverID] else { throw MCPError.invalidResponse }
        let payload: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        switch session.server.transport {
        case .webSocket:
            let data = try JSONSerialization.data(withJSONObject: payload)
            try await session.webSocket?.send(.data(data))
        case .serverSentEvents:
            try await postLegacy(serverID: serverID, payload: payload)
        case .automatic, .streamableHTTP:
            _ = try await sendHTTP(server: session.server, sessionID: session.sessionID, payload: payload)
        }
    }

    private func sendHTTP(server: MCPServer, sessionID: String?,
                          payload: [String: Any]) async throws -> WireResponse {
        guard let url = URL(string: server.url), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { throw MCPError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(max(5, server.timeoutSeconds))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        applyHeaders(server, to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let sessionHeader = http?.value(forHTTPHeaderField: "Mcp-Session-Id")
        if http?.mimeType == "text/event-stream" {
            for try await line in bytes.lines {
                guard line.hasPrefix("data:"),
                      let eventData = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any]
                else { continue }
                guard (200..<300).contains(status) else {
                    throw MCPError.remote("HTTP \(status): \(line.prefix(1_000))")
                }
                return WireResponse(object: object, sessionID: sessionHeader)
            }
            if (200..<300).contains(status) { return WireResponse(sessionID: sessionHeader) }
            throw MCPError.remote("HTTP \(status)")
        }
        var data = Data()
        for try await byte in bytes {
            if data.count < 2_000_000 { data.append(byte) }
        }
        guard (200..<300).contains(status) else {
            throw MCPError.remote("HTTP \(status): \(String(decoding: data.prefix(1_000), as: UTF8.self))")
        }
        if data.isEmpty { return WireResponse(sessionID: sessionHeader) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError.invalidResponse
        }
        return WireResponse(object: object, sessionID: sessionHeader)
    }

    private func startWebSocket(_ server: MCPServer) async throws {
        guard let url = URL(string: server.url) else { throw MCPError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(max(5, server.timeoutSeconds))
        request.setValue("mcp", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        applyHeaders(server, to: &request)
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        sessions[server.id]?.webSocket = socket
    }

    private func sendWebSocket(serverID: UUID, payload: [String: Any], id: Int) async throws -> WireResponse {
        guard let socket = sessions[serverID]?.webSocket else { throw MCPError.invalidResponse }
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await socket.send(.data(data))
        while true {
            let message = try await socket.receive()
            let value: Data
            switch message {
            case let .data(data): value = data
            case let .string(text): value = Data(text.utf8)
            @unknown default: continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: value) as? [String: Any]
            else { continue }
            if (object["id"] as? NSNumber)?.intValue == id { return WireResponse(object: object) }
        }
    }

    private func startLegacySSE(_ server: MCPServer) async throws {
        _ = try await withCheckedThrowingContinuation { continuation in
            legacyReady[server.id] = continuation
            legacyListeners[server.id] = Task { [weak self] in
                await self?.listenLegacySSE(server)
            }
        }
    }

    private func listenLegacySSE(_ server: MCPServer) async {
        do {
            guard let url = URL(string: server.url) else { throw MCPError.invalidURL }
            var request = URLRequest(url: url)
            request.timeoutInterval = 3_600
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            applyHeaders(server, to: &request)
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw MCPError.remote("Legacy MCP SSE connection failed")
            }
            var event = "message"
            var dataLines: [String] = []
            for try await line in bytes.lines {
                if Task.isCancelled { throw CancellationError() }
                if line.hasPrefix("event:") {
                    event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    dataLines.append(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
                } else if line.isEmpty, !dataLines.isEmpty {
                    let data = dataLines.joined(separator: "\n")
                    dataLines.removeAll(keepingCapacity: true)
                    if event == "endpoint", let endpoint = URL(string: data, relativeTo: url)?.absoluteURL,
                       endpoint.host == url.host {
                        sessions[server.id]?.legacyEndpoint = endpoint
                        legacyReady.removeValue(forKey: server.id)?.resume(returning: endpoint)
                    } else if let bytes = data.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                              let id = (object["id"] as? NSNumber)?.intValue,
                              let continuation = legacyResponses[server.id]?.removeValue(forKey: id) {
                        continuation.resume(returning: WireResponse(object: object))
                    }
                    event = "message"
                }
            }
            throw MCPError.remote("Legacy MCP SSE stream closed")
        } catch {
            legacyReady.removeValue(forKey: server.id)?.resume(throwing: error)
            for continuation in legacyResponses.removeValue(forKey: server.id)?.values ?? [:].values {
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendLegacy(serverID: UUID, payload: [String: Any], id: Int) async throws -> WireResponse {
        try await withCheckedThrowingContinuation { continuation in
            legacyResponses[serverID, default: [:]][id] = continuation
            Task { [weak self] in
                do { try await self?.postLegacy(serverID: serverID, payload: payload) }
                catch { await self?.failLegacyResponse(serverID: serverID, id: id, error: error) }
            }
        }
    }

    private func postLegacy(serverID: UUID, payload: [String: Any]) async throws {
        guard let session = sessions[serverID], let endpoint = session.legacyEndpoint else {
            throw MCPError.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(session.server, to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw MCPError.remote("HTTP \(status)") }
    }

    private func failLegacyResponse(serverID: UUID, id: Int, error: Error) {
        legacyResponses[serverID]?.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func applyHeaders(_ server: MCPServer, to request: inout URLRequest) {
        guard let raw = Keychain.get(server.credentialAccount),
              let data = raw.data(using: .utf8),
              let headers = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    }

    private static func exposedName(server: MCPServer, tool: String) -> String {
        func safe(_ value: String) -> String {
            String(value.lowercased().map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        }
        return String("mcp_\(safe(server.name))_\(safe(tool))".prefix(64))
    }
}
