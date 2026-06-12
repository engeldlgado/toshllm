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
