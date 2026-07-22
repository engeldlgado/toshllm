import Foundation

enum MCPTransport: String, Codable, CaseIterable, Identifiable {
    case automatic
    case streamableHTTP
    case serverSentEvents
    case webSocket

    var id: String { rawValue }
}

struct MCPServer: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var enabled = true
    var transport = MCPTransport.automatic
    var timeoutSeconds = 60

    var credentialAccount: String { "mcp-headers-\(id.uuidString)" }
}

enum MCPServerStore {
    static func load() -> [MCPServer] {
        guard let data = UserDefaults.standard.data(forKey: SettingsKeys.mcpServers),
              let servers = try? JSONDecoder().decode([MCPServer].self, from: data) else { return [] }
        return servers
    }

    static func save(_ servers: [MCPServer]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(servers), forKey: SettingsKeys.mcpServers)
    }

    static func deleteCredentials(for server: MCPServer) {
        Keychain.delete(server.credentialAccount)
    }
}

enum MCPError: LocalizedError {
    case invalidURL
    case invalidResponse
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid MCP server URL."
        case .invalidResponse: return "The MCP server returned an invalid JSON-RPC response."
        case let .remote(message): return message
        }
    }
}

struct MCPResourceItem: Identifiable, Sendable {
    let serverID: UUID
    let serverName: String
    let uri: String
    let name: String
    let description: String?
    let mimeType: String?
    var id: String { "\(serverID.uuidString)::\(uri)" }
}

struct MCPPromptArgument: Sendable, Identifiable {
    let name: String
    let description: String?
    let required: Bool
    var id: String { name }
}

struct MCPPromptItem: Identifiable, Sendable {
    let serverID: UUID
    let serverName: String
    let name: String
    let title: String?
    let description: String?
    let arguments: [MCPPromptArgument]
    var id: String { "\(serverID.uuidString)::\(name)" }
}

struct MCPResourceTemplateItem: Identifiable, Sendable {
    let serverID: UUID
    let serverName: String
    let uriTemplate: String
    let name: String
    let description: String?
    let mimeType: String?
    var variables: [String] { MCPURITemplate.variables(in: uriTemplate) }
    var id: String { "\(serverID.uuidString)::template::\(uriTemplate)" }
}

enum MCPURITemplate {
    static func variables(in template: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\{([^}]+)\}"#) else { return [] }
        let range = NSRange(template.startIndex..., in: template)
        var seen = Set<String>()
        return regex.matches(in: template, range: range).flatMap { match -> [String] in
            guard let valueRange = Range(match.range(at: 1), in: template) else { return [] }
            return template[valueRange].drop(while: { "+#./;?&".contains($0) })
                .split(separator: ",")
                .map { String($0.split(separator: ":").first ?? $0).replacingOccurrences(of: "*", with: "") }
        }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func expand(_ template: String, values: [String: String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{([^}]+)\}"#) else { return template }
        var output = template
        for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            guard let whole = Range(match.range(at: 0), in: template),
                  let expressionRange = Range(match.range(at: 1), in: template) else { continue }
            let expression = String(template[expressionRange])
            let operation = expression.first.map(String.init) ?? ""
            let hasOperator = "+#./;?&".contains(operation)
            let names = (hasOperator ? String(expression.dropFirst()) : expression)
                .split(separator: ",").map(String.init)
            let replacement: String
            if operation == "?" || operation == "&" {
                let pairs = names.compactMap { name -> String? in
                    guard let value = values[name], !value.isEmpty else { return nil }
                    return "\(encode(name))=\(encode(value))"
                }
                replacement = pairs.isEmpty ? "" : (operation == "?" ? "?" : "&") + pairs.joined(separator: "&")
            } else {
                let separator = operation == "/" ? "/" : operation == "." ? "." : ","
                let prefix = operation == "/" || operation == "." ? operation : operation == "#" ? "#" : ""
                let expanded = names.compactMap { name in values[name] }.map {
                    operation == "+" || operation == "#" ? reservedEncode($0) : encode($0)
                }
                replacement = expanded.isEmpty ? "" : prefix + expanded.joined(separator: separator)
            }
            output.replaceSubrange(whole, with: replacement)
        }
        return output
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
    }

    private static func reservedEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? value
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+?#/")
        return set
    }()
}

struct MCPCatalog: Sendable {
    var resources: [MCPResourceItem] = []
    var templates: [MCPResourceTemplateItem] = []
    var prompts: [MCPPromptItem] = []
}
