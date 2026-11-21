// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct ToolCallCard: View {
    let call: ChatToolCall
    @EnvironmentObject private var loc: Localizer
    @State private var expanded = false

    private var presentation: ToolCallPresentation { .make(call) }

    private var icon: String {
        switch call.state {
        case .running: return "gearshape.2.fill"
        case .completed where call.accepted == true: return "clock.badge.checkmark"
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
            VStack(alignment: .leading, spacing: 3) {
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
                    if call.accepted == true {
                        Text(loc.t("aceptada, sin confirmar", "accepted, not confirmed"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help(loc.t("El servicio aceptó la operación pero no ha dicho que terminara.",
                                        "The service accepted the operation but has not said it finished."))
                    }
                }
                .font(.callout.weight(.medium))
                if let summary = call.summary {
                    Text(summary)
                        .font(.caption)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .padding(.leading, 22)
                }
            }
            .foregroundStyle(call.state == .failed || call.state == .denied ? .red : .secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel(loc.t("Llamada a herramienta %@", "Tool call %@", "\(call.name)"))
    }
}

private struct ToolCallDetailView: View {
    @EnvironmentObject private var loc: Localizer
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
            case .map:
                if let code = presentation.code, !code.isEmpty {
                    Label(code, systemImage: "map").font(.callout).textSelection(.enabled)
                }
                if let result = presentation.result, !result.isEmpty {
                    Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                } else { emptyState(loc.t("Dibujando…", "Drawing…")) }
            case .dateTime:
                if let result = presentation.result, !result.isEmpty {
                    Label(result, systemImage: "calendar.badge.clock")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                } else { emptyState("Waiting…") }
            case .math:
                codePanel(presentation.code ?? "", language: presentation.language)
                if let result = presentation.result, !result.isEmpty {
                    Label(result, systemImage: "function")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                } else { emptyState(call.state == .running ? "Calculating…" : "No result") }
            case .search:
                SearchResultPanel(result: presentation.result)
            case .generic:
                codePanel(presentation.code.flatMap { $0.isEmpty ? nil : $0 } ?? "{}", language: "json")
                if let result = presentation.result, ToolCallPresentation.indented(result) != nil {
                    Divider()
                    codePanel(result, language: "json")
                } else {
                    resultText()
                }
            }
        }
    }

    @ViewBuilder
    private func codePanel(_ source: String, language: String) -> some View {
        if !source.isEmpty {
            SyntaxHighlightedCode(source: source, language: language)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
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
            Text(result)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
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
    // split once at init: body re-runs on every streamed token, and splitting both
    // sides of every open diff there was the cost
    private let oldLines: [String]
    private let newLines: [String]

    init(edit: ToolCallPresentation.Edit) {
        oldLines = edit.oldText.components(separatedBy: "\n")
        newLines = edit.newText.components(separatedBy: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(oldLines.enumerated()), id: \.offset) { _, line in
                diffLine("−", line, color: .red)
            }
            ForEach(Array(newLines.enumerated()), id: \.offset) { _, line in
                diffLine("+", line, color: .green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// One row of the transcript: a message, or consecutive tool rounds with their results.
enum TranscriptRow: Identifiable {
    case message(ChatMessage)
    case tools([ChatMessage])

    enum ID: Hashable {
        case message(UUID)
        case tools(UUID)
    }

    /// A streaming message that ends in tool calls becomes a block; with the same identity SwiftUI
    /// keeps its live bubble, which then mirrors the next pass.
    var id: ID {
        switch self {
        case .message(let message): return .message(message.id)
        case .tools(let rounds): return .tools(rounds[0].id)
        }
    }

    static func rows(_ messages: [ChatMessage]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var run: [ChatMessage] = []
        for message in messages {
            let round = message.role == "assistant" && !(message.toolCalls ?? []).isEmpty
            if round || (message.role == "tool" && !run.isEmpty) {
                run.append(message)
                continue
            }
            if !run.isEmpty { rows.append(.tools(run)) }
            run = []
            rows.append(.message(message))
        }
        if !run.isEmpty { rows.append(.tools(run)) }
        return rows
    }
}

/// Consecutive tool rounds of a turn as one block. Each call card carries its own result, so the
/// result messages are not drawn again; the answer that follows stays a message of its own.
struct ToolRoundsGroup: View, Equatable {
    let rounds: [ChatMessage]

    static func == (a: ToolRoundsGroup, b: ToolRoundsGroup) -> Bool { a.rounds == b.rounds }

    @EnvironmentObject private var loc: Localizer
    @State private var expanded: Bool?

    private var calls: [ChatToolCall] { rounds.flatMap { $0.toolCalls ?? [] } }

    private var running: Bool {
        calls.contains { [.pending, .awaitingPermission, .running].contains($0.state) }
    }

    private var withoutResult: Int {
        calls.filter { call in
            call.state == .failed || call.state == .denied
                || (call.state == .completed && MathTranscriptionService.isMathTool(call.name)
                    && !MathTranscriptionService.succeeded(call))
        }.count
    }

    private var summary: String {
        let count = calls.count == 1 ? loc.t("1 herramienta", "1 tool")
            : loc.t("%@ herramientas", "%@ tools", "\(calls.count)")
        var titles: [String] = []
        for call in calls {
            let title = ToolCallPresentation.make(call).title
            if !titles.contains(title) { titles.append(title) }
        }
        return ([count] + titles.prefix(3)).joined(separator: " · ")
    }

    var body: some View {
        let isExpanded = expanded ?? running
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.appAccent)
                .frame(width: 26, height: 26)
                .background(Color.appAccent.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded = !isExpanded }
                } label: {
                    HStack(spacing: 7) {
                        Text(summary).lineLimit(1)
                        if withoutResult > 0 {
                            Text(loc.t("%@ sin resultado", "%@ without a result", "\(withoutResult)"))
                                .foregroundStyle(.red)
                        }
                        if running { ProgressView().controlSize(.mini) }
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(loc.t("Muestra u oculta las llamadas a herramientas de este turno, con sus resultados y el texto que el modelo escribió antes de cada una.",
                            "Shows or hides this turn's tool calls, with their results and the text the model wrote before each one."))
                if isExpanded {
                    ForEach(rounds.filter { $0.role == "assistant" }) { round in
                        let said = [round.parts.thinking ?? "", round.parts.body, round.settledInterim ?? ""]
                            .filter { !$0.isEmpty }.joined(separator: "\n\n")
                        if !said.isEmpty {
                            DisclosureGroup(loc.t("Texto del modelo antes de la llamada (no verificado)",
                                                  "Model text before the call (not verified)")) {
                                Text(said).chatFont(.small).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(loc.t("Lo que el modelo escribió antes de llamar a la herramienta. No es un resultado: lo calculado está en cada tarjeta.",
                                        "What the model wrote before calling the tool. It is not a result: what was computed is in each card."))
                        }
                        ForEach(round.toolCalls ?? []) { ToolCallCard(call: $0) }
                    }
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
            Spacer(minLength: 70)
        }
    }
}
