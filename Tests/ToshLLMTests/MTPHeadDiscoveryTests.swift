// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ToshLLM

final class MTPHeadDiscoveryTests: XCTestCase {
    func testHeadAndModelShareAStem() {
        let model = ServerSettings.mtpStem("Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf")
        for head in ["mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf",
                     "Qwen3.8-Flash-Next.mtp.gguf",
                     "Qwen3.8-Flash-Next-MTP-Q8_0.gguf"] {
            XCTAssertEqual(ServerSettings.mtpStem(head), model, head)
        }
    }

    func testADifferentModelDoesNotMatch() {
        XCTAssertNotEqual(ServerSettings.mtpStem("mtp-Qwen3.8-27B-Q8_0.gguf"),
                          ServerSettings.mtpStem("Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf"))
    }

    func testHeadsAreNotOfferedAsModels() {
        for name in ["Qwen3.8-Flash-Next-MTP-Q8_0.gguf", "Qwen3.8-Flash-Next-mtp.gguf"] {
            XCTAssertTrue(GGUFFile.isDraft("/models/\(name)"), name)
        }
    }

    func testFlashNextTakesItsOwnDraftWidth() {
        XCTAssertEqual(ServerSettings.mtpDraftWidthArgs(forModel: "/models/missing.gguf"), [])
    }

    func testDraftWidthFollowsTheCardLaneWidth() {
        let m = "/models/missing.gguf"
        XCTAssertEqual(ServerSettings.mtpDraftWidthArgs(forModel: m, gpuArchitecture: "GCN / Vega"), ["--spec-draft-n-max", "1"])
        XCTAssertEqual(ServerSettings.mtpDraftWidthArgs(forModel: m, gpuArchitecture: "RDNA 2"), ["--spec-draft-n-max", "2"])
        XCTAssertEqual(ServerSettings.mtpDraftWidthArgs(forModel: m, gpuArchitecture: "Apple Silicon"), [])
        XCTAssertEqual(GPUArchitectureClassifier.architecture(for: "AMD Radeon Pro Vega II Duo"), "GCN / Vega")
        XCTAssertEqual(GPUArchitectureClassifier.architecture(for: "AMD Radeon RX 6700 XT"), "RDNA 2")
    }
}

/// The launch environment for a split, written straight from the settings the UI exposes.
final class SplitEnvironmentTests: XCTestCase {
    private func settings(devices: Int, mode: String, group: Int) -> ServerSettings {
        var s = ServerSettings(serverBinary: "/usr/bin/true", modelPath: "/tmp/m.gguf", port: 8080,
                               ngl: 99, ncmoe: 0, ctx: 8192, threads: 6, flashAttn: "auto",
                               noMmap: true, jinja: true, vramReserveMB: 1024, gpuIndex: -1,
                               extraArgs: "", cacheTypeK: "f16", cacheTypeV: "f16", mlock: false)
        s.multiGPU = true
        // an explicit list, so the split width does not depend on the machine running the tests
        s.gpuList = Array(0..<devices)
        s.splitMode = mode
        s.splitGroupSize = group
        return s
    }

    func testTensorSplitCarriesTheBridgeAndTheFastHandover() {
        let s = settings(devices: 2, mode: "tensor", group: 0)
        XCTAssertEqual(s.environment["TOSH_MGPU_PEER"], "1")
        XCTAssertEqual(s.environment["TOSH_MGPU_EVENTS"], "1")
        XCTAssertNil(s.environment["TOSH_MGPU_TENSOR_GROUP"], "one group is a plain tensor split")
        XCTAssertTrue(s.arguments.contains("--split-mode"))
    }

    func testGroupsOnlyApplyWhenTheyDivideTheSplit() {
        XCTAssertNil(settings(devices: 4, mode: "tensor", group: 3).effectiveSplitGroupSize)
        XCTAssertNil(settings(devices: 4, mode: "tensor", group: 4).effectiveSplitGroupSize,
                     "a group as wide as the split is the plain split")
        XCTAssertEqual(settings(devices: 4, mode: "tensor", group: 2).effectiveSplitGroupSize, 2)
    }

    /// The four arrangements, as the engine receives them.
    func testEachArrangementReachesTheEngineWhole() {
        let mesh = settings(devices: 4, mode: "tensor", group: 2)
        XCTAssertEqual(mesh.environment["GGML_METAL_DEVICE_LIST"], "0,1,2,3")
        XCTAssertEqual(mesh.environment["TOSH_MGPU_TENSOR_GROUP"], "2")
        XCTAssertEqual(mesh.environment["TOSH_MGPU_PEER"], "1")
        XCTAssertEqual(mesh.environment["TOSH_MGPU_EVENTS"], "1")
        XCTAssertEqual(mesh.arguments[mesh.arguments.firstIndex(of: "--split-mode")! + 1], "tensor")

        let tp4 = settings(devices: 4, mode: "tensor", group: 0)
        XCTAssertNil(tp4.environment["TOSH_MGPU_TENSOR_GROUP"])
        XCTAssertEqual(tp4.arguments[tp4.arguments.firstIndex(of: "--split-mode")! + 1], "tensor")

        let tp2 = settings(devices: 2, mode: "tensor", group: 0)
        XCTAssertEqual(tp2.environment["GGML_METAL_DEVICE_LIST"], "0,1")
        XCTAssertEqual(tp2.arguments[tp2.arguments.firstIndex(of: "--split-mode")! + 1], "tensor")
    }

    func testALayerSplitLeavesTheBridgeOut() {
        let s = settings(devices: 4, mode: "layer", group: 2)
        XCTAssertNil(s.environment["TOSH_MGPU_PEER"])
        XCTAssertNil(s.environment["TOSH_MGPU_TENSOR_GROUP"])
    }
}
