import SwiftUI

// MARK: - Markdown rendering

private enum MDBlock: Equatable {
    case paragraph(String)
    case header(Int, String)
    case bullet([String])
    case numbered([String])
    case code(String, String)   // language, content
    case math(String)
    case quote(String)
    case table([String], [[String]])   // headers, rows
    case rule
}

struct RichText: View {
    let text: String
    /// While true, only the settled portion of `text` is parsed as Markdown and
    /// the still-growing tail is rendered as plain text (see `body`). Off for
    /// finished messages, which are always fully formatted.
    var streaming = false

    // Caches the parsed blocks of the settled prefix so a flush only re-parses
    // when that prefix actually changes (i.e. when a new block boundary is
    // reached), not on every token. Held in @State so it survives view updates;
    // it's a plain reference, so mutating it never invalidates the view.
    @State private var cache = BlockCache()

    var body: some View {
        // While streaming, format only the settled text (everything up to the
        // last block boundary) and render the in-progress tail plainly. The
        // settled blocks are parsed once per boundary (cached) and frozen by
        // Equatable below, so the expensive inline-Markdown/AttributedString
        // work never runs on the hot path. The tail — which changes on every
        // flush — is rendered by PlainGrowingText (chunked + frozen), and snaps
        // to full formatting the moment its block closes.
        //
        // Without this the trailing block re-ran a full Markdown parse on every
        // token (O(n²) over a long answer); that re-layout starved the GPU —
        // which also drives Metal inference — and stalled generation on discrete
        // AMD GPUs.
        let (settled, tail) = streaming ? Self.splitSettled(text) : (text, "")
        let blocks = cache.blocks(for: settled)
        VStack(alignment: .leading, spacing: 8) {
            // Positional identity keeps each block's view alive across flushes;
            // the Equatable wrapper means SwiftUI re-lays-out only the block
            // whose value changed — and while streaming the settled blocks above
            // the tail never change, so they stay frozen.
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MDBlockView(block: block).equatable()
            }
            if !tail.isEmpty {
                PlainGrowingText(text: tail)
            }
        }
    }

    /// Splits `text` into the settled prefix (safe to format) and the
    /// in-progress tail. The boundary is the last blank line that is *not*
    /// inside an open code fence; everything after it may still change as more
    /// tokens arrive, so it is rendered plainly until its block closes.
    private static func splitSettled(_ text: String) -> (settled: String, tail: String) {
        let lines = text.components(separatedBy: "\n")
        var inFence = false
        var fenceChar: Character = "`"
        var fenceLen = 0
        var settledLines = 0
        for (i, line) in lines.enumerated() {
            if let f = fenceInfo(line) {
                if !inFence {
                    inFence = true; fenceChar = f.char; fenceLen = f.length
                } else if f.info.isEmpty, f.char == fenceChar, f.length >= fenceLen {
                    inFence = false
                }
            } else if !inFence, line.trimmingCharacters(in: .whitespaces).isEmpty {
                settledLines = i + 1
            }
        }
        let settled = lines[..<settledLines].joined(separator: "\n")
        let tail = lines[settledLines...].joined(separator: "\n")
        return (settled, tail)
    }

    /// Memoizes the parsed blocks of the settled prefix. Re-parses only when the
    /// settled string changes, turning a per-flush full parse into one parse per
    /// new block boundary.
    private final class BlockCache {
        private var key = "\u{0}"   // sentinel so an empty prefix parses once
        private var cached: [MDBlock] = []
        func blocks(for settled: String) -> [MDBlock] {
            if settled != key { cached = RichText.parse(settled); key = settled }
            return cached
        }
    }

    // MARK: parser

    private static func parse(_ raw: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false)[...]
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbers: [String] = []

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
            if !bullets.isEmpty { blocks.append(.bullet(bullets)); bullets = [] }
            if !numbers.isEmpty { blocks.append(.numbered(numbers)); numbers = [] }
        }

        while let line = lines.first {
            lines = lines.dropFirst()
            let l = String(line)

            let trimmed = l.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("$$") || trimmed == "\\[" {
                flush()
                let bracketed = trimmed == "\\["
                let closing = bracketed ? "\\]" : "$$"
                if !bracketed, trimmed.count > 4, trimmed.hasSuffix("$$") {
                    blocks.append(.math(String(trimmed.dropFirst(2).dropLast(2))))
                    continue
                }
                var formula: [String] = []
                while let next = lines.first {
                    lines = lines.dropFirst()
                    if next.trimmingCharacters(in: .whitespaces) == closing { break }
                    formula.append(String(next))
                }
                blocks.append(.math(formula.joined(separator: "\n")))
            } else if let fence = fenceInfo(l) {
                flush()
                var code: [String] = []
                // CommonMark: close only on a bare fence of the same char and
                // length >= the opening one. A shorter inner fence (e.g. a
                // ```python example inside a ````markdown block) is content,
                // not a close — without this the block ends early and the code
                // leaks out as a paragraph.
                while let next = lines.first {
                    if let close = fenceInfo(String(next)),
                       close.info.isEmpty, close.char == fence.char, close.length >= fence.length {
                        lines = lines.dropFirst()
                        break
                    }
                    code.append(String(next))
                    lines = lines.dropFirst()
                }
                blocks.append(.code(fence.info, code.joined(separator: "\n")))
            } else if let m = l.range(of: #"^#{1,6} "#, options: .regularExpression) {
                flush()
                let level = l[..<m.upperBound].filter { $0 == "#" }.count
                blocks.append(.header(level, String(l[m.upperBound...])))
            } else if l.hasPrefix(">") {
                flush()
                var quoteLines = [stripQuote(l)]
                while let next = lines.first, next.hasPrefix(">") {
                    quoteLines.append(stripQuote(String(next)))
                    lines = lines.dropFirst()
                }
                // Trim the surrounding empty `>` lines models often add, which
                // otherwise pad the quote with blank lines and stretch its bar.
                let quote = quoteLines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !quote.isEmpty { blocks.append(.quote(quote)) }
            } else if let headers = tableCells(l),
                      let sep = lines.first, isTableSeparator(String(sep)) {
                flush()
                lines = lines.dropFirst()
                var rows: [[String]] = []
                while let next = lines.first, let cells = tableCells(String(next)) {
                    rows.append(cells)
                    lines = lines.dropFirst()
                }
                blocks.append(.table(headers, rows))
            } else if l.range(of: #"^\s*([-*_])(\s*\1){2,}\s*$"#, options: .regularExpression) != nil {
                flush()
                blocks.append(.rule)
            } else if l.range(of: #"^\s*[-*+] "#, options: .regularExpression) != nil {
                if !paragraph.isEmpty || !numbers.isEmpty { flush() }
                bullets.append(l.replacingOccurrences(of: #"^\s*[-*+] "#, with: "", options: .regularExpression))
            } else if l.range(of: #"^\s*\d+[.)] "#, options: .regularExpression) != nil {
                if !paragraph.isEmpty || !bullets.isEmpty { flush() }
                numbers.append(l.replacingOccurrences(of: #"^\s*\d+[.)] "#, with: "", options: .regularExpression))
            } else if l.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                if !bullets.isEmpty || !numbers.isEmpty { flush() }
                paragraph.append(l)
            }
        }
        flush()
        return blocks
    }

    /// A fenced-code delimiter: leading spaces, then >=3 backticks or tildes,
    /// then an optional info string. Returns the fence char, its length and the
    /// info string, or nil when the line is not a fence. Backtick info strings
    /// may not contain backticks (CommonMark), which also rules out inline code.
    private static func fenceInfo(_ line: String) -> (char: Character, length: Int, info: String)? {
        let t = line.drop(while: { $0 == " " })
        guard let first = t.first, first == "`" || first == "~" else { return nil }
        let run = t.prefix(while: { $0 == first })
        guard run.count >= 3 else { return nil }
        let info = String(t.dropFirst(run.count)).trimmingCharacters(in: .whitespaces)
        if first == "`" && info.contains("`") { return nil }
        return (first, run.count, info)
    }

    private static func stripQuote(_ line: String) -> String {
        var s = line
        if s.hasPrefix("> ") { s.removeFirst(2) } else if s.hasPrefix(">") { s.removeFirst() }
        return s
    }

    /// "[ ] item" / "[x] item" → checkbox state, nil for regular bullets.
    fileprivate static func taskState(_ item: String) -> Bool? {
        if item.hasPrefix("[ ] ") { return false }
        if item.hasPrefix("[x] ") || item.hasPrefix("[X] ") { return true }
        return nil
    }

    /// Splits a `| a | b |` line into trimmed cells; nil when it has no pipes.
    private static func tableCells(_ line: String) -> [String]? {
        var t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("|") else { return nil }
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        let cells = t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.isEmpty ? nil : cells
    }

    /// `|---|:---:|` style separator under the header row.
    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.contains("-") && t.contains("|")
            && t.range(of: #"^[\s|:\-]+$"#, options: .regularExpression) != nil
    }

    static func inline(_ s: String) -> AttributedString {
        var attr = (try? AttributedString(markdown: s, options: .init(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        // Links parse but render as plain colored text otherwise; underline and
        // tint the link runs so they read (and behave) as links.
        for run in attr.runs where run.link != nil {
            attr[run.range].underlineStyle = .single
            attr[run.range].foregroundColor = .accentColor
        }
        return attr
    }

    static func containsInlineMath(_ value: String) -> Bool {
        value.range(of: #"\\\([\s\S]+?\\\)|(?<![\\$])\$(?!\$)[\s\S]+?(?<![\\$])\$(?!\$)"#,
                    options: .regularExpression) != nil
    }
}

/// Renders the still-growing tail of a streaming answer cheaply. Completed
/// line-chunks are frozen (Equatable) so they lay out once; only the last,
/// growing chunk re-renders per flush — turning the tail's per-flush cost from
/// O(n) into O(1). Without this a single huge block (e.g. a long code listing,
/// which never produces a settling blank line so the whole thing stays in the
/// tail) re-laid-out in full on every token and the UI crawled far behind the
/// already-finished backend.
private struct PlainGrowingText: View {
    let text: String
    /// Lines per frozen chunk: small enough that the live remainder stays cheap
    /// to re-render, large enough that chunk boundaries are infrequent.
    private static let chunkLines = 50

    var body: some View {
        var lines = text.components(separatedBy: "\n")
        // An open code fence streams in monospace (it snaps to a full CodeBlock
        // once the closing fence settles the block). Drop the opening ```/~~~
        // line while the fence is still open.
        var font: Font = .body
        if let first = lines.first?.trimmingCharacters(in: .whitespaces),
           first.hasPrefix("```") || first.hasPrefix("~~~") {
            font = .system(size: 12, design: .monospaced)
            lines.removeFirst()
        }
        let complete = lines.count / Self.chunkLines
        let chunks = stride(from: 0, to: complete * Self.chunkLines, by: Self.chunkLines)
            .map { lines[$0 ..< $0 + Self.chunkLines].joined(separator: "\n") }
        let rest = lines[(complete * Self.chunkLines)...].joined(separator: "\n")
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                FrozenChunk(text: chunk, font: font).equatable()
            }
            if !rest.isEmpty {
                Text(verbatim: rest).font(font).textSelection(.enabled)
            }
        }
    }
}

/// One settled line-chunk of a streaming tail. Equatable on its text alone (the
/// font is constant for a given chunk), so once its lines stop changing SwiftUI
/// never re-lays-it-out again.
private struct FrozenChunk: View, Equatable {
    let text: String
    let font: Font
    static func == (a: FrozenChunk, b: FrozenChunk) -> Bool { a.text == b.text }
    var body: some View { Text(verbatim: text).font(font).textSelection(.enabled) }
}

/// Renders one parsed Markdown block. Equatable on its block value so that,
/// during streaming, SwiftUI skips re-rendering every completed block above the
/// one currently being written — the key to not re-laying-out the whole answer
/// on each token (see RichText.body).
private struct MDBlockView: View, Equatable {
    let block: MDBlock

    static func == (lhs: MDBlockView, rhs: MDBlockView) -> Bool { lhs.block == rhs.block }

    var body: some View {
        switch block {
        case .paragraph(let s):
            if RichText.containsInlineMath(s) {
                InlineMathText(source: s)
            } else {
                Text(RichText.inline(s)).textSelection(.enabled)
            }
        case .header(let level, let s):
            Text(RichText.inline(s))
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .textSelection(.enabled)
                .padding(.top, 2)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        if let done = RichText.taskState(item) {
                            Image(systemName: done ? "checkmark.square" : "square")
                                .font(.callout).foregroundStyle(.secondary)
                            Text(RichText.inline(String(item.dropFirst(4)))).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("•").foregroundStyle(.secondary)
                            Text(RichText.inline(item)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\(i + 1).").foregroundStyle(.secondary)
                            .font(.system(.body, design: .monospaced))
                        Text(RichText.inline(item)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .code(let lang, let content):
            switch lang.lowercased() {
            case "mermaid": RichContentBlock(source: content, kind: .mermaid)
            case "svg": RichContentBlock(source: content, kind: .svg)
            default: CodeBlock(language: lang, content: content)
            }
        case .math(let formula):
            RichContentBlock(source: formula, kind: .math)
        case .quote(let s):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(.tertiary).frame(width: 3)
                Text(RichText.inline(s)).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .table(let headers, let rows):
            MDTable(headers: headers, rows: rows)
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }
}

/// Markdown pipe table rendered as a grid: bold header, hairline divider and
/// striped rows, selectable text.
private struct MDTable: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                    Text(RichText.inline(h))
                        .fontWeight(.semibold)
                        .padding(.vertical, 6)
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                GridRow {
                    ForEach(0..<headers.count, id: \.self) { c in
                        Text(RichText.inline(c < row.count ? row[c] : ""))
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(i.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.07))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .textSelection(.enabled)
    }
}

struct CodeBlock: View {
    let language: String
    let content: String
    @EnvironmentObject var loc: Localizer
    @State private var copied = false
    @State private var previewing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    previewing = true
                } label: {
                    Label(loc.t("Ampliar código", "Expand code"),
                          systemImage: "arrow.up.left.and.arrow.down.right")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(loc.t("Abrir código en una vista amplia", "Open code in a larger view"))
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(loc.t("Copiar código", "Copy code"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 10))
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.borderless)
                .help(loc.t("Copiar código", "Copy code"))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(nsColor: OneDarkPro.background).brightness(-0.04))

            ScrollView(.horizontal) {
                SyntaxHighlightedCode(source: content, language: language)
                    .padding(10)
            }
            .background(Color(nsColor: OneDarkPro.background))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $previewing) {
            CodePreview(language: language, content: content)
                .environmentObject(loc)
        }
    }
}
