// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftUI
import Darwin

/// Readable model name parsed from the GGUF filename convention
/// (BaseName-SizeLabel-FineTune-Version-Encoding), or from `general.name`.
struct ModelName {
    let title: String
    let quant: String
    let badges: [String]
    let author: String?
    let repository: String?
    let explicitFamily: String?
    private let sizeToken: String

    var repositoryURL: URL? {
        guard let repository, !repository.isEmpty else { return nil }
        return URL(string: "https://huggingface.co/\(repository)")
    }

    var display: String {
        var s = title
        if let author, !author.isEmpty { s += " · " + author }
        if !badges.isEmpty { s += " · " + badges.joined(separator: " · ") }
        if !quant.isEmpty { s += " · " + quant }
        return s
    }

    private static let sep = "[-_.\\s]"
    private static let quantPattern = try! NSRegularExpression(
        pattern: "(?:^|\(sep))((?:UD-)?(?:IQ|Q)\\d+(?:_\\d+)?(?:_[KSMNLX]+)*|BF16|F16|F32|FP16|FP8|MXFP4|TQ\\d+_\\d+[A-Za-z]*)(?=$|\(sep))",
        options: [.caseInsensitive])
    // "E" prefix covers gemma effective-param labels (E2B); -A<n>B is MoE active params.
    private static let sizePattern = try! NSRegularExpression(
        pattern: "(?:^|\(sep))((?:\\d+(?:\\.\\d+)?[BM]-\\d+(?:\\.\\d+)?[BM])|(?:\\d+x)?E?\\d+(?:\\.\\d+)?[BM](?:-A\\d+(?:\\.\\d+)?B)?)(?=$|\(sep))",
        options: [.caseInsensitive])

    private static let attrBadges: [(token: String, badge: String)] = [
        ("uncensored", "Uncensored"), ("abliterated", "Abliterated"),
        ("thinking", "Thinking"), ("reasoning", "Reasoning"),
        ("instruct", "Instruct"), ("coder", "Coder"), ("chat", "Chat"),
        ("distill", "Distill"), ("reap", "REAP"), ("base", "Base"),
        ("qat", "QAT"),
    ]
    private static let stripFromBase: Set<String> = [
        "uncensored", "abliterated", "distill", "reap", "thinking", "reasoning", "qat",
    ]
    private static let acronyms = ["gpt": "GPT", "oss": "OSS", "vl": "VL",
                                   "glm": "GLM", "qwq": "QwQ", "moe": "MoE", "qat": "QAT"]

    private static func cap(_ token: String) -> String {
        if let a = acronyms[token.lowercased()] { return a }
        guard let first = token.first, first.isLowercase else { return token }
        return first.uppercased() + token.dropFirst()
    }

    private static func boundaryHit(_ token: String, in s: String) -> Bool {
        s.range(of: "(?i)(^|\(sep))\(token)($|\(sep))", options: .regularExpression) != nil
    }

    private init(title: String, quant: String, badges: [String], sizeToken: String, author: String? = nil, repository: String? = nil, explicitFamily: String? = nil) {
        self.title = title
        self.quant = quant
        self.badges = badges
        self.sizeToken = sizeToken
        self.author = author
        self.repository = repository
        self.explicitFamily = explicitFamily
    }

    init(_ rawName: String, author: String? = nil, repository: String? = nil, explicitFamily: String? = nil) {
        self.author = author
        self.repository = repository
        self.explicitFamily = explicitFamily
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
        if token.contains("-"), let total = token.split(separator: "-").last {
            token = String(total)
        }
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
        if let explicitFamily, explicitFamily != Self.otherFamily {
            return explicitFamily
        }
        return Self.family(forText: title)
    }

    static func family(forText text: String) -> String {
        let tokens = text.lowercased()
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
        if let m = re.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)),
           m.numberOfRanges > 1 {
            return Double(ns.substring(with: m.range(at: 1)))
        }
        let activeTotal = try! NSRegularExpression(
            pattern: "(?i)(?:^|[-_.])(\\d+(?:\\.\\d+)?)([BM])-(\\d+(?:\\.\\d+)?)[BM](?:[-_.]|$)")
        guard let m = activeTotal.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 2,
              let value = Double(ns.substring(with: m.range(at: 1))) else { return nil }
        return ns.substring(with: m.range(at: 2)).uppercased() == "M" ? value / 1000 : value
    }

    /// Name looks like a MoE: an A<active>B tag (any active-param count), an
    /// NxM expert count, or an explicit moe/oss marker.
    static func looksMoE(_ name: String) -> Bool {
        let l = name.lowercased()
        return l.range(of: "(?i)(^|[-_.])a\\d+(?:\\.\\d+)?b($|[-_.])", options: .regularExpression) != nil
            || l.range(of: "(?i)(^|[-_.])\\d+x\\d", options: .regularExpression) != nil
            || l.contains("moe") || l.contains("-oss") || l.contains("gpt-oss")
    }

    /// Titles prefer useful embedded metadata. Quantization uses the header unless
    /// the filename carries a more specific UD quantization variant.
    static func forPath(_ path: String) -> ModelName {
        if let cached = cacheLock.withLock({ cache[path] }) { return cached }
        let name = resolve(path)
        cacheLock.withLock { cache[path] = name }
        return name
    }

    nonisolated(unsafe) private static var cache: [String: ModelName] = [:]
    private static let cacheLock = NSLock()

    /// Called from list rows, so it is cached: each pass otherwise costs three stat
    /// calls per model and the name never changes while the file does not.
    static func forgetCachedNames() { cacheLock.withLock { cache.removeAll() } }

    /// Extracts Hugging Face URL from macOS extended attribute if downloaded via browser.
    static func whereFromsURL(forPath path: String) -> String? {
        let length = getxattr(path, "com.apple.metadata:kMDItemWhereFroms", nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes {
            getxattr(path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, length, 0, 0)
        }
        guard read == length,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else {
            return nil
        }
        return plist.first(where: { $0.contains("huggingface.co") })
    }

    /// Parses author and cleaned repository name from a Hugging Face URL.
    static func parseHuggingFaceURL(_ urlString: String) -> (author: String, repo: String)? {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              url.host?.contains("huggingface.co") == true else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        var author: String? = nil
        var rawRepo: String? = nil

        if let resolveIndex = components.firstIndex(of: "resolve") ?? components.firstIndex(of: "blob"), resolveIndex >= 2 {
            author = components[resolveIndex - 2]
            rawRepo = components[resolveIndex - 1]
        } else if components.count >= 2 {
            author = components[0]
            rawRepo = components[1]
        }

        guard let author, let rawRepo, !author.isEmpty, !rawRepo.isEmpty else { return nil }
        let cleaned = rawRepo.replacingOccurrences(of: "(?i)[-_.]*gguf.*$", with: "", options: .regularExpression)
        return (author, cleaned.isEmpty ? rawRepo : cleaned)
    }

    private static func resolve(_ path: String) -> ModelName {
        let fileURL = URL(fileURLWithPath: path)
        let fileName = fileURL.lastPathComponent
        let byFile = ModelName(fileName)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return byFile }
        let metadata = GGUFMetadataCache.metadata(at: path)
        let headerQuant = metadata?.fileTypeLabel

        var repoAuthor: String? = nil
        var fullRepo: String? = nil
        var repoModelName: ModelName? = nil

        // 1. Try recorded download source from ToshLLM
        if let sourceURLString = ModelStore.source(forFile: fileName),
           let parsed = parseHuggingFaceURL(sourceURLString) {
            repoAuthor = parsed.author
            fullRepo = "\(parsed.author)/\(parsed.repo)"
            repoModelName = ModelName(parsed.repo, author: repoAuthor, repository: fullRepo)
        }

        // 2. Try macOS browser download origin extended attribute (kMDItemWhereFroms)
        if repoAuthor == nil || repoModelName == nil,
           let whereFroms = whereFromsURL(forPath: path),
           let parsed = parseHuggingFaceURL(whereFroms) {
            if repoAuthor == nil { repoAuthor = parsed.author }
            if fullRepo == nil { fullRepo = "\(parsed.author)/\(parsed.repo)" }
            if repoModelName == nil { repoModelName = ModelName(parsed.repo, author: repoAuthor, repository: fullRepo) }
            ModelStore.recordSource(whereFroms, forFile: fileName)
        }

        // 3. Try GGUF URL metadata keys (e.g. general.base_model.0.repo_url, general.source.url)
        let urlKeys = [
            "general.base_model.0.repo_url",
            "general.source.url",
            "general.repo_url",
            "general.url"
        ]
        for key in urlKeys where repoAuthor == nil || repoModelName == nil {
            if let urlStr = metadata?.string(for: key),
               let parsed = parseHuggingFaceURL(urlStr) {
                if repoAuthor == nil { repoAuthor = parsed.author }
                if fullRepo == nil { fullRepo = "\(parsed.author)/\(parsed.repo)" }
                if repoModelName == nil { repoModelName = ModelName(parsed.repo, author: repoAuthor, repository: fullRepo) }
            }
        }

        let genericMetadataNames: Set<String> = [
            "model", "original model", "converted model", "untitled",
            "ours", "hf", "huggingface", "gguf", "base", "default"
        ]

        // 4. Try general.name with "owner/model" format (e.g. "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF")
        if let meta = metadata?.string(for: "general.name")?.trimmingCharacters(in: .whitespaces),
           meta.contains("/") {
            let parts = meta.split(separator: "/")
            if parts.count >= 2 {
                let owner = String(parts[0])
                if repoAuthor == nil && !genericMetadataNames.contains(owner.lowercased()) {
                    repoAuthor = owner
                }
                let rawRepo = String(parts[1])
                let cleaned = rawRepo.replacingOccurrences(of: "(?i)[-_.]*gguf.*$", with: "", options: .regularExpression)
                if fullRepo == nil && !genericMetadataNames.contains(owner.lowercased()) {
                    fullRepo = "\(owner)/\(rawRepo)"
                }
                if repoModelName == nil && !cleaned.isEmpty && !genericMetadataNames.contains(cleaned.lowercased()) {
                    repoModelName = ModelName(cleaned, author: repoAuthor, repository: fullRepo)
                }
            }
        }

        // 5. Try GGUF organization and author metadata
        let orgKeys = [
            "general.base_model.0.organization",
            "general.organization",
            "general.base_model.0.author",
            "general.author"
        ]
        for key in orgKeys where repoAuthor == nil {
            if let org = metadata?.string(for: key)?.trimmingCharacters(in: .whitespaces),
               !org.isEmpty, !genericMetadataNames.contains(org.lowercased()) {
                repoAuthor = org
            }
        }

        // 6. Try filename prefix if formatted as "author_model" (e.g. "google_gemma-4-E4B-it-Q4_K_M.gguf")
        if repoAuthor == nil, fileName.contains("_") {
            let prefix = String(fileName.split(separator: "_")[0])
            let knownCreators: Set<String> = [
                "google", "unsloth", "bartowski", "meta", "mistralai", "mistral",
                "deepseek", "qwen", "openbmb", "microsoft", "maziyarpanahi",
                "davidau", "thebloke", "empero-ai"
            ]
            if knownCreators.contains(prefix.lowercased()) {
                repoAuthor = prefix
            }
        }

        // 7. Determine the base candidate
        var primary: ModelName? = repoModelName

        if primary == nil, let meta = metadata?.string(for: "general.name")?.trimmingCharacters(in: .whitespaces), !meta.isEmpty {
            let metadataName = meta.split(separator: "/").last.map(String.init) ?? meta
            let byMeta = ModelName(metadataName, author: repoAuthor)
            let isGeneric = genericMetadataNames.contains(byMeta.title.lowercased())
                || genericMetadataNames.contains(metadataName.lowercased())
            if !byMeta.title.isEmpty && !isGeneric {
                primary = byMeta
            }
        }

        if primary == nil, let baseName = metadata?.string(for: "general.base_model.0.name")?.trimmingCharacters(in: .whitespaces), !baseName.isEmpty {
            let byBase = ModelName(baseName, author: repoAuthor)
            if !genericMetadataNames.contains(byBase.title.lowercased()) {
                primary = byBase
            }
        }

        let chosen = primary ?? byFile

        var title = chosen.title
        if chosen.sizeToken.isEmpty && !byFile.sizeToken.isEmpty {
            title = "\(title) \(byFile.sizeToken)"
        } else if byFile.sizeToken.contains("-A"), !chosen.sizeToken.contains("-A") {
            if !chosen.sizeToken.isEmpty {
                let suffix = " \(chosen.sizeToken)"
                if title.hasSuffix(suffix) {
                    title = String(title.dropLast(suffix.count))
                }
            }
            if !title.hasSuffix(byFile.sizeToken) {
                title = "\(title) \(byFile.sizeToken)"
            }
        }

        var badges: [String] = []
        for badge in byFile.badges + chosen.badges where !badges.contains(badge) {
            badges.append(badge)
        }
        let quant = byFile.quant.hasPrefix("UD-")
            ? byFile.quant
            : (headerQuant ?? (byFile.quant.isEmpty ? chosen.quant : byFile.quant))

        // Determine family with robust fallbacks:
        var determinedFamily = Self.family(forText: title)
        if determinedFamily == Self.otherFamily {
            determinedFamily = Self.family(forText: byFile.title)
        }
        if determinedFamily == Self.otherFamily, let arch = metadata?.string(for: "general.architecture") {
            determinedFamily = Self.family(forText: arch)
        }
        if determinedFamily == Self.otherFamily, let baseName = metadata?.string(for: "general.base_model.0.name") {
            determinedFamily = Self.family(forText: baseName)
        }

        // Backfill recorded download source in ToshLLM if missing
        if ModelStore.source(forFile: fileName) == nil {
            if let whereFroms = whereFromsURL(forPath: path) {
                ModelStore.recordSource(whereFroms, forFile: fileName)
            } else if let repo = fullRepo {
                ModelStore.recordSource("https://huggingface.co/\(repo)/resolve/main/\(fileName)", forFile: fileName)
            }
        }

        return ModelName(title: title,
                         quant: quant,
                         badges: badges,
                         sizeToken: chosen.sizeToken.isEmpty ? byFile.sizeToken : byFile.sizeToken,
                         author: repoAuthor,
                         repository: fullRepo ?? chosen.repository,
                         explicitFamily: determinedFamily)
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
            if let author = model.author, !author.isEmpty {
                Text(author)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            ForEach(model.badges, id: \.self) { badge in
                Text(badge)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.appAccent.opacity(0.18), in: Capsule())
                    .foregroundStyle(Color.appAccent)
            }
            if !model.quant.isEmpty {
                Text(model.quant)
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
