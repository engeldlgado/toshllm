import Foundation
import CryptoKit
import os

// MARK: - Settings keys (single source of truth)

/// Every persisted setting key lives here. Views, `ServerSettings.fromDefaults`
/// and `ProfileStore` all reference these constants, so a typo is a compile
/// error instead of a silent bug.
enum SettingsKeys {
    static let language = "lang"
    static let serverBinary = "serverBinary"
    static let modelPath = "modelPath"
    static let modelsDir = "modelsDir"
    /// Persisted (model, projector) pairs that failed to load, so a bad mmproj
    /// isn't auto-attached again.
    static let incompatibleMmproj = "incompatibleMmproj"
    static let port = "port"
    static let ngl = "ngl"
    static let ncmoe = "ncmoe"
    /// Last user-set ncmoe per model file, restored when that model is re-selected.
    static let ncmoeByModel = "ncmoeByModel"
    static let ctx = "ctx"
    static let threads = "threads"
    static let flashAttn = "flashAttn"
    static let noMmap = "noMmap"
    static let jinja = "jinja"
    static let concurrencyDisable = "concurrencyDisable"
    static let vramReserve = "vramReserve"
    static let gpuIndex = "gpuIndex"
    /// Comma-separated physical GPU indices to split across (2+ entries).
    static let gpuList = "gpuList"
    static let extraArgs = "extraArgs"
    static let embeddings = "embeddings"
    static let cacheTypeK = "cacheTypeK"
    static let cacheTypeV = "cacheTypeV"
    static let mlock = "mlock"
    static let cacheRAM = "cacheRAM"
    static let parallelSlots = "parallelSlots"
    static let reasoningInline = "reasoningInline"
    static let specMTP = "specMTP"
    static let faAmd = "faAmd"
    static let persistCache = "persistCache"
    static let multiGPU = "multiGPU"
    static let multiGPUCount = "multiGPUCount"
    static let forcePrivateBuffers = "forcePrivateBuffers"
    static let cacheReuse = "cacheReuse"
    static let loadVision = "loadVision"
    static let apiKeyEnabled = "apiKeyEnabled"
    static let localNetworkDiscovery = "localNetworkDiscovery"
    static let menuBarIcon = "menuBarIcon"
    /// Where to surface per-GPU VRAM in the menu bar: "off" | "icon" | "panel".
    static let menuBarGPU = "menuBarGPU"
    static let autoStart = "autoStart"
    static let chatTemp = "chatTemp"
    static let chatMaxTokens = "chatMaxTokens"
    static let chatSystem = "chatSystem"
    static let chatThinking = "chatThinking"
    static let chatAutoCompact = "chatAutoCompact"
    static let smoothTyping = "smoothTyping"
    static let onboardingDone = "onboardingDone"

    // Benchmark workload sizes (llama-bench -p / -n)
    static let benchPP = "benchPP"
    static let benchTG = "benchTG"

    // Image generation (text-to-image)
    static let imagenPrompt = "imagenPrompt"
    static let imagenAspect = "imagenAspect"
    static let imagenBaseSize = "imagenBaseSize"
    static let imagenSteps = "imagenSteps"
    static let imagenSeed = "imagenSeed"
    static let imagenFormat = "imagenFormat"
    static let imagenOffloadCPU = "imagenOffloadCPU"
    static let imagenGPU = "imagenGPU"
    static let imagenModel = "imagenModel"
    static let imagenCustomModel = "imagenCustomModel"
    static let imagenCustomVAE = "imagenCustomVAE"
    static let imagenCustomCfg = "imagenCustomCfg"
    static let imagenInitImage = "imagenInitImage"
    static let imagenStrength = "imagenStrength"
    /// Extra parallel generation instances (JSON: [ImageInstanceConfig]).
    static let imagenInstances = "imagenInstances"

    /// Tunable option keys (engine / GPU / inference / chat). Resetting clears these
    /// so `@AppStorage` falls back to its declared defaults. The models folder, the
    /// selected model and onboarding state are deliberately NOT included, so a reset
    /// never hides or deletes downloaded models. Profiles and the Keychain API key
    /// live outside UserDefaults and are untouched.
    static let resettableOptionKeys = [
        serverBinary, port, ngl, ncmoe, ctx, threads, flashAttn, noMmap, jinja, concurrencyDisable,
        vramReserve, gpuIndex, gpuList, extraArgs, embeddings, cacheTypeK, cacheTypeV, mlock, cacheRAM,
        parallelSlots, reasoningInline, specMTP, faAmd, persistCache, multiGPU, multiGPUCount,
        forcePrivateBuffers, cacheReuse, apiKeyEnabled, localNetworkDiscovery,
        menuBarIcon, menuBarGPU, autoStart, chatTemp, chatMaxTokens, chatSystem, chatThinking,
        chatAutoCompact, smoothTyping,
        imagenAspect, imagenBaseSize, imagenSteps, imagenFormat, imagenOffloadCPU, imagenGPU,
    ]

    /// Clears every tunable option so they revert to defaults, keeping models intact.
    static func resetOptionsToDefaults() {
        let defaults = UserDefaults.standard
        for key in resettableOptionKeys { defaults.removeObject(forKey: key) }
    }
}

// MARK: - Logging

enum AppLog {
    private static let subsystem = "dev.engel.toshllm"
    static let server = Logger(subsystem: subsystem, category: "server")
    static let downloads = Logger(subsystem: subsystem, category: "downloads")
    static let chat = Logger(subsystem: subsystem, category: "chat")
    static let app = Logger(subsystem: subsystem, category: "app")
}

/// App support directory for persistent state (logs, lockfiles, chats).
enum AppSupport {
    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ToshLLM")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Rotating plain-text log for the engine output, so crashes can be diagnosed
/// after the fact and exported from Settings.
/// Per-session log files kept under Application Support/logs, named with the start
/// timestamp (e.g. `server-2026-06-19_15-30-45.log`). Each server run writes its own
/// file, so a Mac crash leaves the session's log intact for later inspection. Files
/// older than `retentionDays` are pruned automatically so they don't pile up.
final class RotatingFileLog: @unchecked Sendable {
    private let dir: URL
    private let prefix: String
    private let maxBytes: UInt64
    private let retentionDays: Int
    private let queue = DispatchQueue(label: "toshllm.filelog")
    private var handle: FileHandle?
    private var currentURL: URL

    init(name: String, maxBytes: UInt64 = 10 * 1024 * 1024, retentionDays: Int = 3) {
        self.prefix = (name as NSString).deletingPathExtension   // "server.log" -> "server"
        self.maxBytes = maxBytes
        self.retentionDays = retentionDays
        self.dir = AppSupport.directory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.currentURL = dir.appendingPathComponent("\(prefix).log")   // until a session starts
        queue.async { [self] in cleanup() }   // prune stale logs at launch too
    }

    var fileURL: URL { queue.sync { currentURL } }
    var directory: URL { dir }

    /// Begins a new timestamped per-session file and prunes files past the retention
    /// window. Call once per server start so each run is isolated and crash-safe.
    func startSession() {
        queue.async { [self] in
            try? handle?.close(); handle = nil
            let stamp = Self.stampFormatter.string(from: Date())
            currentURL = dir.appendingPathComponent("\(prefix)-\(stamp).log")
            cleanup()
        }
    }

    func append(_ text: String) {
        queue.async { [self] in
            if handle == nil {
                if !FileManager.default.fileExists(atPath: currentURL.path) {
                    FileManager.default.createFile(atPath: currentURL.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: currentURL)
                _ = try? handle?.seekToEnd()
            }
            guard let handle else { return }
            try? handle.write(contentsOf: Data(text.utf8))
            // Flush to disk so a machine freeze / kernel panic (e.g. an AMD MoE GPU
            // deadlock) still leaves every line written so far — not just what the
            // OS happened to flush. A process crash was already safe; this covers
            // the harder case the logs exist for.
            try? handle.synchronize()
            if let size = try? handle.offset(), size > maxBytes {
                rotate()
            }
        }
    }

    /// Within a single session, cap growth: move the current file aside once and
    /// keep writing, so one runaway run can't fill the disk.
    private func rotate() {
        try? handle?.close()
        handle = nil
        let prev = currentURL.deletingPathExtension().appendingPathExtension("prev.log")
        try? FileManager.default.removeItem(at: prev)
        try? FileManager.default.moveItem(at: currentURL, to: prev)
    }

    /// Deletes session log files older than the retention window.
    private func cleanup() {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for f in files where f.lastPathComponent.hasPrefix(prefix) && f.pathExtension == "log" {
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mod, mod < cutoff { try? fm.removeItem(at: f) }
        }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// Single accumulating benchmark history file (`benchmarks.txt`), pruned to the
/// last `retentionDays` of runs so it stays a useful, shareable record without
/// growing forever. Each run's header carries an ISO date used for pruning.
final class BenchmarkLog: @unchecked Sendable {
    let url: URL
    let directory: URL
    private let queue = DispatchQueue(label: "toshllm.benchlog")
    private let retentionDays: Int
    static let runMarker = "=== ToshLLM benchmark · "

    init(retentionDays: Int = 3) {
        self.retentionDays = retentionDays
        directory = AppSupport.directory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("benchmarks.txt")
        prune()
    }

    func append(_ text: String) {
        queue.async { [self] in
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(text.utf8))
            try? h.synchronize()   // survive a machine freeze mid-run
            try? h.close()
        }
    }

    /// Rewrite the file keeping only runs newer than the retention window, keyed
    /// off the ISO date in each run's header line.
    func prune() {
        queue.async { [self] in
            guard let content = try? String(contentsOf: url, encoding: .utf8),
                  content.contains(Self.runMarker) else { return }
            let iso = ISO8601DateFormatter()
            let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
            var kept = ""
            for block in content.components(separatedBy: Self.runMarker).dropFirst() {
                guard let end = block.range(of: " ===") else { continue }
                let date = iso.date(from: String(block[block.startIndex..<end.lowerBound]))
                // Keep recent runs; keep unparseable ones to avoid losing data.
                if date == nil || date! >= cutoff { kept += Self.runMarker + block }
            }
            try? kept.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Shell-words argument parsing

enum ShellWords {
    /// Splits a command-line string honoring single/double quotes, so
    /// `--system "hello world"` becomes two arguments instead of three.
    static func split(_ input: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character? = nil
        var hasContent = false

        for ch in input {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                hasContent = true
            } else if ch == " " || ch == "\t" {
                if hasContent || !current.isEmpty {
                    result.append(current)
                    current = ""
                    hasContent = false
                }
            } else {
                current.append(ch)
            }
        }
        if hasContent || !current.isEmpty { result.append(current) }
        return result
    }
}

// MARK: - Engine PID lockfile

/// Tracks the PIDs of the engines we spawned (one per running server), so a later
/// launch can reap orphans precisely (verifying each PID still points at one of our
/// binaries) instead of pattern-killing by path.
enum EngineLock {
    private static var url: URL { AppSupport.directory.appendingPathComponent("engine.pid") }

    private static func read() -> [Int32] {
        (try? String(contentsOf: url, encoding: .utf8))?
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) } ?? []
    }

    private static func save(_ pids: [Int32]) {
        if pids.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? pids.map(String.init).joined(separator: "\n")
                .write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func add(pid: Int32) {
        var pids = read()
        if !pids.contains(pid) { pids.append(pid) }
        save(pids)
    }

    static func remove(pid: Int32) {
        save(read().filter { $0 != pid })
    }

    /// Kills any recorded PID still alive whose executable lives inside one of our app
    /// bundles, then clears the file. Returns whether at least one orphan was reaped.
    @discardableResult
    static func reapOrphans() -> Bool {
        var reaped = false
        for pid in read() {
            guard kill(pid, 0) == 0 else { continue }   // not running

            var buffer = [CChar](repeating: 0, count: 4096)
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let path = String(cString: buffer)

            // Only processes from a ToshLLM bundle are ours to kill.
            guard path.contains("ToshLLM.app/Contents/Resources/bin") else { continue }

            AppLog.app.warning("Reaping orphaned engine pid \(pid) at \(path)")
            kill(pid, SIGTERM)
            usleep(500_000)
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            reaped = true
        }
        save([])
        return reaped
    }
}

// MARK: - File hashing

enum FileHash {
    /// Streaming SHA-256 suitable for multi-gigabyte files.
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Keychain (API key storage)

enum Keychain {
    private static let service = "dev.engel.toshllm"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Returns the stored API key, generating one on first use.
    static func apiKey() -> String {
        if let existing = get("api-key") { return existing }
        let fresh = (0..<32).map { _ in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()! }
        let key = String(fresh)
        set(key, account: "api-key")
        return key
    }
}
