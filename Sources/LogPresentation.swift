// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum PresentedLogLevel: Int, Sendable {
    case info = 0
    case warning = 1
    case error = 2

    var shortLabel: String {
        switch self {
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }
}

struct PresentedLogLine: Identifiable, Sendable {
    let id: Int
    let time: String
    let level: PresentedLogLevel
    let source: String
    let message: String
    let raw: String
}

enum LogPresentationParser {
    /// llama.cpp writes `<elapsed> <I|W|E> <source> <message>`. Startup banners,
    /// Metal diagnostics and third-party engines are also kept as useful rows.
    static func parse(_ text: String, fallbackSource: String) -> [PresentedLogLine] {
        text.split(separator: "\n", omittingEmptySubsequences: true).enumerated().map { index, rawLine in
            let raw = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            let fields = raw.split(maxSplits: 3, omittingEmptySubsequences: true,
                                   whereSeparator: { $0.isWhitespace })
            if fields.count == 4, isElapsedTime(fields[0]), let level = level(fields[1]) {
                // llama.cpp pads the source column, so the tail carries that padding.
                let message = String(fields[3]).trimmingCharacters(in: .whitespaces)
                return PresentedLogLine(id: index, time: String(fields[0]), level: level,
                                        source: friendlySource(String(fields[2])),
                                        message: message, raw: raw)
            }

            let inferred = inferredLevel(raw)
            return PresentedLogLine(id: index, time: "—", level: inferred,
                                    source: inferredSource(raw, fallback: fallbackSource),
                                    message: raw, raw: raw)
        }
    }

    private static func isElapsedTime(_ value: Substring) -> Bool {
        guard value.first?.isNumber == true else { return false }
        return value.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
    }

    private static func level(_ value: Substring) -> PresentedLogLevel? {
        switch value {
        case "E": .error
        case "W": .warning
        case "I", "D": .info
        default: nil
        }
    }

    private static func inferredLevel(_ line: String) -> PresentedLogLevel {
        let lower = line.lowercased()
        if lower.contains("fatal") || lower.contains("error") || lower.contains("failed") { return .error }
        if lower.contains("warning") || lower.contains("warn:") { return .warning }
        return .info
    }

    private static func inferredSource(_ line: String, fallback: String) -> String {
        let lower = line.lowercased()
        if lower.contains("ggml_metal") || lower.contains("metal") { return "Metal" }
        if lower.contains("llama_server") { return "Server" }
        if lower.hasPrefix("toshllm ") || lower.hasPrefix("engine ") || lower.hasPrefix("model  ") ||
            lower.hasPrefix("settings:") || lower.hasPrefix("args:") { return "ToshLLM" }
        return fallback
    }

    private static func friendlySource(_ source: String) -> String {
        switch source.lowercased() {
        case "srv", "server": "Server"
        case "cmn", "common": "Common"
        case "load": "Loader"
        case "slot": "Slot"
        case "sampler": "Sampler"
        default: source
        }
    }
}

enum LogFileTail {
    /// Read only the tail used by the UI. Full files remain available through
    /// Finder and diagnostics export without retaining multi-megabyte strings.
    static func read(_ url: URL?, maxBytes: UInt64 = 512 * 1024) -> String {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return "" }
        let start = end > maxBytes ? end - maxBytes : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        guard !data.isEmpty else { return "" }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text.removeSubrange(text.startIndex...newline)
        }
        return text
    }
}
