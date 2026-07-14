import Foundation
import SwiftUI

/// Readable model name parsed from the GGUF filename convention
/// (BaseName-SizeLabel-FineTune-Version-Encoding), or from `general.name`.
struct ModelName {
    let title: String
    let quant: String
    let badges: [String]
    private let sizeToken: String

    var display: String {
        var s = title
        if !badges.isEmpty { s += " · " + badges.joined(separator: " · ") }
        if !quant.isEmpty { s += " · " + quant }
        return s
    }

    private static let sep = "[-_.\\s]"
    private static let quantPattern = try! NSRegularExpression(
        pattern: "(?:^|\(sep))((?:UD-)?(?:IQ|Q)\\d+(?:_\\d+)?(?:_[KSMLX]+)*|BF16|F16|F32|FP16|FP8|MXFP4|TQ\\d+_\\d+[A-Za-z]*)(?=$|\(sep))",
        options: [.caseInsensitive])
    // "E" prefix covers gemma effective-param labels (E2B); -A<n>B is MoE active params.
    private static let sizePattern = try! NSRegularExpression(
        pattern: "(?:^|\(sep))((?:\\d+x)?E?\\d+(?:\\.\\d+)?[BM](?:-A\\d+(?:\\.\\d+)?B)?)(?=$|\(sep))",
        options: [.caseInsensitive])

    private static let attrBadges: [(token: String, badge: String)] = [
        ("uncensored", "Uncensored"), ("abliterated", "Abliterated"),
        ("thinking", "Thinking"), ("reasoning", "Reasoning"),
        ("instruct", "Instruct"), ("coder", "Coder"), ("chat", "Chat"),
        ("distill", "Distill"), ("reap", "REAP"), ("base", "Base"),
    ]
    private static let stripFromBase: Set<String> = [
        "uncensored", "abliterated", "distill", "reap", "thinking", "reasoning",
    ]
    private static let acronyms = ["gpt": "GPT", "oss": "OSS", "vl": "VL",
                                   "glm": "GLM", "qwq": "QwQ", "moe": "MoE"]

    private static func cap(_ token: String) -> String {
        if let a = acronyms[token.lowercased()] { return a }
        guard let first = token.first, first.isLowercase else { return token }
        return first.uppercased() + token.dropFirst()
    }

    private static func boundaryHit(_ token: String, in s: String) -> Bool {
        s.range(of: "(?i)(^|\(sep))\(token)($|\(sep))", options: .regularExpression) != nil
    }

    private init(title: String, quant: String, badges: [String], sizeToken: String) {
        self.title = title
        self.quant = quant
        self.badges = badges
        self.sizeToken = sizeToken
    }

    init(_ rawName: String) {
        var s = rawName
        for ext in [".gguf", ".safetensors"] where s.lowercased().hasSuffix(ext) {
            s = String(s.dropLast(ext.count))
        }
        s = s.replacingOccurrences(of: "(?i)[-.]?mmproj|^mmproj-|^mtp-", with: "",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)-\\d{5}-of-\\d{5}", with: "",
                                   options: .regularExpression)

        let full = NSRange(s.startIndex..., in: s)

        var quantToken = ""
        var quantStart = s.endIndex
        if let m = Self.quantPattern.matches(in: s, range: full).last,
           let r = Range(m.range(at: 1), in: s) {
            quantToken = String(s[r]).uppercased()
            quantStart = r.lowerBound
        }

        var sizeToken = ""
        var sizeRange: Range<String.Index>? = nil
        for m in Self.sizePattern.matches(in: s, range: full) {
            if let r = Range(m.range(at: 1), in: s), r.lowerBound < quantStart {
                sizeToken = String(s[r]).uppercased()
                sizeRange = r
                break
            }
        }

        let base: String
        if let sr = sizeRange {
            base = String(s[s.startIndex..<sr.lowerBound])
        } else {
            base = String(s[s.startIndex..<quantStart])
        }

        var seen = Set<String>()
        let cleanBase = base
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map(String.init)
            .filter { !Self.stripFromBase.contains($0.lowercased()) }
            .filter { seen.insert($0.lowercased()).inserted }   // drop "Qwen Qwen" dupes
            .map(Self.cap)
        let titleParts = (cleanBase + [sizeToken]).filter { !$0.isEmpty }
        self.title = titleParts.isEmpty
            ? s.trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
            : titleParts.joined(separator: " ")

        let lower = s.lowercased()
        let titleLower = cleanBase.joined(separator: " ").lowercased()
        var badges: [String] = []
        if sizeToken.contains("-A") || sizeToken.contains("X")
            || lower.contains("moe") || lower.contains("a3b") { badges.append("MoE") }
        let hasVL = Self.boundaryHit("vl", in: lower)
        if !hasVL && lower.contains("vision") { badges.append("Vision") }
        // gemma marks instruction-tuned as a bare "it"; treat it as Instruct.
        if Self.boundaryHit("it", in: lower) && !titleLower.contains("it") {
            badges.append("Instruct")
        }
        for (token, badge) in Self.attrBadges
        where lower.contains(token) && !titleLower.contains(token) && !badges.contains(badge) {
            badges.append(badge)
        }

        self.quant = quantToken
        self.badges = badges
        self.sizeToken = sizeToken
    }

    /// Active parameters in billions from an A<n>B tag (e.g. "35B-A3B" → 3.0).
    static func activeParamsB(_ name: String) -> Double? {
        let ns = name as NSString
        let re = try! NSRegularExpression(pattern: "(?i)[-_.]a(\\d+(?:\\.\\d+)?)b(?:[-_.]|$)")
        guard let m = re.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return Double(ns.substring(with: m.range(at: 1)))
    }

    /// Name looks like a MoE: an A<active>B tag (any active-param count), an
    /// NxM expert count, or an explicit moe/oss marker.
    static func looksMoE(_ name: String) -> Bool {
        let l = name.lowercased()
        return l.range(of: "(?i)(^|[-_.])a\\d+(?:\\.\\d+)?b($|[-_.])", options: .regularExpression) != nil
            || l.range(of: "(?i)(^|[-_.])\\d+x\\d", options: .regularExpression) != nil
            || l.contains("moe") || l.contains("-oss") || l.contains("gpt-oss")
    }

    /// Titles from the embedded `general.name` when local; quant/flags stay from the filename.
    static func forPath(_ path: String) -> ModelName {
        let byFile = ModelName(URL(fileURLWithPath: path).lastPathComponent)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path),
              let meta = ServerSettings.ggufString("general.name", at: path)?
                  .trimmingCharacters(in: .whitespaces),
              !meta.isEmpty else { return byFile }
        // Some converters preserve the Hugging Face repository as owner/model.
        // Only the model component belongs in the title.
        let metadataName = meta.split(separator: "/").last.map(String.init) ?? meta
        let byMeta = ModelName(metadataName)
        guard !byMeta.title.isEmpty else { return byFile }
        let title = byMeta.sizeToken.isEmpty && !byFile.sizeToken.isEmpty
            ? "\(byMeta.title) \(byFile.sizeToken)" : byMeta.title
        var badges: [String] = []
        for badge in byFile.badges + byMeta.badges where !badges.contains(badge) {
            badges.append(badge)
        }
        return ModelName(title: title,
                         quant: byFile.quant.isEmpty ? byMeta.quant : byFile.quant,
                         badges: badges,
                         sizeToken: byMeta.sizeToken.isEmpty ? byFile.sizeToken : byMeta.sizeToken)
    }
}

/// Parsed model name for lists: title with small badge and quant pills.
struct ModelTitleLabel: View {
    let model: ModelName
    var titleFont: Font = .callout

    init(_ model: ModelName, titleFont: Font = .callout) {
        self.model = model
        self.titleFont = titleFont
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(model.title).font(titleFont).lineLimit(1)
            ForEach(model.badges, id: \.self) { badge in
                Text(badge)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.appAccent.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.appAccent)
            }
            if !model.quant.isEmpty {
                Text(model.quant)
                    .font(.system(size: 9, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
