import Foundation

struct HFRepo: Identifiable, Decodable {
    let id: String
    let downloads: Int?
    let likes: Int?
}

struct HFFile: Identifiable {
    let path: String
    let sizeBytes: Int64
    let paths: [String]
    var id: String { path }
    var sizeGB: String { String(format: "%.1f GB", Double(sizeBytes) / 1_073_741_824) }
    /// Name-based guess; the UI should ask `SearchStore.isMoE(repo:file:)`.
    var isMoE: Bool { ModelName.looksMoE(path) }
}

@MainActor
final class SearchStore: ObservableObject {
    @Published var query = ""
    @Published var results: [HFRepo] = []
    @Published var files: [String: [HFFile]] = [:]
    /// Repos whose HF tree contains an `*mmproj*.gguf`; the model list filters
    /// projectors out, so vision detection reads this instead.
    @Published var visionRepos: Set<String> = []
    /// A compatible DFlash speculative-decoding draft found for a repo, if any.
    struct DraftInfo: Equatable { let repo: String; let file: String; let sizeBytes: Int64 }
    @Published var draftRepos: [String: DraftInfo] = [:]
    private var draftProbed: Set<String> = []
    @Published var expanded: String?
    @Published var searching = false
    @Published var didSearch = false

    @Published var trending: [HFRepo] = []
    @Published var loadingTrending = false

    /// expert_count from each candidate's GGUF header, keyed by download URL.
    @Published var headerMoE: [String: Bool] = [:]

    /// A renamed MoE is invisible to the filename guess, and calling it dense sizes
    /// the fit estimate against full VRAM instead of expert offload.
    func isMoE(repo: String, file: HFFile) -> Bool {
        headerMoE[downloadURL(repo: repo, file: file.path)] ?? file.isMoE
    }

    /// The GGUF models trending on Hugging Face right now — the "discovery"
    /// half of the hybrid Browse tab (curated recommendations are computed
    /// locally elsewhere). Fetched once; rows reuse the same expand-to-files
    /// path as search, so fit badges appear per quant on expand.
    func loadTrending(force: Bool = false) async {
        if force { trending = [] }
        guard trending.isEmpty, !loadingTrending else { return }
        loadingTrending = true
        defer { loadingTrending = false }

        // trendingScore is HF's live trending order; fall back to all-time
        // downloads if it ever yields nothing, so the tab is never empty.
        for sort in ["trendingScore", "downloads"] {
            var comps = URLComponents(string: "https://huggingface.co/api/models")!
            comps.queryItems = [
                URLQueryItem(name: "filter", value: "gguf"),
                URLQueryItem(name: "sort", value: sort),
                URLQueryItem(name: "limit", value: "15"),
            ]
            guard let url = comps.url,
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let repos = try? JSONDecoder().decode([HFRepo].self, from: data) else { continue }
            if !repos.isEmpty { trending = repos; return }
        }
    }

    func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        defer { searching = false; didSearch = true }

        var comps = URLComponents(string: "https://huggingface.co/api/models")!
        comps.queryItems = [
            URLQueryItem(name: "search", value: q),
            URLQueryItem(name: "filter", value: "gguf"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "limit", value: "12"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url) else {
            results = []
            return
        }
        results = (try? JSONDecoder().decode([HFRepo].self, from: data)) ?? []
        expanded = nil
        files = [:]
    }

    func toggleFiles(repo: String) async {
        if expanded == repo { expanded = nil; return }
        expanded = repo
        guard files[repo] == nil else { return }

        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        let ggufEntries = entries.compactMap { entry -> GGUFFileEntry? in
            guard let path = entry["path"] as? String, path.lowercased().hasSuffix(".gguf") else { return nil }
            let size = (entry["size"] as? NSNumber)?.int64Value ?? 0
            return GGUFFileEntry(path: path, sizeBytes: size)
        }
        if ggufEntries.contains(where: { $0.path.lowercased().contains("mmproj") }) {
            visionRepos.insert(repo)
        }
        let list = GGUFFile.models(from: ggufEntries).map {
            HFFile(path: $0.primaryPath, sizeBytes: $0.sizeBytes, paths: $0.paths)
        }
        .sorted { $0.sizeBytes < $1.sizeBytes }
        files[repo] = list
        // Detached so the list renders now; estimates refine as headers land.
        Task { await probeHeaders(repo: repo, files: list) }
        Task { await detectDraft(repo: repo) }
    }

    /// One HF search per repo (cached) for a compatible DFlash draft. The draft is
    /// a separate repo named `<base>…DFlash…`; we keep only mainline-loadable ones.
    private func detectDraft(repo: String) async {
        guard !draftProbed.contains(repo) else { return }
        draftProbed.insert(repo)
        let base = Self.modelBaseName(repo)
        guard base.count >= 4,
              let q = "\(base) DFlash".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://huggingface.co/api/models?search=\(q)&limit=12"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        let baseKey = Self.alnum(base)
        for m in arr {
            guard let id = m["id"] as? String,
                  id.lowercased().contains("dflash"),
                  Self.alnum(id).contains(baseKey),
                  let best = await bestDraftFile(repo: id) else { continue }
            draftRepos[repo] = best
            return
        }
    }

    private func bestDraftFile(repo: String) async -> DraftInfo? {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let ggufs: [(String, Int64)] = arr.compactMap { e in
            guard let p = e["path"] as? String, p.lowercased().hasSuffix(".gguf") else { return nil }
            return (p, (e["size"] as? NSNumber)?.int64Value ?? 0)
        }
        // q8_0 is the draft sweet spot (best acceptance, small); fall back downward.
        func pick(_ k: String) -> (String, Int64)? { ggufs.first { $0.0.lowercased().contains(k) } }
        guard let best = pick("q8_0") ?? pick("q6") ?? pick("q4_k_m") ?? pick("q4") ?? ggufs.min(by: { $0.1 < $1.1 })
        else { return nil }
        // Only offer drafts our engine can load: it needs the `dflash.target_layers`
        // key; newer converters emit `dflash.target_layer_ids`, which won't load.
        guard await Self.headerContains(downloadURL(repo: repo, file: best.0), "dflash.target_layers") else { return nil }
        return DraftInfo(repo: repo, file: best.0, sizeBytes: best.1)
    }

    nonisolated private static func headerContains(_ urlString: String, _ key: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(headerProbeBytes - 1)", forHTTPHeaderField: "Range")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return false }
        return data.range(of: Data(key.utf8)) != nil
    }

    /// The bare model name from a repo id, minus owner and a trailing GGUF marker.
    private static func modelBaseName(_ repo: String) -> String {
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        return name.replacingOccurrences(of: "(?i)[-_ ]?gguf$", with: "", options: .regularExpression)
    }

    private static func alnum(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The metadata block sits in the first few KB, so one small range request per
    /// file is enough, and they share a single HTTP/2 connection to the host.
    private func probeHeaders(repo: String, files: [HFFile]) async {
        let pending = files.map { downloadURL(repo: repo, file: $0.path) }
            .filter { headerMoE[$0] == nil }
        guard !pending.isEmpty else { return }

        await withTaskGroup(of: (String, Bool?).self) { group in
            for url in pending {
                group.addTask { (url, await Self.probeMoE(urlString: url)) }
            }
            for await (url, moe) in group {
                if let moe { headerMoE[url] = moe }
            }
        }
    }

    /// nil when unreadable (offline, non-GGUF, truncated): caller keeps the guess.
    nonisolated private static func probeMoE(urlString: String) async -> Bool? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(headerProbeBytes - 1)", forHTTPHeaderField: "Range")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let metadata = GGUFMetadataCache.parse(from: data) else { return nil }
        return (metadata.uint32(forSuffix: "expert_count") ?? 0) > 0
    }

    /// Generous: measured GGUFs put expert_count ~1.5 KB in.
    nonisolated private static let headerProbeBytes = 64 * 1024

    func downloadURL(repo: String, file: String) -> String {
        "https://huggingface.co/\(repo)/resolve/main/\(file)"
    }
}
