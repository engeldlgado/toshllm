import Foundation

struct BuiltinToolInfo: Identifiable, Sendable {
    let displayName: String
    let name: String
    let writesData: Bool
    let definitionData: Data
    let mcpServerID: UUID?
    let remoteName: String?

    var id: String { name }

    var openAIDefinition: [String: Any]? {
        try? JSONSerialization.jsonObject(with: definitionData) as? [String: Any]
    }

    init?(json: [String: Any]) {
        guard let displayName = json["display_name"] as? String,
              let name = json["tool"] as? String,
              let permissions = json["permissions"] as? [String: Any],
              let writesData = permissions["write"] as? Bool,
              let definition = json["definition"] as? [String: Any],
              JSONSerialization.isValidJSONObject(definition),
              let definitionData = try? JSONSerialization.data(withJSONObject: definition)
        else { return nil }
        self.displayName = displayName
        self.name = name
        self.writesData = writesData
        self.definitionData = definitionData
        mcpServerID = nil
        remoteName = nil
    }

    init(displayName: String, name: String, definition: [String: Any],
         mcpServerID: UUID, remoteName: String) throws {
        self.displayName = displayName
        self.name = name
        writesData = true
        definitionData = try JSONSerialization.data(withJSONObject: definition)
        self.mcpServerID = mcpServerID
        self.remoteName = remoteName
    }

    init(displayName: String, name: String, writesData: Bool,
         definition: [String: Any]) throws {
        self.displayName = displayName
        self.name = name
        self.writesData = writesData
        definitionData = try JSONSerialization.data(withJSONObject: definition)
        mcpServerID = nil
        remoteName = nil
    }
}

struct ToolExecutionResult: Sendable, Equatable {
    let content: String
    let isError: Bool
}

enum ChatToolsError: LocalizedError {
    case invalidResponse
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "llama.cpp returned an invalid tools response."
        case let .server(status, message):
            return "HTTP \(status): \(message)"
        }
    }
}

enum ChatToolsService {
    static let builtInNames = [
        "read_file", "edit_file", "write_file", "get_datetime",
        "file_glob_search", "grep_search", "exec_shell_command", "run_javascript"
    ]

    static func isAlwaysAllowed(_ name: String) -> Bool {
        UserDefaults.standard.bool(forKey: permissionKey(name))
    }

    static func allowAlways(_ name: String) {
        UserDefaults.standard.set(true, forKey: permissionKey(name))
    }

    static func revokeAllPermissions() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("toolPermission.always.") {
            defaults.removeObject(forKey: key)
        }
    }

    static func list(port: Int) async throws -> [BuiltinToolInfo] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/tools")!)
        authorize(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ChatToolsError.invalidResponse
        }
        return rows.compactMap(BuiltinToolInfo.init(json:))
    }

    static func execute(name: String, arguments: [String: Any], port: Int) async throws -> ToolExecutionResult {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/tools")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["tool": name, "params": arguments])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatToolsError.invalidResponse
        }
        if let error = object["error"] { return ToolExecutionResult(content: String(describing: error), isError: true) }
        if let text = object["plain_text_response"] { return ToolExecutionResult(content: String(describing: text), isError: false) }
        let normalized = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return ToolExecutionResult(content: String(decoding: normalized, as: UTF8.self), isError: false)
    }

    static func executeStreaming(name: String, arguments: [String: Any], port: Int,
                                 onUpdate: @escaping (String) async -> Void) async throws -> ToolExecutionResult {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/tools")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "tool": name, "params": arguments, "stream": true
        ])
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var detail = ""
            for try await line in bytes.lines {
                detail += line
                if detail.count > 1_000 { break }
            }
            throw ChatToolsError.server(status: status, message: detail)
        }
        var output = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: "),
                  let data = String(line.dropFirst(6)).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let chunk = event["chunk"] as? String {
                output += chunk
                await onUpdate(output)
            }
            if (event["done"] as? Bool) == true {
                if let error = event["error"] as? String, !error.isEmpty {
                    if !output.isEmpty { output += "\n" }
                    output += "Error: \(error)"
                    await onUpdate(output)
                    return ToolExecutionResult(content: output, isError: true)
                }
                return ToolExecutionResult(content: output, isError: false)
            }
        }
        throw ChatToolsError.invalidResponse
    }

    static func parseArguments(_ source: String) throws -> [String: Any] {
        guard let data = source.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatToolsError.invalidResponse
        }
        return value
    }

    private static func authorize(_ request: inout URLRequest) {
        if let key = ServerSettings.activeAPIKey() {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
    }

    private static func permissionKey(_ name: String) -> String {
        "toolPermission.always.builtin.\(name)"
    }

    private static func validate(response: URLResponse, data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message: String
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = object["error"] ?? object["message"] {
                message = String(describing: detail)
            } else {
                message = String(decoding: data.prefix(1_000), as: UTF8.self)
            }
            throw ChatToolsError.server(status: status, message: message)
        }
    }
}
