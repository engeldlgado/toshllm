import SwiftUI
import AppKit

struct SyntaxHighlightedCode: View {
    let source: String
    let language: String
    @State private var highlighted = AttributedString()

    var body: some View {
        Text(highlighted)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .task(id: source) {
                highlighted = SyntaxHighlighter.highlight(source, language: language)
            }
    }
}

enum SyntaxHighlighter {
    static func highlight(_ source: String, language: String) -> AttributedString {
        let text = NSMutableAttributedString(string: source, attributes: [
            .foregroundColor: OneDarkPro.foreground
        ])
        let keywords = keywordPattern(language)
        let pattern = #"(?s)(?<comment>/\*.*?\*/)|(?<triple>\"\"\".*?\"\"\"|'''.*?''')|(?<linecomment>//[^\n]*|(?m:^\s*#[^\n]*))|(?<string>\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*')|(?<number>\b(?:0x[\da-fA-F]+|\d+(?:\.\d+)?)\b)|(?<keyword>\b(?:"# + keywords + #")\b)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return AttributedString(text)
        }
        let full = NSRange(location: 0, length: text.length)
        regex.enumerateMatches(in: source, range: full) { match, _, _ in
            guard let match else { return }
            let color: NSColor
            if match.range(withName: "comment").location != NSNotFound
                || match.range(withName: "linecomment").location != NSNotFound {
                color = OneDarkPro.comment
            } else if match.range(withName: "string").location != NSNotFound
                        || match.range(withName: "triple").location != NSNotFound {
                color = OneDarkPro.string
            } else if match.range(withName: "number").location != NSNotFound {
                color = OneDarkPro.number
            } else {
                color = OneDarkPro.keyword
            }
            text.addAttribute(.foregroundColor, value: color, range: match.range)
        }
        colorDeclarationNames(in: source, text: text,
                              pattern: #"\b(?:def|func|function)\s+([A-Za-z_$][\w$]*)"#,
                              color: OneDarkPro.function)
        colorDeclarationNames(in: source, text: text,
                              pattern: #"\b(?:class|struct|enum|protocol|interface|typealias)\s+([A-Za-z_$][\w$]*)"#,
                              color: OneDarkPro.type)
        return AttributedString(text)
    }

    private static func colorDeclarationNames(in source: String, text: NSMutableAttributedString,
                                              pattern: String, color: NSColor) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(location: 0, length: text.length)
        regex.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let name = match?.range(at: 1), name.location != NSNotFound else { return }
            text.addAttribute(.foregroundColor, value: color, range: name)
        }
    }

    private static func keywordPattern(_ language: String) -> String {
        switch language.lowercased() {
        case "swift":
            "actor|any|as|async|await|break|case|catch|class|continue|default|defer|do|else|enum|extension|false|for|func|guard|if|import|in|init|is|let|nil|nonisolated|private|protocol|public|repeat|return|self|some|static|struct|switch|throw|throws|true|try|typealias|var|where|while"
        case "python", "py":
            "and|as|assert|async|await|break|class|continue|def|del|elif|else|except|False|finally|for|from|global|if|import|in|is|lambda|None|nonlocal|not|or|pass|raise|return|True|try|while|with|yield"
        case "javascript", "js", "typescript", "ts", "tsx", "jsx":
            "as|async|await|break|case|catch|class|const|continue|debugger|default|delete|do|else|enum|export|extends|false|finally|for|from|function|get|if|implements|import|in|instanceof|interface|let|new|null|of|package|private|protected|public|return|set|static|super|switch|this|throw|true|try|type|typeof|undefined|var|void|while|with|yield"
        case "c", "cpp", "c++", "objective-c", "objc":
            "auto|bool|break|case|catch|char|class|const|constexpr|continue|default|delete|do|double|else|enum|explicit|extern|false|float|for|friend|if|inline|int|long|namespace|new|nullptr|operator|private|protected|public|register|return|short|signed|sizeof|static|struct|switch|template|this|throw|true|try|typedef|typename|union|unsigned|using|virtual|void|volatile|while"
        case "json": "true|false|null"
        case "bash", "sh", "shell", "zsh":
            "case|do|done|elif|else|esac|export|fi|for|function|if|in|local|readonly|return|then|until|while"
        default:
            "break|case|class|const|continue|default|else|enum|false|for|func|function|if|import|let|nil|null|private|public|return|static|struct|switch|true|var|while"
        }
    }
}

enum OneDarkPro {
    static let background = NSColor(srgbRed: 0x28 / 255, green: 0x2C / 255, blue: 0x34 / 255, alpha: 1)
    static let foreground = NSColor(srgbRed: 0xAB / 255, green: 0xB2 / 255, blue: 0xBF / 255, alpha: 1)
    static let comment = NSColor(srgbRed: 0x5C / 255, green: 0x63 / 255, blue: 0x70 / 255, alpha: 1)
    static let keyword = NSColor(srgbRed: 0xC6 / 255, green: 0x78 / 255, blue: 0xDD / 255, alpha: 1)
    static let string = NSColor(srgbRed: 0x98 / 255, green: 0xC3 / 255, blue: 0x79 / 255, alpha: 1)
    static let function = NSColor(srgbRed: 0x61 / 255, green: 0xAF / 255, blue: 0xEF / 255, alpha: 1)
    static let type = NSColor(srgbRed: 0xE5 / 255, green: 0xC0 / 255, blue: 0x7B / 255, alpha: 1)
    static let number = NSColor(srgbRed: 0xD1 / 255, green: 0x9A / 255, blue: 0x66 / 255, alpha: 1)
}

struct CodePreview: View {
    let language: String
    let content: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var loc: Localizer

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.headline)
                Spacer()
                Button(loc.t("Cerrar", "Close"), systemImage: "xmark", action: dismiss.callAsFunction)
                    .labelStyle(.iconOnly)
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            ScrollView([.horizontal, .vertical]) {
                SyntaxHighlightedCode(source: content, language: language)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: OneDarkPro.background))
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}
