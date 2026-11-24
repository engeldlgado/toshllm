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
    // a tool call writing a long file streams only arguments, no text, for longer than the text limit
    func testToolCallArgumentsAreActivityNotText() throws {
        var accumulator = ChatStreamAccumulator()
        let line = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":"}}]}}]}"#
        let event = try XCTUnwrap(try accumulator.consume(line))
        XCTAssertTrue(event.receivedToolCall)
        XCTAssertFalse(event.receivedContent)

        let buffer = StreamBuffer()
        let start = Date()
        buffer.write(reasoning: "", visible: "I'll write both files.", speed: nil)
        for second in stride(from: 1.0, through: 45, by: 1) {
            buffer.note(now: start.addingTimeInterval(second))
            XCTAssertFalse(buffer.stalled(now: start.addingTimeInterval(second + 0.5)))
        }
    }

    func testTheStallReportSaysWhatLimitWasHit() {
        let start = Date()
        var liveness = StreamLiveness(now: start)
        XCTAssertEqual(liveness.report(now: start.addingTimeInterval(190)), "190 s without output during the prompt (limit 180 s)")
        liveness.note(text: true, now: start)
        XCTAssertEqual(liveness.report(now: start.addingTimeInterval(31)), "31 s without output after text (limit 30 s)")
    }
}
