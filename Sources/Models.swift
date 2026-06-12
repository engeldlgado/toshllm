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
    let id = UUID()
    let fileName: String
    let destination: URL
    @Published var progress: Double = 0
    @Published var receivedMB: Double = 0
    @Published var totalMB: Double = 0
    @Published var finished = false
    @Published var error: String?

    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    var onFinish: (() -> Void)?

    init(remote: URL, destination: URL) {
        self.fileName = remote.lastPathComponent
        self.destination = destination
        super.init()
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        self.task = session.downloadTask(with: remote)
        self.task?.resume()
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
        Task { @MainActor in self.error = "Cancelada" }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let p = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        let rec = Double(totalBytesWritten) / 1_048_576
        let tot = Double(totalBytesExpectedToWrite) / 1_048_576
        Task { @MainActor in
            self.progress = p
            self.receivedMB = rec
            self.totalMB = tot
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        let dest = destination
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            Task { @MainActor in
                self.finished = true
                self.progress = 1
                self.onFinish?()
            }
        } catch {
            let msg = error.localizedDescription
            Task { @MainActor in self.error = msg }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        let msg = error.localizedDescription
        Task { @MainActor in self.error = msg }
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
