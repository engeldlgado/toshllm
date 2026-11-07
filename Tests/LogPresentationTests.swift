// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ToshLLM

final class LogPresentationTests: XCTestCase {
    func testParsesRealLlamaCppPrefix() {
        let line = "0.00.112.264 I srv    load_model: loading model '/models/Qwen.gguf'"
        let parsed = LogPresentationParser.parse(line, fallbackSource: "Engine")

        XCTAssertEqual(parsed.first?.time, "0.00.112.264")
        XCTAssertEqual(parsed.first?.level, .info)
        XCTAssertEqual(parsed.first?.source, "Server")
        XCTAssertEqual(parsed.first?.message, "load_model: loading model '/models/Qwen.gguf'")
    }

    func testKeepsUnprefixedMetalDiagnostics() {
        let line = "ggml_metal: device 0: AMD Radeon RX 6700 XT"
        let parsed = LogPresentationParser.parse(line, fallbackSource: "Engine")

        XCTAssertEqual(parsed.first?.source, "Metal")
        XCTAssertEqual(parsed.first?.message, line)
    }

    func testFunctionNameInTheTagPlaceStaysInTheMessage() {
        let line = "0.25.476.312 I common_speculative_init_result: creating MTP draft context"
        let parsed = LogPresentationParser.parse(line, fallbackSource: "Engine")

        XCTAssertEqual(parsed.first?.source, "Engine")
        XCTAssertEqual(parsed.first?.message, "common_speculative_init_result: creating MTP draft context")
    }

    func testCrashLinesCountAsErrors() {
        let log = """
        /src/ggml/src/ggml-backend-meta.cpp:741: unsupported mul_mat split states
        2   llama-server                        0x000000010efb3ea1 ggml_backend_meta_get_split_state + 1473
        [ToshLLM] the engine stopped (engine exited with code 6 — see the log in Settings) — restarting
        """
        let parsed = LogPresentationParser.parse(log, fallbackSource: "Engine")

        XCTAssertEqual(parsed.map(\.level), [.error, .error, .error])
        XCTAssertEqual(parsed[1].source, "Backtrace")
        XCTAssertEqual(parsed[1].message, "2 llama-server 0x000000010efb3ea1 ggml_backend_meta_get_split_state + 1473")
        XCTAssertEqual(parsed[2].source, "ToshLLM")
    }

    func testKeepsTheBannerIndentation() {
        let parsed = LogPresentationParser.parse("    [0] AMD Radeon RX 6700 XT · 12 GB", fallbackSource: "Engine")

        XCTAssertEqual(parsed.first?.message, "    [0] AMD Radeon RX 6700 XT · 12 GB")
        XCTAssertEqual(parsed.first?.level, .info)
    }

    func testLongNamesGetBreakPointsForDisplayOnly() {
        let message = "error: Ignored (00000004:kIOAccelCommandBufferCallbackErrorSubmissionsIgnored)"
        let shown = LogPresentationParser.softBreaks(message)

        XCTAssertTrue(shown.contains(":\u{200B}kIOAccel"))
        XCTAssertTrue(shown.contains("Accel\u{200B}Command"))
        XCTAssertEqual(shown.replacingOccurrences(of: "\u{200B}", with: ""), message)
        XCTAssertEqual(LogPresentationParser.softBreaks("slot launch_slot_: id 0 | task 0"), "slot launch_slot_: id 0 | task 0")
    }
}
