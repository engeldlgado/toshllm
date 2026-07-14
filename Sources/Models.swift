import Foundation

struct LocalModel: Identifiable, Hashable {
    let url: URL
    let name: String
    let sizeBytes: Int64
    let partURLs: [URL]
    var id: String { url.path }
    var sizeGB: String { String(format: "%.1f GB", Double(sizeBytes) / 1_073_741_824) }
    var isMoE: Bool {
        if let metadata = GGUFMetadataCache.metadata(at: url.path) {
            return (metadata.uint32(forSuffix: "expert_count") ?? 0) > 0
        }
        return ModelName.looksMoE(name)
    }

    init(url: URL, name: String, sizeBytes: Int64, partURLs: [URL]? = nil) {
        self.url = url
        self.name = name
        self.sizeBytes = sizeBytes
        self.partURLs = partURLs ?? [url]
    }

    /// Top-level `.gguf` scan, excluding mmproj files. Shared by `ModelStore.refresh()`
    /// and the router preset generator, which has no `ModelStore` instance to call.
    nonisolated static func scan(in directory: URL) -> [LocalModel] {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let entries = files.map { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return GGUFFileEntry(path: url.path, sizeBytes: size)
        }
        return GGUFFile.models(from: entries)
            .map { group in
                let url = URL(fileURLWithPath: group.primaryPath)
                return LocalModel(
                    url: url,
                    name: url.lastPathComponent,
                    sizeBytes: group.sizeBytes,
                    partURLs: group.paths.map { URL(fileURLWithPath: $0) }
                )
            }
            .sorted { $0.sizeBytes < $1.sizeBytes }
    }
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
        // The saved name, which may differ from the remote (e.g. projectors are
        // renamed to <model>.mmproj.gguf). The UI keys progress off this.
        self.fileName = destination.lastPathComponent
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

    /// Scan the folder up front so the list is populated as soon as the app
    /// launches, independent of which window or tab appears first.
    init() { refresh() }

    /// The fixed default location, used when the user hasn't picked a custom folder.
    nonisolated static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("models")

    /// Where models are scanned, downloaded and deleted. Defaults to `~/models`,
    /// overridable from Settings (persisted in `SettingsKeys.modelsDir`).
    var directory: URL {
        let custom = UserDefaults.standard.string(forKey: SettingsKeys.modelsDir) ?? ""
        return custom.isEmpty ? Self.defaultDirectory : URL(fileURLWithPath: custom, isDirectory: true)
    }

    /// Where image-generation components (diffusion model, VAE, text encoder) live.
    /// A subfolder so they never appear in the LLM model list, which scans only the
    /// top level.
    var imagenDirectory: URL { directory.appendingPathComponent("imagen", isDirectory: true) }

    /// Download an image-gen component into the `imagen/` subfolder under its fixed
    /// name. Reuses the resumable transfer used for models; skips the projector
    /// auto-fetch (components aren't vision models).
    func downloadImageComponent(urlString: String, fileName: String) {
        guard let remote = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              remote.scheme?.hasPrefix("http") == true else { return }
        let dir = imagenDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: dest.path),
              !downloads.contains(where: { $0.destination == dest && $0.error == nil }) else { return }
        let item = DownloadItem(remote: remote, destination: dest)
        item.onFinish = { [weak self] in self?.objectWillChange.send() }
        downloads.append(item)
    }

    /// The in-progress (or failed) download for an image component, matched inside
    /// the `imagen/` subfolder so it can show live progress on its card.
    func imageDownload(fileName: String) -> DownloadItem? {
        downloads.last {
            $0.destination.lastPathComponent == fileName
                && $0.destination.deletingLastPathComponent().lastPathComponent == "imagen"
                && !$0.finished
        }
    }

    func refresh() {
        models = LocalModel.scan(in: directory)
    }

    func isDownloaded(fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path)
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

    /// Downloads `urlString` into the models folder. `preferredName`, when set,
    /// overrides the saved filename — used for multimodal projectors, which ship
    /// under generic, collision-prone names (e.g. `mmproj-F16.gguf`, identical
    /// across repos). Saving them as `<model>.mmproj.gguf` makes the model→
    /// projector pairing deterministic and avoids cross-repo filename clashes.
    func download(urlString: String, preferredName: String? = nil,
                  fetchVisionProjector: Bool = true) {
        guard let remote = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              remote.scheme?.hasPrefix("http") == true else { return }
        let fileName = preferredName ?? remote.lastPathComponent
        let dest = directory.appendingPathComponent(fileName)
        let item = DownloadItem(remote: remote, destination: dest)
        item.onFinish = { [weak self] in self?.refresh() }
        downloads.append(item)
        // Vision models ship a separate projector (mmproj). When downloading the
        // model, fetch its sibling mmproj too so vision works without manual steps.
        if fetchVisionProjector && !fileName.lowercased().contains("mmproj") {
            Task { await autoFetchProjector(for: remote) }
        }
    }

    /// If `modelURL` points at a Hugging Face GGUF whose repo also contains an
    /// `*mmproj*.gguf` (multimodal projector), download that projector to the same
    /// folder. No-op for non-HF URLs, non-vision repos, or when it's already local.
    func autoFetchProjector(for modelURL: URL) async {
        guard modelURL.host?.contains("huggingface.co") == true else { return }
        let comps = modelURL.pathComponents   // ["/", owner, repo, "resolve", branch, file…]
        guard let r = comps.firstIndex(of: "resolve"), r >= 2, comps.count > r + 1 else { return }
        let repo = comps[r - 2] + "/" + comps[r - 1]
        let branch = comps[r + 1]
        guard let api = URL(string: "https://huggingface.co/api/models/\(repo)/tree/\(branch)"),
              let (data, _) = try? await URLSession.shared.data(from: api),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        let projectors = entries.compactMap { $0["path"] as? String }
            .filter { $0.lowercased().contains("mmproj") && $0.lowercased().hasSuffix(".gguf") }
        // Pick the best projector for Metal-on-AMD. The vision encoder runs partly
        // on CPU here, so precision barely matters: prefer the smallest sane one —
        // q8 if present, else f16 (avoid bf16, which Metal ops don't like, and f32,
        // which is twice the size for no gain). Fall back to whatever's there.
        func has(_ s: String, _ k: String) -> Bool { s.lowercased().contains(k) }
        let proj = projectors.first { has($0, "q8") }
            ?? projectors.first { has($0, "f16") && !has($0, "bf16") }
            ?? projectors.first { !has($0, "f32") && !has($0, "bf16") }
            ?? projectors.first
        guard let proj else { return }
        // Save under a model-specific name so pairing is unambiguous and projectors
        // from different repos (all named e.g. mmproj-F16.gguf) never collide.
        let modelStem = modelURL.deletingPathExtension().lastPathComponent
        let projName = "\(modelStem).mmproj.gguf"
        let projDest = directory.appendingPathComponent(projName)
        guard !FileManager.default.fileExists(atPath: projDest.path),
              !downloads.contains(where: { $0.destination == projDest && $0.error == nil }) else { return }
        download(urlString: "https://huggingface.co/\(repo)/resolve/\(branch)/\(proj)", preferredName: projName)
    }

    func clearFinishedDownloads() {
        downloads.removeAll { $0.finished || $0.error != nil }
    }

    /// For a local model that is a known catalog vision model whose multimodal
    /// projector isn't present in the folder, returns the catalog entry so the UI
    /// can offer to download the missing mmproj.
    func missingVisionProjector(for model: LocalModel) -> CatalogModel? {
        guard let cat = Catalog.models.first(where: { $0.fileName == model.name }), cat.isVision else { return nil }
        guard ServerSettings.mmprojPath(forModel: model.url.path) == nil else { return nil }   // already paired
        return cat
    }

    /// Download the multimodal projector for a catalog vision model into the folder.
    func downloadProjector(for cat: CatalogModel) {
        guard let url = URL(string: cat.urlString) else { return }
        Task { await autoFetchProjector(for: url) }
    }

    /// Retry a failed download by replacing it with a fresh transfer (new session
    /// + re-fetched metadata), reusing the same source URL.
    func retry(_ item: DownloadItem) {
        downloads.removeAll { $0.id == item.id }
        // Preserve the saved name when it was renamed (e.g. projectors), so the
        // retry lands on the same destination instead of the generic remote name.
        let remoteName = item.remote.lastPathComponent
        let preferred = item.destination.lastPathComponent == remoteName ? nil : item.destination.lastPathComponent
        download(urlString: item.remote.absoluteString, preferredName: preferred)
    }

    /// Moves the model to the Trash (recoverable). For a vision model, its paired
    /// multimodal projector (mmproj) is removed too, so no orphan file is left.
    func delete(_ model: LocalModel) {
        if let proj = ServerSettings.mmprojPath(forModel: model.url.path) {
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: proj), resultingItemURL: nil)
        }
        for url in model.partURLs {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        refresh()
    }
}
