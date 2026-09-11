// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct HFFileMetadata {
    let sha256: String?
    let sizeBytes: Int64?
}

enum HuggingFaceAPI {
    /// repo + file path -> sha256/size from the Hugging Face tree API (LFS oid).
    static func fileMetadata(for url: URL) async -> HFFileMetadata? {
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
        return HFFileMetadata(sha256: (entry["lfs"] as? [String: Any])?["oid"] as? String,
                              sizeBytes: (entry["size"] as? NSNumber)?.int64Value)
    }
}

enum ModelUpdateState: Equatable {
    case upToDate
    case available(sizeBytes: Int64?)
    /// No recorded source, no published checksum, or same size with no local digest.
    case unknown

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// Compares each local model against the file its recorded download URL points at.
@MainActor
final class ModelUpdateChecker: ObservableObject {
    @Published private(set) var remote: [String: HFFileMetadata] = [:]
    @Published private(set) var checking = false
    private var lastCheck: Date?

    /// Compared on read, so a finished re-download clears the flag without another lookup.
    func state(for model: LocalModel) -> ModelUpdateState {
        guard let meta = remote[model.name] else { return .unknown }
        // A split model sums every shard, which no single remote entry matches.
        let localSize = model.partURLs.count == 1 ? model.sizeBytes : nil
        return Self.compare(localDigest: ModelStore.digest(forFile: model.name),
                            localSize: localSize, remote: meta)
    }

    func check(_ models: [LocalModel]) async {
        guard !checking else { return }
        checking = true
        var found: [String: HFFileMetadata] = [:]
        for model in models {
            guard let source = ModelStore.source(forFile: model.name),
                  let url = URL(string: source),
                  let meta = await HuggingFaceAPI.fileMetadata(for: url) else { continue }
            found[model.name] = meta
        }
        remote = found
        lastCheck = Date()
        checking = false
    }

    func checkIfStale(_ models: [LocalModel], interval: TimeInterval = 6 * 3600) async {
        if let lastCheck, Date().timeIntervalSince(lastCheck) < interval { return }
        await check(models)
    }

    /// Without a recorded digest only a size change distinguishes a re-upload.
    static func compare(localDigest: String?, localSize: Int64?, remote: HFFileMetadata) -> ModelUpdateState {
        if let localDigest, let remoteDigest = remote.sha256 {
            return localDigest.caseInsensitiveCompare(remoteDigest) == .orderedSame
                ? .upToDate : .available(sizeBytes: remote.sizeBytes)
        }
        guard let localSize, let remoteSize = remote.sizeBytes else { return .unknown }
        return remoteSize == localSize ? .unknown : .available(sizeBytes: remoteSize)
    }
}
