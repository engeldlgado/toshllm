import Foundation

enum VideoRuntimeAvailability {
    static var executableDirectories: [String] {
        var values = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin"]
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            values.insert(bundled, at: 0)
        }
        return values
    }

    static var isAvailable: Bool {
        executableDirectories.contains { directory in
            FileManager.default.isExecutableFile(atPath: directory + "/ffmpeg")
                && FileManager.default.isExecutableFile(atPath: directory + "/ffprobe")
        }
    }

    static func augmentedPath(_ existing: String?) -> String {
        var values = executableDirectories
        values.append(contentsOf: (existing ?? "").split(separator: ":").map(String.init))
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }
}
