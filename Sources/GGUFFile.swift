// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct GGUFFileEntry: Sendable {
    let path: String
    let sizeBytes: Int64
}

struct GGUFModelFiles: Sendable {
    let primaryPath: String
    let sizeBytes: Int64
    let paths: [String]
}

enum GGUFFile {
    private struct Shard {
        let index: Int
        let total: Int
        let groupKey: String
    }

    private static let shardRegex = try! NSRegularExpression(
        pattern: #"-(\d{5})-of-(\d{5})(?=\.gguf$)"#,
        options: [.caseInsensitive]
    )

    static func models(from entries: [GGUFFileEntry]) -> [GGUFModelFiles] {
        var singles: [GGUFModelFiles] = []
        var shards: [String: [(entry: GGUFFileEntry, shard: Shard)]] = [:]

        for entry in entries where isModelFile(entry.path) {
            guard let shard = shardInfo(entry.path) else {
                singles.append(GGUFModelFiles(
                    primaryPath: entry.path,
                    sizeBytes: entry.sizeBytes,
                    paths: [entry.path]
                ))
                continue
            }
            shards[shard.groupKey, default: []].append((entry, shard))
        }

        for group in shards.values {
            guard let first = group.first,
                  group.count == first.shard.total,
                  Set(group.map { $0.shard.index }) == Set(1...first.shard.total),
                  group.allSatisfy({ $0.shard.total == first.shard.total }),
                  let primary = group.first(where: { $0.shard.index == 1 }) else { continue }
            let ordered = group.sorted { $0.shard.index < $1.shard.index }
            singles.append(GGUFModelFiles(
                primaryPath: primary.entry.path,
                sizeBytes: ordered.reduce(0) { $0 + $1.entry.sizeBytes },
                paths: ordered.map { $0.entry.path }
            ))
        }

        return singles
    }

    /// Total bytes of a model, including every sibling shard when `path` is the
    /// first `-00001-of-N` file. Falls back to the single file for normal GGUFs.
    static func totalSize(at path: String) -> UInt64? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if shardInfo(url.path) == nil {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
            return size
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(),
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) else { return nil }
        let entries = files.compactMap { file -> GGUFFileEntry? in
            guard file.pathExtension.lowercased() == "gguf",
                  let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize else { return nil }
            return GGUFFileEntry(path: file.standardizedFileURL.path, sizeBytes: Int64(size))
        }
        if let model = models(from: entries).first(where: {
            $0.primaryPath == url.path || $0.paths.contains(url.path)
        }) {
            return UInt64(max(0, model.sizeBytes))
        }
        return nil
    }

    static func isProjector(_ path: String) -> Bool {
        path.lowercased().contains("mmproj")
    }

    /// A DFlash or MTP speculative-decoding draft.
    static func isDraft(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return name.contains("dflash") || name.hasPrefix("mtp-") || name.hasSuffix(".mtp.gguf")
    }

    private static func isModelFile(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.lowercased() == "gguf"
            && !isProjector(path) && !isDraft(path)
    }

    private static func shardInfo(_ path: String) -> Shard? {
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        guard let match = shardRegex.firstMatch(in: path, range: range),
              let matchRange = Range(match.range, in: path),
              let indexRange = Range(match.range(at: 1), in: path),
              let totalRange = Range(match.range(at: 2), in: path),
              let index = Int(path[indexRange]),
              let total = Int(path[totalRange]), total > 1 else { return nil }
        var groupKey = path
        groupKey.removeSubrange(matchRange)
        return Shard(index: index, total: total, groupKey: groupKey)
    }
}
