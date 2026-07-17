import Foundation

struct BenchmarkShareArtifact: Identifiable {
    let name: String
    let sha256: String
    let sizeBytes: Int64

    var id: String { "\(name):\(sha256)" }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}
