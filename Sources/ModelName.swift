// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

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

    /// Total parameters in billions from the size label ("0.6B" → 0.6, "8x7B" → 56,
    /// "E4B" → 4, "70M" → 0.07). The A<n>B tag is active params and is ignored here.
    var paramsB: Double? {
        var token = sizeToken.uppercased()
        if let a = token.range(of: "-A") { token = String(token[token.startIndex..<a.lowerBound]) }
        var multiplier = 1.0
        if let x = token.firstIndex(of: "X"), let n = Double(token[token.startIndex..<x]) {
            multiplier = n
            token = String(token[token.index(after: x)...])
        }
        if token.hasPrefix("E") { token = String(token.dropFirst()) }
        let millions = token.hasSuffix("M")
        guard let value = Double(token.dropLast()) else { return nil }
        return multiplier * value / (millions ? 1000 : 1)
    }

    /// Family the picker groups under. Merges a maker's generations and its
    /// architecture spellings, so Qwen3, Qwen2.5 and QwQ all land together.
    var family: String {
        let tokens = title.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        // The name splits into "gpt" + "oss", so the pair has to be read together.
        if tokens.contains("gpt") && tokens.contains("oss") { return "GPT-OSS" }
        for (key, name) in Self.families {
            let hit = key.count <= 2
                ? tokens.contains(key)
                : tokens.contains { $0.hasPrefix(key) }
            if hit { return name }
        }
        return Self.otherFamily
    }

    /// Bucket for makers the table does not know, so the picker does not fill up
    /// with one-model sections. The view localises this one.
    static let otherFamily = "Others"

    /// Longest and most specific keys first: a token is matched by prefix, so
    /// "gpt-oss" has to win before "gpt" and "bailing" before "ling".
    private static let families: [(String, String)] = [
        ("qwq", "Qwen"), ("qwen", "Qwen"),
        ("chatglm", "GLM"), ("glm", "GLM"),
        ("tinyllama", "Llama"), ("codellama", "Llama"), ("llama", "Llama"),
        ("codegemma", "Gemma"), ("gemma", "Gemma"),
        ("mixtral", "Mistral"), ("ministral", "Mistral"), ("magistral", "Mistral"),
        ("devstral", "Mistral"), ("codestral", "Mistral"), ("mistral", "Mistral"),
        ("deepseek", "DeepSeek"), ("dflash", "DeepSeek"),
        ("phi", "Phi"), ("granite", "Granite"),
        ("gpt", "GPT"),
        ("olmo", "OLMo"), ("hunyuan", "Hunyuan"), ("falcon", "Falcon"),
        ("nemotron", "Nemotron"),
        ("command", "Command"), ("cohere", "Command"), ("aya", "Command"),
        ("smol", "SmolLM"), ("stablelm", "StableLM"), ("stablecode", "StableLM"),
        ("internlm", "InternLM"), ("exaone", "EXAONE"),
        ("seed", "Seed"), ("kimi", "Kimi"), ("minimax", "MiniMax"),
        ("minicpm", "MiniCPM"), ("ernie", "ERNIE"), ("dots", "dots"),
        ("apriel", "Apriel"), ("bailing", "Ling"), ("ling", "Ling"),
        ("openchat", "OpenChat"), ("vicuna", "Vicuna"), ("zephyr", "Zephyr"),
        ("solar", "Solar"), ("orion", "Orion"), ("jamba", "Jamba"),
        ("mamba", "Mamba"), ("rwkv", "RWKV"), ("arwkv", "RWKV"),
        ("arcee", "Arcee"), ("afm", "Arcee"), ("apertus", "Apertus"),
        ("arctic", "Arctic"), ("baichuan", "Baichuan"), ("bitnet", "BitNet"),
        ("bloom", "BLOOM"), ("chameleon", "Chameleon"), ("codeshell", "CodeShell"),
        ("cogvlm", "CogVLM"), ("dbrx", "DBRX"), ("deci", "Deci"),
        ("dream", "Dream"), ("grok", "Grok"), ("grove", "GroveMoE"),
        ("jais", "Jais"), ("laguna", "Laguna"), ("lfm", "LFM"),
        ("llada", "LLaDA"), ("maincoder", "Maincoder"), ("mellum", "Mellum"),
        ("mimo", "MiMo"), ("mpt", "MPT"), ("nanbeige", "Nanbeige"),
        ("openelm", "OpenELM"), ("pangu", "PanGu"), ("plamo", "PLaMo"),
        ("refact", "Refact"), ("smallthinker", "SmallThinker"),
        ("starcoder", "StarCoder"), ("step", "Step"), ("xverse", "XVERSE"),
        ("yi", "Yi"), ("plm", "PLM"), ("moonlight", "Kimi"),
    ]

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

    /// Titles from the embedded `general.name` when local. Quantization comes from
    /// `general.file_type`; filenames are only the fallback for incomplete metadata.
    static func forPath(_ path: String) -> ModelName {
        let byFile = ModelName(URL(fileURLWithPath: path).lastPathComponent)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return byFile }
        let metadata = GGUFMetadataCache.metadata(at: path)
        let headerQuant = metadata?.fileTypeLabel
        guard
              let meta = ServerSettings.ggufString("general.name", at: path)?
                  .trimmingCharacters(in: .whitespaces),
              !meta.isEmpty else {
            guard let headerQuant else { return byFile }
            return ModelName(title: byFile.title, quant: headerQuant,
                             badges: byFile.badges, sizeToken: byFile.sizeToken)
        }
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
                         quant: headerQuant ?? (byFile.quant.isEmpty ? byMeta.quant : byFile.quant),
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
