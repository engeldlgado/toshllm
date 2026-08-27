// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ToshLLM

final class AudioVideoExportIntegrationTests: XCTestCase {
    @MainActor
    func testCaptionedVideoExportWhenFixtureIsProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["TOSH_AUDIO_VIDEO_FIXTURE"] else {
            throw XCTSkip("Set TOSH_AUDIO_VIDEO_FIXTURE to run the video export integration test")
        }
        let source = URL(fileURLWithPath: path)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("tosh-captioned-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: output) }
        let exporter = SubtitleVideoExporter()
        exporter.export(
            sourceURL: source,
            cues: [SubtitleCue(id: 1, start: 0.2, end: 1.8, text: "ToshLLM subtitle test")],
            outputURL: output
        )
        while exporter.isExporting {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(exporter.error)
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertGreaterThan(size, 1_000)
    }
}
