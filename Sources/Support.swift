import Foundation
import CryptoKit
import os

// MARK: - Settings keys (single source of truth)

/// Every persisted setting key lives here. Views, `ServerSettings.fromDefaults`
/// and `ProfileStore` all reference these constants, so a typo is a compile
/// error instead of a silent bug.
enum SettingsKeys {
    static let serverBinary = "serverBinary"
    static let modelPath = "modelPath"
    static let port = "port"
    static let ngl = "ngl"
    static let ncmoe = "ncmoe"
    static let ctx = "ctx"
    static let threads = "threads"
    static let flashAttn = "flashAttn"
    static let noMmap = "noMmap"
    static let jinja = "jinja"
    static let concurrencyDisable = "concurrencyDisable"
    static let vramReserve = "vramReserve"
    static let gpuIndex = "gpuIndex"
    static let extraArgs = "extraArgs"
    static let cacheTypeK = "cacheTypeK"
    static let cacheTypeV = "cacheTypeV"
    static let mlock = "mlock"
    static let specMTP = "specMTP"
    static let apiKeyEnabled = "apiKeyEnabled"
    static let menuBarIcon = "menuBarIcon"
    static let autoStart = "autoStart"
    static let chatTemp = "chatTemp"
    static let chatMaxTokens = "chatMaxTokens"
    static let chatSystem = "chatSystem"
    static let chatThinking = "chatThinking"
    static let onboardingDone = "onboardingDone"
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
final class RotatingFileLog: @unchecked Sendable {
    private let url: URL
    private let maxBytes: UInt64
    private let queue = DispatchQueue(label: "toshllm.filelog")
    private var handle: FileHandle?

    init(name: String, maxBytes: UInt64 = 5 * 1024 * 1024) {
        self.url = AppSupport.directory.appendingPathComponent(name)
        self.maxBytes = maxBytes
    }

    var fileURL: URL { url }

    func append(_ text: String) {
        queue.async { [self] in
            if handle == nil {
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: url)
                try? handle?.seekToEnd()
            }
            guard let handle else { return }
            try? handle.write(contentsOf: Data(text.utf8))
            if let size = try? handle.offset(), size > maxBytes {
                rotate()
            }
        }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let old = url.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
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

/// Tracks the PID of the engine we spawned, so a later launch can reap an
/// orphan precisely (verifying the PID still points at one of our binaries)
/// instead of pattern-killing by path.
enum EngineLock {
    private static var url: URL { AppSupport.directory.appendingPathComponent("engine.pid") }

    static func write(pid: Int32) {
        try? String(pid).write(to: url, atomically: true, encoding: .utf8)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Kills the recorded PID if it is still alive and its executable lives
    /// inside one of our app bundles. Returns whether an orphan was reaped.
    @discardableResult
    static func reapOrphan() -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        defer { clear() }

        guard kill(pid, 0) == 0 else { return false }   // not running

        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let path = String(cString: buffer)

        // Only processes from a ToshLLM bundle are ours to kill.
        guard path.contains("ToshLLM.app/Contents/Resources/bin") else { return false }

        AppLog.app.warning("Reaping orphaned engine pid \(pid) at \(path)")
        kill(pid, SIGTERM)
        usleep(500_000)
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        return true
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
