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
}
