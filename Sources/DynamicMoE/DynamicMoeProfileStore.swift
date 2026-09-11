// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

enum DynamicMoeProfileStore {
    private static let directoryName = "dynamic-moe"

    static var directory: URL {
        let url = AppSupport.directory.appending(path: directoryName, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func modelFingerprint(path: String) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let identity = "\(url.path)|\(size)|\(modified.timeIntervalSince1970)|v1"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func hotMapURL(modelPath: String) -> URL? {
        guard let fingerprint = modelFingerprint(path: modelPath) else { return nil }
        return directory.appending(path: "\(fingerprint).map")
    }

    static func load(modelPath: String, gpu: GPUDevice?) -> DynamicMoeOptimizationProfile? {
        guard let gpu, let fingerprint = modelFingerprint(path: modelPath) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: profileURL(fingerprint: fingerprint, gpu: gpu)),
              let profile = try? decoder.decode(DynamicMoeOptimizationProfile.self, from: data),
              profile.version == DynamicMoeOptimizationProfile.currentVersion,
              profile.modelFingerprint == fingerprint,
              profile.gpuName == gpu.name,
              profile.gpuVRAMMB == gpu.vramMB else { return nil }
        if let path = profile.hotMapPath,
           !FileManager.default.fileExists(atPath: path) { return nil }
        return profile
    }

    static func save(_ profile: DynamicMoeOptimizationProfile, gpu: GPUDevice) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(profile).write(
            to: profileURL(fingerprint: profile.modelFingerprint, gpu: gpu),
            options: .atomic)
    }

    private static func profileURL(fingerprint: String, gpu: GPUDevice) -> URL {
        let gpuIdentity = "\(gpu.name)|\(gpu.vramMB)"
        let gpuHash = SHA256.hash(data: Data(gpuIdentity.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appending(path: "\(fingerprint)-\(gpuHash).json")
    }
}
