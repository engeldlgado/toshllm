import Foundation

/// Checks GitHub Releases for a newer published version.
/// Dependency-free: it notifies and links the download; installing is up to the user.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published var latestVersion: String?
    @Published var releaseURL: URL?
    @Published var checking = false

    static let releasesAPI = "https://api.github.com/repos/engeldlgado/toshllm/releases/latest"

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }

        guard let url = URL(string: Self.releasesAPI),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return }

        let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if Self.isVersion(remote, newerThan: AppInfo.version) {
            latestVersion = remote
            releaseURL = (obj["html_url"] as? String).flatMap(URL.init(string:))
        }
    }

    /// Numeric per-component comparison (0.81.1 < 0.82 < 1.0).
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
