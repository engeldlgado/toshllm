import Foundation

struct ToolCallPresentation: Equatable {
    enum Kind: Equatable {
        case read, write, edit, shell, grep, glob, javaScript, dateTime, search, generic
    }

    struct Edit: Equatable, Identifiable {
        let id = UUID()
        let oldText: String
        let newText: String

        static func == (lhs: Edit, rhs: Edit) -> Bool {
            lhs.oldText == rhs.oldText && lhs.newText == rhs.newText
        }
    }

    let kind: Kind
    let title: String
    let path: String?
    let code: String?
    let language: String
    let detail: String?
    let edits: [Edit]
    let result: String?

    static func make(_ call: ChatToolCall) -> ToolCallPresentation {
        let args = arguments(call.arguments)
        let path = string(args, keys: ["path", "file_path", "filePath"])
        let result = call.result
        switch call.name {
        case "read_file":
            var detail: String?
            if let start = number(args, keys: ["start_line", "line_start", "startLine", "from_line"]) {
                if let end = number(args, keys: ["end_line", "line_end", "endLine", "to_line"]) {
                    detail = "lines \(start)–\(end)"
                } else if let count = number(args, keys: ["line_count", "count", "num_lines"]) {
                    detail = "lines \(start)–\(start + count - 1)"
                }
            }
            return ToolCallPresentation(kind: .read, title: "Read file", path: path,
                                        code: nil, language: language(for: path), detail: detail,
                                        edits: [], result: result)
        case "write_file":
            return ToolCallPresentation(kind: .write, title: "Write file", path: path,
                                        code: args["content"] as? String,
                                        language: language(for: path), detail: nil,
                                        edits: [], result: result)
        case "edit_file":
            let edits = (args["edits"] as? [[String: Any]] ?? []).compactMap { edit -> Edit? in
                guard let old = edit["old_text"] as? String, !old.isEmpty else { return nil }
                return Edit(oldText: old, newText: edit["new_text"] as? String ?? "")
            }
            return ToolCallPresentation(kind: .edit, title: "Edit file", path: path,
                                        code: nil, language: language(for: path), detail: nil,
                                        edits: edits, result: result)
        case "exec_shell_command":
            let command = string(args, keys: ["command", "cmd", "shell_command"])
            return ToolCallPresentation(kind: .shell, title: command ?? "Shell command", path: nil,
                                        code: command, language: "bash", detail: nil,
                                        edits: [], result: result)
        case "grep_search":
            let pattern = args["pattern"] as? String
            return ToolCallPresentation(kind: .grep, title: "Search text", path: path,
                                        code: pattern, language: "text",
                                        detail: args["include"] as? String, edits: [], result: result)
        case "file_glob_search":
            let include = args["include"] as? String ?? "**"
            return ToolCallPresentation(kind: .glob,
                                        title: include == "**" ? "List files" : "Search files",
                                        path: path, code: include, language: "text",
                                        detail: args["exclude"] as? String, edits: [], result: result)
        case JavaScriptSandboxService.toolName:
            let timeout = (args["timeout_ms"] as? NSNumber)?.intValue
            return ToolCallPresentation(kind: .javaScript, title: "JavaScript sandbox", path: nil,
                                        code: args["code"] as? String, language: "javascript",
                                        detail: timeout.map { "timeout \($0) ms" }, edits: [], result: result)
        case "get_datetime":
            return ToolCallPresentation(kind: .dateTime, title: "Date and time", path: nil,
                                        code: nil, language: "text", detail: nil,
                                        edits: [], result: result)
        default:
            if call.name.localizedCaseInsensitiveContains("search") {
                let query = string(args, keys: ["query", "q", "search_query"])
                return ToolCallPresentation(kind: .search,
                                            title: query.map { "Search: \($0)" } ?? call.name,
                                            path: nil, code: query, language: "text", detail: nil,
                                            edits: [], result: result)
            }
            return ToolCallPresentation(kind: .generic, title: call.name, path: nil,
                                        code: call.arguments, language: "json", detail: nil,
                                        edits: [], result: result)
        }
    }

    private static func arguments(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func string(_ args: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = args[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func number(_ args: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = args[key] as? NSNumber { return value.intValue }
        }
        return nil
    }

    private static func language(for path: String?) -> String {
        switch URL(fileURLWithPath: path ?? "").pathExtension.lowercased() {
        case "swift": return "swift"
        case "js", "mjs", "cjs": return "javascript"
        case "ts", "tsx": return "typescript"
        case "py": return "python"
        case "sh", "zsh", "bash": return "bash"
        case "json", "jsonl": return "json"
        case "c", "h": return "c"
        case "cc", "cpp", "cxx", "hpp": return "cpp"
        case "md", "markdown": return "markdown"
        case "html", "htm": return "html"
        case "css": return "css"
        default: return "text"
        }
    }
}
