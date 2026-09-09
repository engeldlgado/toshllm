// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ToshLLM

final class ToolSupportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: SettingsKeys.toolsUnsupportedModels)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SettingsKeys.toolsUnsupportedModels)
        super.tearDown()
    }

    func testBlocksOnlyTheModelThatFailed() {
        ToolSupport.block("/models/Llama-3.2-1B-Instruct-Q4_K_M.gguf")

        XCTAssertTrue(ToolSupport.isBlocked("/models/Llama-3.2-1B-Instruct-Q4_K_M.gguf"))
        XCTAssertFalse(ToolSupport.isBlocked("/models/Qwen3-8B-Q4_K_M.gguf"))
    }

    func testBlockingTwiceKeepsOneEntry() {
        ToolSupport.block("/models/a.gguf")
        ToolSupport.block("/models/a.gguf")

        XCTAssertEqual(ToolSupport.blockedModels, ["/models/a.gguf"])
    }

    func testUnblockRestoresTools() {
        ToolSupport.block("/models/a.gguf")
        ToolSupport.block("/models/b.gguf")
        ToolSupport.unblock("/models/a.gguf")

        XCTAssertFalse(ToolSupport.isBlocked("/models/a.gguf"))
        XCTAssertEqual(ToolSupport.blockedModels, ["/models/b.gguf"])
    }

    func testMissingModelIsNeverBlocked() {
        ToolSupport.block(nil)
        ToolSupport.block("")

        XCTAssertTrue(ToolSupport.blockedModels.isEmpty)
        XCTAssertFalse(ToolSupport.isBlocked(nil))
        XCTAssertFalse(ToolSupport.isBlocked(""))
    }
}
