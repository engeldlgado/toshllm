// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

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
            return metadata.isMoE
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


enum ResumableDownload {
    enum ResponsePlan: Equatable {
        case append(totalBytes: Int64?)
        case restart(totalBytes: Int64?)
        case alreadyComplete
        case reject
    }

    static func request(remote: URL, partialBytes: Int64) -> URLRequest {
        var request = URLRequest(url: remote)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if partialBytes > 0 {
            request.setValue("bytes=\(partialBytes)-", forHTTPHeaderField: "Range")
        }
        return request
    }

    static func responsePlan(statusCode: Int, contentRange: String?, contentLength: Int64,
                             partialBytes: Int64, expectedBytes: Int64?) -> ResponsePlan {
        if statusCode == 416, let expectedBytes, partialBytes == expectedBytes {
            return .alreadyComplete
        }
        if statusCode == 206 {
            guard let range = contentRange,
                  range.lowercased().hasPrefix("bytes \(partialBytes)-") else { return .reject }
            let total = range.split(separator: "/").last.flatMap { Int64($0) }
            return .append(totalBytes: total ?? expectedBytes)
        }
        if (200...299).contains(statusCode) {
            let total = contentLength > 0 ? contentLength : expectedBytes
            return .restart(totalBytes: total)
        }
        return .reject
    }
}

private final class DownloadSink: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?

    init(url: URL) { self.url = url }

    func size() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    func open(append: Bool) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let next = try FileHandle(forWritingTo: url)
        if append {
            try next.seekToEnd()
        } else {
            try next.truncate(atOffset: 0)
        }
        handle = next
        return Int64(try next.offset())
    }

    func append(_ data: Data) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { throw CocoaError(.fileNoSuchFile) }
        try handle.write(contentsOf: data)
        return Int64(try handle.offset())
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }
}

@MainActor
final class DownloadItem: NSObject, ObservableObject, Identifiable, URLSessionDataDelegate {
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
    private var task: URLSessionDataTask?
    private var requestedOffset: Int64 = 0
    private let sink: DownloadSink
    private let sessionConfiguration: URLSessionConfiguration
    private lazy var session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: nil)

    // Compatibility accessors used across the UI
    var finished: Bool { phase == .finished }
    var error: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    init(remote: URL, destination: URL, sessionConfiguration: URLSessionConfiguration = .default) {
        self.remote = remote
        self.destination = destination
        // The saved name, which may differ from the remote (e.g. projectors are
        // renamed to <model>.mmproj.gguf). The UI keys progress off this.
        self.fileName = destination.lastPathComponent
        self.sink = DownloadSink(url: destination.appendingPathExtension("download"))
        self.sessionConfiguration = sessionConfiguration
        super.init()
        Task { await prepare() }
    }

    /// Fetches integrity metadata, checks disk space, then starts the transfer.
    private func prepare() async {
        if let meta = await HuggingFaceAPI.fileMetadata(for: remote) {
            expectedSHA256 = meta.sha256
            expectedBytes = meta.sizeBytes
        }

        if let needed = expectedBytes {
            let values = try? destination.deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let remaining = max(0, needed - sink.size())
            if let free = values?.volumeAvailableCapacityForImportantUsage,
               free < remaining + 1_000_000_000 {
                let neededGB = Double(remaining) / 1_073_741_824
                let freeGB = Double(free) / 1_073_741_824
                phase = .failed(String(format: "Espacio insuficiente: %.1f GB libres, %.1f GB necesarios / not enough disk space", freeGB, neededGB))
                return
            }
            totalMB = Double(needed) / 1_048_576
        }

        startTask()
    }

    private func startTask() {
        requestedOffset = sink.size()
        let t = session.dataTask(with: ResumableDownload.request(remote: remote, partialBytes: requestedOffset))
        task = t
        phase = .downloading
        receivedMB = Double(requestedOffset) / 1_048_576
        if let expectedBytes, expectedBytes > 0 {
            progress = Double(requestedOffset) / Double(expectedBytes)
        }
        t.resume()
    }

    func pause() {
        guard phase == .downloading else { return }
        phase = .paused
        task?.cancel()
        sink.close()
    }

    func resume() {
        guard phase == .paused else { return }
        startTask()
    }

    func cancel() {
        phase = .failed("Cancelada / cancelled")
        task?.cancel()
        sink.close()
        session.invalidateAndCancel()
    }

    // MARK: URLSessionDataDelegate

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                                didReceive response: URLResponse,
                                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        Task { @MainActor in
            self.handle(response: response, completionHandler: completionHandler)
        }
    }

    private func handle(response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            phase = .failed("Respuesta de descarga inválida / invalid download response")
            return
        }
        let offset = requestedOffset
        let plan = ResumableDownload.responsePlan(
            statusCode: http.statusCode,
            contentRange: http.value(forHTTPHeaderField: "Content-Range"),
            contentLength: response.expectedContentLength,
            partialBytes: offset,
            expectedBytes: expectedBytes)
        do {
            let total: Int64?
            switch plan {
            case .append(let bytes):
                _ = try sink.open(append: true)
                total = bytes
            case .restart(let bytes):
                _ = try sink.open(append: false)
                total = bytes
            case .alreadyComplete:
                total = expectedBytes
            case .reject:
                completionHandler(.cancel)
                phase = .failed("El servidor rechazó la reanudación / server rejected resume request")
                return
            }
            completionHandler(plan == .alreadyComplete ? .cancel : .allow)
            if let total, total > 0 { totalMB = Double(total) / 1_048_576 }
            if plan == .alreadyComplete { finishTransfer() }
        } catch {
            completionHandler(.cancel)
            phase = .failed(error.localizedDescription)
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                                didReceive data: Data) {
        let bytes: Int64
        do { bytes = try sink.append(data) } catch {
            dataTask.cancel()
            let message = error.localizedDescription
            Task { @MainActor in self.phase = .failed(message) }
            return
        }
        Task { @MainActor in
            self.receivedMB = Double(bytes) / 1_048_576
            let expected = self.expectedBytes ?? Int64(self.totalMB * 1_048_576)
            if expected > 0 { self.progress = min(1, Double(bytes) / Double(expected)) }
        }
    }

    private func finishTransfer() {
        sink.close()
        phase = .verifying
        let expected = expectedSHA256
        let staging = sink.url
        Task {
            let ok: Bool = await Task.detached(priority: .userInitiated) {
                guard let expected else { return true }
                return FileHash.sha256(of: staging)?.lowercased() == expected.lowercased()
            }.value

            if ok {
                try? FileManager.default.removeItem(at: destination)
                do {
                    try FileManager.default.moveItem(at: staging, to: destination)
                    if let expected { ModelStore.recordDigest(expected, forFile: destination.lastPathComponent) }
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
        sink.close()
        Task { @MainActor in
            if let error {
                if (error as NSError).code == NSURLErrorCancelled || self.phase == .paused || self.error != nil {
                    return
                }
                // Keep the partial file and resume from the stable URL.
                self.phase = .paused
                AppLog.downloads.error("download paused after network error: \(error.localizedDescription)")
                return
            }
            self.finishTransfer()
        }
    }
}

@MainActor
final class ModelStore: ObservableObject {
    @Published var models: [LocalModel] = []
    @Published var downloads: [DownloadItem] = []

    /// Scan the folder up front so the list is populated as soon as the app
    /// launches, independent of which window or tab appears first.
    init() {
        // Keep Base selected for existing installs.
        if UserDefaults.standard.object(forKey: SettingsKeys.whisperModel) == nil {
            let legacy = whisperDirectory.appendingPathComponent("ggml-base.bin")
            if FileManager.default.fileExists(atPath: legacy.path) {
                UserDefaults.standard.set("base", forKey: SettingsKeys.whisperModel)
            }
        }
        refresh()
    }

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

    var whisperDirectory: URL { directory.appendingPathComponent("whisper", isDirectory: true) }

    var selectedWhisperModel: WhisperModel {
        let id = UserDefaults.standard.string(forKey: SettingsKeys.whisperModel)
            ?? WhisperModel.recommendedID
        return WhisperModel.model(id: id)
    }

    func downloadWhisperModel(_ model: WhisperModel? = nil) {
        let model = model ?? selectedWhisperModel
        guard let remote = URL(string: model.downloadURL) else { return }
        let dir = whisperDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = model.url(in: dir)
        guard !FileManager.default.fileExists(atPath: destination.path),
              !downloads.contains(where: { $0.destination == destination && $0.error == nil }) else { return }
        let item = DownloadItem(remote: remote, destination: destination)
        item.onFinish = { [weak self] in self?.objectWillChange.send() }
        downloads.append(item)
    }

    func whisperDownload(_ model: WhisperModel? = nil) -> DownloadItem? {
        let destination = (model ?? selectedWhisperModel).url(in: whisperDirectory)
        return downloads.last { $0.destination == destination && !$0.finished }
    }

    func whisperModelInstalled(_ model: WhisperModel? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (model ?? selectedWhisperModel).url(in: whisperDirectory).path)
    }

    var selectedWhisperModelURL: URL {
        selectedWhisperModel.url(in: whisperDirectory)
    }

    func retryWhisperDownload(_ item: DownloadItem) {
        let model = WhisperModel.catalog.first { $0.url(in: whisperDirectory) == item.destination }
        downloads.removeAll { $0.id == item.id }
        downloadWhisperModel(model)
    }

    var whisperVADURL: URL {
        WhisperVADModel.url(in: whisperDirectory)
    }

    var whisperVADInstalled: Bool {
        FileManager.default.fileExists(atPath: whisperVADURL.path)
    }

    func downloadWhisperVAD() {
        guard let remote = URL(string: WhisperVADModel.downloadURL) else { return }
        try? FileManager.default.createDirectory(at: whisperDirectory, withIntermediateDirectories: true)
        guard !whisperVADInstalled,
              !downloads.contains(where: { $0.destination == whisperVADURL && $0.error == nil }) else { return }
        let item = DownloadItem(remote: remote, destination: whisperVADURL)
        item.onFinish = { [weak self] in self?.objectWillChange.send() }
        downloads.append(item)
    }

    func whisperVADDownload() -> DownloadItem? {
        downloads.last { $0.destination == whisperVADURL && !$0.finished }
    }

    func retryWhisperVADDownload(_ item: DownloadItem) {
        downloads.removeAll { $0.id == item.id }
        downloadWhisperVAD()
    }

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
        ModelTraitsCache.invalidate()
        models = LocalModel.scan(in: directory)
        presentFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        ModelTraitsCache.warm(paths: models.map(\.url.path)) { [weak self] in
            self?.objectWillChange.send()
        }
    }

    /// Every name in the folder, including the projectors and drafts the model
    /// list filters out. The browse rows ask once per file on every redraw.
    @Published private(set) var presentFiles: Set<String> = []

    func isDownloaded(fileName: String) -> Bool {
        presentFiles.contains(fileName)
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
        Self.recordSource(urlString, forFile: fileName)
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

    static func recordSource(_ urlString: String, forFile fileName: String) {
        var map = UserDefaults.standard.dictionary(forKey: SettingsKeys.modelSource) as? [String: String] ?? [:]
        map[fileName] = urlString
        UserDefaults.standard.set(map, forKey: SettingsKeys.modelSource)
    }

    static func source(forFile fileName: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: SettingsKeys.modelSource) as? [String: String])?[fileName]
    }

    static func recordDigest(_ sha256: String, forFile fileName: String) {
        var map = UserDefaults.standard.dictionary(forKey: SettingsKeys.modelDigest) as? [String: String] ?? [:]
        map[fileName] = sha256.lowercased()
        UserDefaults.standard.set(map, forKey: SettingsKeys.modelDigest)
    }

    static func digest(forFile fileName: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: SettingsKeys.modelDigest) as? [String: String])?[fileName]
    }

    /// Re-downloads every shard from its recorded source.
    func update(_ model: LocalModel) {
        for part in model.partURLs {
            let name = part.lastPathComponent
            guard let source = Self.source(forFile: name) else { continue }
            download(urlString: source, preferredName: name, fetchVisionProjector: false)
        }
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

    /// Download a DFlash draft under a model-specific name so pairing is unambiguous.
    func downloadDflashDraft(repo: String, file: String, modelStem: String) {
        let name = "\(modelStem).dflash.gguf"
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path),
              !downloads.contains(where: { $0.destination.lastPathComponent == name && $0.error == nil }) else { return }
        download(urlString: "https://huggingface.co/\(repo)/resolve/main/\(file)",
                 preferredName: name, fetchVisionProjector: false)
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

    /// Moves the model and its paired files to the Trash.
    func delete(_ model: LocalModel) {
        for sibling in [ServerSettings.mmprojPath(forModel: model.url.path),
                        ServerSettings.dflashDraftPath(forModel: model.url.path),
                        ServerSettings.mtpDraftPath(forModel: model.url.path)].compactMap({ $0 }) {
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: sibling), resultingItemURL: nil)
        }
        var digests = UserDefaults.standard.dictionary(forKey: SettingsKeys.modelDigest) as? [String: String] ?? [:]
        for url in model.partURLs {
            digests[url.lastPathComponent] = nil
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        UserDefaults.standard.set(digests, forKey: SettingsKeys.modelDigest)
        refresh()
    }
}
