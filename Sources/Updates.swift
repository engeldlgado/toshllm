import Foundation
import AppKit

/// Checks GitHub Releases for a newer published version.
/// Dependency-free: it notifies and links the download; installing is up to the user.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published var latestVersion: String?
    @Published var releaseURL: URL?
    @Published var checking = false
    @Published var installing = false
    @Published var installError: String?

    private var dmgURL: URL?
    private var checksumsURL: URL?

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
            if let assets = obj["assets"] as? [[String: Any]] {
                for asset in assets {
                    guard let name = asset["name"] as? String,
                          let urlString = asset["browser_download_url"] as? String,
                          let url = URL(string: urlString) else { continue }
                    if name.hasSuffix(".dmg") { dmgURL = url }
                    if name == "checksums.txt" { checksumsURL = url }
                }
            }
        }
    }

    /// Downloads the release DMG to ~/Downloads, verifies it against the
    /// published checksums, and opens it for the user to install.
    func downloadAndInstall() async {
        guard let dmgURL, !installing else {
            if dmgURL == nil, let releaseURL { NSWorkspace.shared.open(releaseURL) }
            return
        }
        installing = true
        installError = nil
        defer { installing = false }

        do {
            let (temp, _) = try await URLSession.shared.download(from: dmgURL)
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let dest = downloads.appendingPathComponent(dmgURL.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: temp, to: dest)

            if let checksumsURL,
               let (data, _) = try? await URLSession.shared.data(from: checksumsURL),
               let listing = String(data: data, encoding: .utf8) {
                let expected = listing.split(separator: "\n")
                    .first { $0.contains(dmgURL.lastPathComponent) }?
                    .split(separator: " ").first.map(String.init)
                let actual = await Task.detached { FileHash.sha256(of: dest) }.value
                if let expected, let actual, expected.lowercased() != actual.lowercased() {
                    try? FileManager.default.removeItem(at: dest)
                    installError = "Checksum no coincide: descarga descartada / checksum mismatch: download discarded"
                    return
                }
            }
            NSWorkspace.shared.open(dest)
        } catch {
            installError = error.localizedDescription
        }
    }

    /// Numeric per-component comparison (0.81.1 < 0.82 < 1.0).
    nonisolated static func isVersion(_ a: String, newerThan b: String) -> Bool {
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
