import Foundation

struct LocalModel: Identifiable, Hashable {
    let url: URL
    let name: String
    let sizeBytes: Int64
    var id: String { url.path }
    var sizeGB: String { String(format: "%.1f GB", Double(sizeBytes) / 1_073_741_824) }
    var isMoE: Bool { name.localizedCaseInsensitiveContains("a3b") || name.localizedCaseInsensitiveContains("moe") }
}


@MainActor
final class DownloadItem: NSObject, ObservableObject, Identifiable, URLSessionDownloadDelegate {
    enum Phase: Equatable {
        case preparing, downloading, paused, verifying, finished
        case failed(String)
    }

    let id = UUID()
    let remote: URL
    let destination: URL
    let fileName: String

    @Published var phase: Phase = .preparing
    @Published var progress: Double = 0
    @Published var receivedMB: Double = 0
    @Published var totalMB: Double = 0

    var onFinish: (() -> Void)?

    private var expectedSHA256: String?
    private var expectedBytes: Int64?
    private var task: URLSessionDownloadTask?
    private var resumeData: Data?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    // Compatibility accessors used across the UI
    var finished: Bool { phase == .finished }
    var error: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    init(remote: URL, destination: URL) {
        self.remote = remote
        self.destination = destination
        self.fileName = remote.lastPathComponent
        super.init()
        Task { await prepare() }
    }

    /// Fetches integrity metadata, checks disk space, then starts the transfer.
    private func prepare() async {
        if let meta = await Self.huggingFaceMetadata(for: remote) {
            expectedSHA256 = meta.sha256
            expectedBytes = meta.size
        }

        if let needed = expectedBytes {
            let values = try? destination.deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let free = values?.volumeAvailableCapacityForImportantUsage,
               free < needed + 1_000_000_000 {
                let neededGB = Double(needed) / 1_073_741_824
                let freeGB = Double(free) / 1_073_741_824
                phase = .failed(String(format: "Espacio insuficiente: %.1f GB libres, %.1f GB necesarios / not enough disk space", freeGB, neededGB))
                return
            }
            totalMB = Double(needed) / 1_048_576
        }

        startTask()
    }

    private func startTask() {
        let t: URLSessionDownloadTask
        if let data = resumeData {
            t = session.downloadTask(withResumeData: data)
            resumeData = nil
        } else {
            t = session.downloadTask(with: remote)
        }
        task = t
        phase = .downloading
        t.resume()
    }

    func pause() {
        guard phase == .downloading else { return }
        task?.cancel { [weak self] data in
            Task { @MainActor in
                self?.resumeData = data
                self?.phase = .paused
            }
        }
    }

    func resume() {
        guard phase == .paused else { return }
        startTask()
    }

    func cancel() {
        task?.cancel()
        session.invalidateAndCancel()
        phase = .failed("Cancelada / cancelled")
    }

    // MARK: integrity

    /// repo + file path -> sha256/size from the Hugging Face tree API (LFS oid).
    private static func huggingFaceMetadata(for url: URL) async -> (sha256: String?, size: Int64?)? {
        guard url.host?.contains("huggingface.co") == true else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let resolve = parts.firstIndex(of: "resolve"), resolve >= 2, parts.count > resolve + 1 else { return nil }
        let repo = parts[0] + "/" + parts[1]
        let rev = parts[resolve + 1]
        let filePath = parts[(resolve + 2)...].joined(separator: "/")
        let dir = filePath.contains("/") ? "/" + filePath.split(separator: "/").dropLast().joined(separator: "/") : ""

        guard let api = URL(string: "https://huggingface.co/api/models/\(repo)/tree/\(rev)\(dir)"),
              let (data, _) = try? await URLSession.shared.data(from: api),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }

        guard let entry = entries.first(where: { ($0["path"] as? String) == filePath }) else { return nil }
        let size = (entry["size"] as? NSNumber)?.int64Value
        let sha = (entry["lfs"] as? [String: Any])?["oid"] as? String
        return (sha, size)
    }

    // MARK: URLSessionDownloadDelegate

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
        let p = expected > 0 ? Double(totalBytesWritten) / Double(expected) : 0
        let rec = Double(totalBytesWritten) / 1_048_576
        let tot = Double(expected) / 1_048_576
        Task { @MainActor in
            self.progress = p
            self.receivedMB = rec
            if tot > 0 { self.totalMB = tot }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        let dest = destination
        // Move out of the system temp dir synchronously, then verify.
        let staging = dest.appendingPathExtension("download")
        do {
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            let msg = error.localizedDescription
            Task { @MainActor in self.phase = .failed(msg) }
            return
        }

        Task { @MainActor in
            self.phase = .verifying
            let expected = self.expectedSHA256
            let ok: Bool = await Task.detached(priority: .userInitiated) {
                guard let expected else { return true }   // no checksum published
                return FileHash.sha256(of: staging)?.lowercased() == expected.lowercased()
            }.value

            if ok {
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.moveItem(at: staging, to: dest)
                    self.progress = 1
                    self.phase = .finished
                    self.onFinish?()
                } catch {
                    self.phase = .failed(error.localizedDescription)
                }
            } else {
                try? FileManager.default.removeItem(at: staging)
                AppLog.downloads.error("checksum mismatch for \(self.fileName)")
                self.phase = .failed("Checksum SHA-256 no coincide: descarga corrupta, reintenta / checksum mismatch: corrupt download, retry")
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let msg = error.localizedDescription
        Task { @MainActor in
            // Keep resume data so a transient network failure is resumable.
            if let data {
                self.resumeData = data
                self.phase = .paused
            } else {
                self.phase = .failed(msg)
            }
        }
    }
}

@MainActor
final class ModelStore: ObservableObject {
    @Published var models: [LocalModel] = []
    @Published var downloads: [DownloadItem] = []

    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("models")

    func refresh() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        models = files
            .filter { $0.pathExtension.lowercased() == "gguf" }
            .compactMap { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                return LocalModel(url: url, name: url.lastPathComponent, sizeBytes: size)
            }
            .sorted { $0.sizeBytes < $1.sizeBytes }
    }

    func isDownloaded(fileName: String) -> Bool {
        models.contains { $0.name == fileName }
    }

    func localModel(fileName: String) -> LocalModel? {
        models.first { $0.name == fileName }
    }

    func isDownloading(fileName: String) -> Bool {
        downloads.contains { $0.fileName == fileName && !$0.finished && $0.error == nil }
    }

    /// The in-progress (or failed) download for a file, so a card can show its
    /// live progress right where the user pressed Download. Finished ones are
    /// excluded — the model then appears as a local file instead.
    func downloadItem(fileName: String) -> DownloadItem? {
        downloads.last { $0.fileName == fileName && !$0.finished }
    }

    func download(urlString: String) {
        guard let remote = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              remote.scheme?.hasPrefix("http") == true else { return }
        let dest = directory.appendingPathComponent(remote.lastPathComponent)
        let item = DownloadItem(remote: remote, destination: dest)
        item.onFinish = { [weak self] in self?.refresh() }
        downloads.append(item)
    }

    func clearFinishedDownloads() {
        downloads.removeAll { $0.finished || $0.error != nil }
    }

    /// Moves the model to the Trash (recoverable).
    func delete(_ model: LocalModel) {
        try? FileManager.default.trashItem(at: model.url, resultingItemURL: nil)
        refresh()
    }
}
