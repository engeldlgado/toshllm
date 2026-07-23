import SwiftUI

struct ToolCallCard: View {
    let call: ChatToolCall
    @EnvironmentObject private var loc: Localizer
    @State private var expanded = false

    private var presentation: ToolCallPresentation { .make(call) }

    private var icon: String {
        switch call.state {
        case .running: return "gearshape.2.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed, .denied: return "xmark.octagon.fill"
        case .pending, .awaitingPermission: return "hand.raised.fill"
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ToolCallDetailView(call: call, presentation: presentation)
                .padding(.top, 8)
        } label: {
            HStack(spacing: 7) {
                Label(presentation.title, systemImage: icon)
                    .lineLimit(1)
                if let path = presentation.path {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if call.state == .running { ProgressView().controlSize(.mini) }
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(call.state == .failed || call.state == .denied ? .red : .secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel(loc.t("Llamada a herramienta \(call.name)", "Tool call \(call.name)"))
    }
}

private struct ToolCallDetailView: View {
    let call: ChatToolCall
    let presentation: ToolCallPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let path = presentation.path {
                Label(path, systemImage: "doc")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let detail = presentation.detail {
                Text(detail).font(.caption2).foregroundStyle(.tertiary)
            }

            switch presentation.kind {
            case .read:
                resultCode(language: presentation.language, waiting: "Waiting for file content…")
            case .write:
                codePanel(presentation.code ?? "", language: presentation.language)
                resultText()
            case .edit:
                if presentation.edits.isEmpty {
                    emptyState("No edits")
                } else {
                    ForEach(Array(presentation.edits.enumerated()), id: \.element.id) { index, edit in
                        Text("Edit \(index + 1) of \(presentation.edits.count)")
                            .font(.caption2).foregroundStyle(.tertiary)
                        DiffPanel(edit: edit)
                    }
                    resultText()
                }
            case .shell:
                codePanel(presentation.code ?? "", language: "bash")
                consolePanel(title: "Terminal")
            case .grep, .glob:
                if let code = presentation.code, !code.isEmpty {
                    Label(code, systemImage: presentation.kind == .grep ? "text.magnifyingglass" : "doc.text.magnifyingglass")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                consolePanel(title: "Matches")
            case .javaScript:
                codePanel(presentation.code ?? "", language: "javascript")
                consolePanel(title: "Console")
            case .dateTime:
                if let result = presentation.result, !result.isEmpty {
                    Label(result, systemImage: "calendar.badge.clock")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                } else { emptyState("Waiting…") }
            case .search:
                SearchResultPanel(result: presentation.result)
            case .generic:
                codePanel(call.arguments.isEmpty ? "{}" : call.arguments, language: "json")
                resultText()
            }
        }
    }

    @ViewBuilder
    private func codePanel(_ source: String, language: String) -> some View {
        if !source.isEmpty {
            ScrollView([.horizontal, .vertical]) {
                SyntaxHighlightedCode(source: source, language: language)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 280)
            .background(Color(nsColor: OneDarkPro.background), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func resultCode(language: String, waiting: String) -> some View {
        if let result = presentation.result, !result.isEmpty {
            codePanel(result, language: language)
        } else { emptyState(waiting) }
    }

    @ViewBuilder
    private func resultText() -> some View {
        if let result = presentation.result, !result.isEmpty {
            Divider()
            Text(result).font(.caption).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func consolePanel(title: String) -> some View {
        Label(title, systemImage: "terminal")
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        if let result = presentation.result, !result.isEmpty {
            ScrollView([.horizontal, .vertical]) {
                Text(result)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 300)
            .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
        } else { emptyState(call.state == .running ? "Running…" : "No output") }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text).font(.caption.italic()).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct DiffPanel: View {
    let edit: ToolCallPresentation.Edit

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(edit.oldText.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    diffLine("−", String(line), color: .red)
                }
                ForEach(Array(edit.newText.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    diffLine("+", String(line), color: .green)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 280)
        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
    }

    private func diffLine(_ marker: String, _ text: String, color: Color) -> some View {
        Text("\(marker) \(text.isEmpty ? " " : text)")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.09))
            .textSelection(.enabled)
    }
}

private struct SearchResultPanel: View {
    let result: String?

    private struct Hit: Identifiable {
        let id = UUID()
        let title: String
        let url: URL
        let snippet: String
    }

    /// Search tools return a `{answer, results:[{url,title,content}]}` JSON;
    /// parse it into a clean list, else fall back to plain URL chips.
    private var parsed: (answer: String?, hits: [Hit])? {
        guard let result, let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["results"] as? [[String: Any]] else { return nil }
        let hits = rows.compactMap { row -> Hit? in
            guard let link = row["url"] as? String, let url = URL(string: link) else { return nil }
            return Hit(title: (row["title"] as? String) ?? url.host ?? link, url: url,
                       snippet: (row["content"] as? String) ?? "")
        }
        return hits.isEmpty ? nil : (object["answer"] as? String, hits)
    }

    private var links: [(String, URL)] {
        guard let result else { return [] }
        let pattern = #"https?://[^\s\]\[\)\}\>,\"]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(result.startIndex..., in: result)
        var seen = Set<URL>()
        return regex.matches(in: result, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: result),
                  let url = URL(string: String(result[swiftRange])),
                  seen.insert(url).inserted else { return nil }
            return (url.host ?? url.absoluteString, url)
        }
    }

    var body: some View {
        if let parsed {
            VStack(alignment: .leading, spacing: 8) {
                if let answer = parsed.answer, !answer.isEmpty {
                    Text(answer).font(.caption).textSelection(.enabled)
                }
                ForEach(parsed.hits) { hit in
                    VStack(alignment: .leading, spacing: 2) {
                        Link(destination: hit.url) {
                            Label(hit.title, systemImage: "globe").font(.caption.weight(.medium)).lineLimit(2)
                        }
                        Text(hit.url.host ?? hit.url.absoluteString)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        if !hit.snippet.isEmpty {
                            Text(hit.snippet).font(.caption2).foregroundStyle(.tertiary).lineLimit(3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        } else if links.isEmpty {
            Text(result ?? "No results")
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(Array(links.enumerated()), id: \.offset) { _, item in
                    Link(destination: item.1) {
                        Label(item.0, systemImage: "globe")
                            .font(.caption).lineLimit(1).padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            if let result { Text(result).font(.caption).textSelection(.enabled) }
        }
    }
}

struct ToolResultCard: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message.toolCallID ?? "Tool", systemImage: "terminal")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(message.content).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
