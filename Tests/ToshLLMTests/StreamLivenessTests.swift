// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ToshLLM

final class StreamLivenessTests: XCTestCase {
    func testALongPromptWithProgressIsAlive() {
        let start = Date()
        var liveness = StreamLiveness(now: start)
        // a slow GPU reports a batch of prompt every minute for half an hour
        for minute in 1...30 {
            let now = start.addingTimeInterval(Double(minute) * 60)
            XCTAssertFalse(liveness.stalled(now: now))
            liveness.note(text: false, now: now)
        }
        XCTAssertFalse(liveness.sawText)
    }

    func testSilenceDuringThePromptStalls() {
        let start = Date()
        let liveness = StreamLiveness(now: start)
        XCTAssertFalse(liveness.stalled(now: start.addingTimeInterval(170)))
        XCTAssertTrue(liveness.stalled(now: start.addingTimeInterval(190)))
    }

    func testOnceTextStartsItHasToKeepComing() {
        let start = Date()
        var liveness = StreamLiveness(now: start)
        liveness.note(text: false, now: start.addingTimeInterval(100))
        liveness.note(text: true, now: start.addingTimeInterval(120))
        XCTAssertFalse(liveness.stalled(now: start.addingTimeInterval(145)))
        XCTAssertTrue(liveness.stalled(now: start.addingTimeInterval(155)))
    }

    // the answer ended while the main thread was still laying it out: the watchdog reads that late
    func testAnEndedStreamNeverStalls() {
        let buffer = StreamBuffer()
        buffer.write(reasoning: "", visible: "| a | b |", speed: nil)
        let late = Date().addingTimeInterval(StreamLiveness.textLimit + 5)
        XCTAssertTrue(buffer.stalled(now: late))
        buffer.finish()
        XCTAssertFalse(buffer.stalled(now: late))
    }

    func testAHeldAnswerCountsAsPrompt() {
        let buffer = StreamBuffer()
        buffer.write(reasoning: "", visible: "", speed: nil)
        XCTAssertFalse(buffer.stalled(now: Date().addingTimeInterval(StreamLiveness.textLimit + 5)))
        XCTAssertTrue(buffer.stalled(now: Date().addingTimeInterval(StreamLiveness.promptLimit + 5)))
    }

    func testAgentKeepAlivesKeepTheStreamAlive() {
        let buffer = StreamBuffer()
        buffer.write(reasoning: "", visible: "x", speed: nil)
        let alive = Date().addingTimeInterval(StreamLiveness.textLimit - 1)
        buffer.note(now: alive)
        XCTAssertFalse(buffer.stalled(now: alive.addingTimeInterval(StreamLiveness.textLimit - 1)))
        XCTAssertTrue(buffer.stalled(now: alive.addingTimeInterval(StreamLiveness.textLimit + 1)))
    }
}
