import Foundation

struct HFRepo: Identifiable, Decodable {
    let id: String
    let downloads: Int?
    let likes: Int?
}

struct HFFile: Identifiable {
    let path: String
    let sizeBytes: Int64
    var id: String { path }
    var sizeGB: String { String(format: "%.1f GB", Double(sizeBytes) / 1_073_741_824) }
    var isMoE: Bool {
        let p = path.lowercased()
        return p.contains("a3b") || p.contains("a22b") || p.contains("moe") || p.contains("oss")
    }
}

@MainActor
final class SearchStore: ObservableObject {
    @Published var query = ""
    @Published var results: [HFRepo] = []
    @Published var files: [String: [HFFile]] = [:]
    @Published var expanded: String?
    @Published var searching = false
    @Published var didSearch = false

    @Published var trending: [HFRepo] = []
    @Published var loadingTrending = false

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

        files[repo] = entries.compactMap { entry in
            guard let path = entry["path"] as? String, path.lowercased().hasSuffix(".gguf") else { return nil }
            let size = (entry["size"] as? NSNumber)?.int64Value ?? 0
            return HFFile(path: path, sizeBytes: size)
        }
        .sorted { $0.sizeBytes < $1.sizeBytes }
    }

    func downloadURL(repo: String, file: String) -> String {
        "https://huggingface.co/\(repo)/resolve/main/\(file)"
    }
}
