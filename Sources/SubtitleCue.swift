// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct SubtitleCue: Identifiable, Hashable, Codable, Sendable {
    let id: Int
    var start: TimeInterval
    var end: TimeInterval
    var text: String

    var srtBlock: String {
        "\(id)\n\(Self.timestamp(start, decimal: ",")) --> \(Self.timestamp(end, decimal: ","))\n\(text)"
    }

    var vttBlock: String {
        "\(Self.timestamp(start, decimal: ".")) --> \(Self.timestamp(end, decimal: "."))\n\(text)"
    }

    static func parseSRT(_ raw: String) -> [SubtitleCue] {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .compactMap(parseBlock)
    }

    static func srt(_ cues: [SubtitleCue]) -> String {
        cues.map(\.srtBlock).joined(separator: "\n\n") + (cues.isEmpty ? "" : "\n")
    }

    static func vtt(_ cues: [SubtitleCue]) -> String {
        "WEBVTT\n\n" + cues.map(\.vttBlock).joined(separator: "\n\n") + (cues.isEmpty ? "" : "\n")
    }

    static func plainText(_ cues: [SubtitleCue]) -> String {
        guard !cues.isEmpty else { return "" }
        var paragraphs: [String] = []
        var current = ""
        for (index, cue) in cues.enumerated() {
            if index > 0, cue.start - cues[index - 1].end > 2, !current.isEmpty {
                paragraphs.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : " ") + cue.text.replacing("\n", with: " / ")
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n\n") + "\n"
    }

    static func timestamp(_ seconds: TimeInterval, decimal: String) -> String {
        let milliseconds = max(0, Int((seconds * 1_000).rounded()))
        return "\(pad(milliseconds / 3_600_000, width: 2)):\(pad((milliseconds / 60_000) % 60, width: 2)):\(pad((milliseconds / 1_000) % 60, width: 2))\(decimal)\(pad(milliseconds % 1_000, width: 3))"
    }

    private static func parseBlock(_ block: String) -> SubtitleCue? {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3, let id = Int(lines[0]) else { return nil }
        let bounds = lines[1].components(separatedBy: " --> ")
        guard bounds.count == 2, let start = seconds(bounds[0]), let end = seconds(bounds[1]) else { return nil }
        let text = lines.dropFirst(2).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return SubtitleCue(id: id, start: start, end: end, text: text)
    }

    private static func seconds(_ value: String) -> TimeInterval? {
        let parts = value.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }
        return hours * 3_600 + minutes * 60 + seconds
    }

    private static func pad(_ value: Int, width: Int) -> String {
        let raw = String(value)
        return String(repeating: "0", count: max(0, width - raw.count)) + raw
    }
}
