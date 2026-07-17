import XCTest
@testable import ToshLLM

final class ModelDetectionTests: XCTestCase {
    func testGGUFMetadataIsTheMoESourceOfTruth() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let renamedMoE = dir.appendingPathComponent("renamed-model.gguf")
        try writeGGUF(to: renamedMoE, uint32: ["qwen35moe.expert_count": 256])
        let moe = LocalModel(url: renamedMoE, name: renamedMoE.lastPathComponent,
                             sizeBytes: Int64(try fileSize(renamedMoE)))
        XCTAssertTrue(moe.isMoE)
        XCTAssertTrue(ServerSettings.modelIsMoE(at: renamedMoE.path))

        let misleadingDense = dir.appendingPathComponent("definitely-moe-A3.5B.gguf")
        try writeGGUF(to: misleadingDense, uint32: ["llama.block_count": 24])
        let dense = LocalModel(url: misleadingDense, name: misleadingDense.lastPathComponent,
                               sizeBytes: Int64(try fileSize(misleadingDense)))
        XCTAssertFalse(dense.isMoE, "A valid dense GGUF must override a misleading filename")

        let unreadable = dir.appendingPathComponent("fallback-A3.5B.gguf")
        try Data().write(to: unreadable)
        let fallback = LocalModel(url: unreadable, name: unreadable.lastPathComponent, sizeBytes: 0)
        XCTAssertTrue(fallback.isMoE, "Filename detection remains a fallback for unreadable files")
    }

    func testBenchmarkFamilyTreatsValidArchitectureWithoutExpertsAsDense() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let denseURL = dir.appendingPathComponent("qwen-dense.gguf")
        try writeGGUF(to: denseURL, strings: ["general.architecture": "qwen35"])
        let dense = LocalModel(url: denseURL, name: denseURL.lastPathComponent,
                               sizeBytes: Int64(try fileSize(denseURL)))
        XCTAssertEqual(BenchmarkModelFamilyClassifier.family(for: dense), "dense")

        let moeURL = dir.appendingPathComponent("renamed.gguf")
        try writeGGUF(to: moeURL, strings: ["general.architecture": "qwen35moe"],
                      uint32: ["qwen35moe.expert_count": 256])
        let moe = LocalModel(url: moeURL, name: moeURL.lastPathComponent,
                             sizeBytes: Int64(try fileSize(moeURL)))
        XCTAssertEqual(BenchmarkModelFamilyClassifier.family(for: moe), "moe")
    }

    func testBenchmarkGPUArchitectureUsesTheReportedDeviceName() {
        XCTAssertEqual(GPUArchitectureClassifier.architecture(for: "AMD Radeon RX 9070 XT"), "RDNA 4")
        XCTAssertEqual(GPUArchitectureClassifier.architecture(for: "AMD Radeon RX 6700 XT"), "RDNA 2")
        XCTAssertEqual(GPUArchitectureClassifier.architecture(for: "AMD Radeon RX 5700 XT"), "RDNA 1")
        XCTAssertEqual(GPUArchitectureClassifier.architecture(for: "AMD Radeon RX 580"), "GCN / Vega")
        XCTAssertEqual(GPUArchitectureClassifier.architecture(for: "AMD Radeon Pro W6800X"), "RDNA 2")
        XCTAssertEqual(GPUArchitectureClassifier.architecture(for: "AMD Radeon VII"), "GCN / Vega")
        XCTAssertEqual(GPUArchitectureClassifier.architecture(for: "AMD Instinct MI325X"), "CDNA 3")
        XCTAssertEqual(GPUArchitectureClassifier.architecture(for: "AMD Instinct MI355X"), "CDNA 4")
        XCTAssertEqual(GPUArchitectureClassifier.architecture(for: "AMD Radeon 890M"), "RDNA 3.5")
        XCTAssertEqual(GPUArchitectureClassifier.architecture(for: "NVIDIA GeForce RTX 5090"), "Blackwell")
        XCTAssertEqual(GPUArchitectureClassifier.architecture(for: "NVIDIA GeForce RTX 4090"), "Ada Lovelace")
        XCTAssertEqual(GPUArchitectureClassifier.architecture(for: "NVIDIA RTX 6000 Ada Generation"), "Ada Lovelace")
        XCTAssertEqual(GPUArchitectureClassifier.architecture(for: "NVIDIA RTX A6000"), "Ampere")
        XCTAssertEqual(GPUArchitectureClassifier.architecture(for: "NVIDIA Quadro RTX 6000"), "Turing")
        XCTAssertEqual(GPUArchitectureClassifier.architecture(for: "NVIDIA A100-SXM4-80GB"), "Ampere")
        XCTAssertEqual(GPUArchitectureClassifier.architecture(for: "Intel Arc B580"), "Xe2 / Battlemage")
        XCTAssertEqual(GPUArchitectureClassifier.architecture(for: "Intel Arc A770"), "Xe HPG / Alchemist")
        XCTAssertEqual(GPUArchitectureClassifier.architecture(for: "Apple M4 Max GPU"), "Apple Silicon")
        XCTAssertNil(GPUArchitectureClassifier.architecture(for: "AMD Radeon Graphics"))
        XCTAssertNil(GPUArchitectureClassifier.architecture(for: "NVIDIA RTX 6000"))
        XCTAssertNil(GPUArchitectureClassifier.architecture(for: "Virtual GPU"))
    }

    func testMetadataCacheInvalidatesWhenFileChanges() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mutable.gguf")

        try writeGGUF(to: url, uint32: ["qwen35moe.expert_count": 8])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)],
                                              ofItemAtPath: url.path)
        XCTAssertTrue(ServerSettings.modelIsMoE(at: url.path))

        try writeGGUF(to: url, uint32: ["qwen35moe.expert_count": 0])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)],
                                              ofItemAtPath: url.path)
        XCTAssertFalse(ServerSettings.modelIsMoE(at: url.path))
    }

    func testMetadataCacheSupportsConcurrentReaders() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("concurrent.gguf")
        try writeGGUF(to: url, strings: ["general.name": "Concurrent Model"],
                      uint32: ["qwen35moe.expert_count": 128])

        let lock = NSLock()
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            let valid = ServerSettings.modelIsMoE(at: url.path)
                && ServerSettings.ggufString("general.name", at: url.path) == "Concurrent Model"
            if !valid {
                lock.lock()
                failures += 1
                lock.unlock()
            }
        }
        XCTAssertEqual(failures, 0)
    }

    func testCompleteShardsAreGroupedAndIncompleteSetsAreHidden() throws {
        let entries = [
            GGUFFileEntry(path: "model-00001-of-00003.gguf", sizeBytes: 10),
            GGUFFileEntry(path: "model-00002-of-00003.gguf", sizeBytes: 20),
            GGUFFileEntry(path: "model-00003-of-00003.gguf", sizeBytes: 30),
            GGUFFileEntry(path: "broken-00001-of-00002.gguf", sizeBytes: 40),
            GGUFFileEntry(path: "model-mmproj-F16.gguf", sizeBytes: 50),
            GGUFFileEntry(path: "single-Q4_K_M.gguf", sizeBytes: 60),
            GGUFFileEntry(path: "one-part-00001-of-00001.gguf", sizeBytes: 70),
        ]

        let models = GGUFFile.models(from: entries)
        XCTAssertEqual(models.count, 3)
        let split = try XCTUnwrap(models.first { $0.primaryPath.hasPrefix("model-") })
        XCTAssertEqual(split.sizeBytes, 60)
        XCTAssertEqual(split.paths, [
            "model-00001-of-00003.gguf",
            "model-00002-of-00003.gguf",
            "model-00003-of-00003.gguf",
        ])
        XCTAssertFalse(models.contains { $0.primaryPath.contains("broken") })
        XCTAssertFalse(models.contains { $0.primaryPath.contains("mmproj") })
        XCTAssertTrue(models.contains { $0.primaryPath.contains("one-part") })
    }

    func testLocalScanUsesWholeShardSize() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 1, count: 11).write(to: dir.appendingPathComponent("split-00001-of-00002.gguf"))
        try Data(repeating: 2, count: 13).write(to: dir.appendingPathComponent("split-00002-of-00002.gguf"))
        try Data(repeating: 3, count: 17).write(to: dir.appendingPathComponent("incomplete-00001-of-00002.gguf"))

        let models = LocalModel.scan(in: dir)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].sizeBytes, 24)
        XCTAssertEqual(models[0].partURLs.count, 2)
        XCTAssertTrue(models[0].name.contains("00001-of-00002"))
    }

    func testEmbeddedNameKeepsFilenameSizeAndDropsRepositoryOwner() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("pixtral-12B-Q4_K_M.gguf")
        try writeGGUF(to: url, strings: ["general.name": "publisher/Pixtral"])

        let parsed = ModelName.forPath(url.path)
        XCTAssertEqual(parsed.title, "Pixtral 12B")
        XCTAssertEqual(parsed.quant, "Q4_K_M")
    }

    func testLegacyProjectorFallbackRequiresUniqueFamilyAndDimension() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appendingPathComponent("Qwen3.6-14B-A3B-FableVibes-Q4_K_M.gguf")
        let matching = dir.appendingPathComponent("Qwen3.6-14B-A3B-FableVibes-mmproj-Q8_0.gguf")
        let unrelated = dir.appendingPathComponent("Gemma3-mmproj-F16.gguf")
        try writeGGUF(to: model, uint32: ["qwen35moe.embedding_length": 2048])
        try writeGGUF(to: matching, uint32: ["clip.projection_dim": 2048])
        try writeGGUF(to: unrelated, uint32: ["clip.projection_dim": 2048])

        XCTAssertEqual(resolved(ServerSettings.mmprojPath(forModel: model.path)), resolved(matching.path))

        let ambiguous = dir.appendingPathComponent("Qwen3.6-14B-A3B-mmproj-F16.gguf")
        try writeGGUF(to: ambiguous, uint32: ["clip.projection_dim": 2048])
        XCTAssertNil(ServerSettings.mmprojPath(forModel: model.path),
                     "Two compatible same-family projectors must remain a manual choice")
    }

    func testDecimalActiveParameterNameLooksMoE() {
        XCTAssertTrue(ModelName.looksMoE("Model-30B-A3.5B-Q4_K_M.gguf"))
    }

    /// A range request only covers the header, so parsing works off a Data slice.
    func testParsesHeaderFromDataAndRejectsTruncated() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("remote.gguf")
        try writeGGUF(to: url, strings: ["general.architecture": "gemma4"],
                      uint32: ["gemma4.expert_count": 128])
        let full = try Data(contentsOf: url)

        let parsed = try XCTUnwrap(GGUFMetadataCache.parse(from: full))
        XCTAssertEqual(parsed.uint32(forSuffix: "expert_count"), 128)
        XCTAssertEqual(parsed.string(for: "general.architecture"), "gemma4")

        XCTAssertNil(GGUFMetadataCache.parse(from: full.prefix(12)),
                     "a truncated header must fall back, not guess")
        XCTAssertNil(GGUFMetadataCache.parse(from: Data("not a gguf".utf8)))
    }

    /// The whole point of the remote probe: a MoE whose filename hides it.
    func testHeaderBeatsFilenameForRenamedMoE() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("totally-dense-looking.gguf")
        try writeGGUF(to: url, uint32: ["gemma4.expert_count": 128])

        XCTAssertFalse(ModelName.looksMoE(url.lastPathComponent))
        let header = try XCTUnwrap(GGUFMetadataCache.parse(from: try Data(contentsOf: url)))
        XCTAssertTrue((header.uint32(forSuffix: "expert_count") ?? 0) > 0)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("toshllm-detection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as! NSNumber).uint64Value
    }

    private func resolved(_ path: String?) -> String? {
        path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    private func writeGGUF(
        to url: URL,
        strings: [String: String] = [:],
        uint32: [String: UInt32] = [:]
    ) throws {
        var data = Data("GGUF".utf8)
        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendUInt64(_ value: UInt64) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendString(_ value: String) {
            appendUInt64(UInt64(value.utf8.count))
            data.append(contentsOf: value.utf8)
        }

        appendUInt32(3)
        appendUInt64(0)
        appendUInt64(UInt64(strings.count + uint32.count))
        for (key, value) in strings {
            appendString(key)
            appendUInt32(8)
            appendString(value)
        }
        for (key, value) in uint32 {
            appendString(key)
            appendUInt32(4)
            appendUInt32(value)
        }
        try data.write(to: url)
    }
}
