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
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
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
        text.split(separator: "\n", omittingEmptySubsequences: true).enumerated().compactMap { index, rawLine in
            var tail = Substring(rawLine)
            while tail.last?.isWhitespace == true { tail = tail.dropLast() }
            guard !tail.isEmpty else { return nil }
            let raw = String(tail)
            let fields = raw.split(maxSplits: 3, omittingEmptySubsequences: true,
                                   whereSeparator: { $0.isWhitespace })
            if fields.count >= 3, isElapsedTime(fields[0]), let level = level(fields[1]) {
                // a function name in the tag's place is the message's first word, not a source
                if fields.count == 4, isSourceTag(fields[2]) {
                    // llama.cpp pads the source column, so the tail carries that padding.
                    let message = String(fields[3]).trimmingCharacters(in: .whitespaces)
                    return PresentedLogLine(id: index, time: String(fields[0]), level: level,
                                            source: friendlySource(String(fields[2])),
                                            message: message, raw: raw)
                }
                let message = fields[2...].joined(separator: " ")
                return PresentedLogLine(id: index, time: String(fields[0]), level: level,
                                        source: inferredSource(message, fallback: fallbackSource),
                                        message: message, raw: raw)
            }

            if isBacktraceFrame(fields) {
                // the frames' column padding only spreads them across the row
                return PresentedLogLine(id: index, time: "—", level: .error, source: "Backtrace",
                                        message: fields.joined(separator: " "), raw: raw)
            }
            let leading = raw.prefix { $0.isWhitespace }
            let message = leading.count > 0 ? raw : raw.trimmingCharacters(in: .whitespaces)
            return PresentedLogLine(id: index, time: "—", level: inferredLevel(raw),
                                    source: inferredSource(raw, fallback: fallbackSource),
                                    message: message, raw: raw)
        }
    }

    /// Long names (IOKit constants, mangled symbols, paths) have no space to wrap at, and the
    /// text system splits them with a hyphen the log does not have; give them break points instead.
    /// For display only: search and copy keep the line as written.
    static func softBreaks(_ message: String) -> String {
        guard message.count >= 28 else { return message }
        return message.split(separator: " ", omittingEmptySubsequences: false).map { token in
            guard token.count >= 28 else { return String(token) }
            var out = ""
            var lowercaseRun = 0
            for character in token {
                // between words of a camel-case name, never after a single letter (kIOAccel)
                if character.isUppercase, lowercaseRun >= 2 { out.append("\u{200B}") }
                lowercaseRun = character.isLowercase ? lowercaseRun + 1 : 0
                out.append(character)
                // after separators, never after an opening bracket, which would hang at a line end
                if ":/_.,=".contains(character) { out.append("\u{200B}") }
            }
            return out
        }.joined(separator: " ")
    }

    /// llama.cpp tags are a short word (srv, cmn, slot, spec); a name ending in a colon is the message.
    private static func isSourceTag(_ value: Substring) -> Bool {
        value.count <= 8 && value.allSatisfy { $0.isLetter }
    }

    /// `<n>  <binary>  0x<address>  <symbol> + <offset>`, as the engine prints a crash.
    private static func isBacktraceFrame(_ fields: [Substring]) -> Bool {
        fields.count >= 4 && fields[0].allSatisfy(\.isNumber) && fields[2].hasPrefix("0x")
    }

    /// `file.cpp:741: message`, how GGML_ABORT and GGML_ASSERT stop the engine.
    private static func isAbortLocation(_ line: String) -> Bool {
        guard let colon = line.range(of: ": ") else { return false }
        let head = line[..<colon.lowerBound]
        guard let lineMark = head.lastIndex(of: ":"),
              head[head.index(after: lineMark)...].allSatisfy(\.isNumber),
              head.index(after: lineMark) < head.endIndex else { return false }
        let file = head[..<lineMark]
        return [".c", ".cc", ".cpp", ".h", ".hpp", ".m", ".mm", ".metal"].contains { file.hasSuffix($0) }
    }

    private static func isElapsedTime(_ value: Substring) -> Bool {
        guard value.first?.isNumber == true else { return false }
        return value.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
    }

    private static func level(_ value: Substring) -> PresentedLogLevel? {
        switch value {
        case "E": return .error
        case "W": return .warning
        case "I", "D": return .info
        default: return nil
        }
    }

    private static func inferredLevel(_ line: String) -> PresentedLogLevel {
        let lower = line.lowercased()
        if isAbortLocation(line) { return .error }
        if lower.contains("fatal") || lower.contains("error") || lower.contains("failed") { return .error }
        if lower.contains("exited with code") || lower.contains("engine stopped") || lower.contains("terminating") {
            return .error
        }
        if lower.contains("warning") || lower.contains("warn:") { return .warning }
        return .info
    }

    private static func inferredSource(_ line: String, fallback: String) -> String {
        let lower = line.lowercased().trimmingCharacters(in: .whitespaces)
        // the app's start banner, ahead of the engine's own lines
        if lower.hasPrefix("[toshllm]") || lower.hasPrefix("====") || lower.hasPrefix("toshllm ")
            || lower.hasPrefix("engine ") || lower.hasPrefix("model ") || lower.hasPrefix("gpus detected")
            || lower.hasPrefix("gpu select") || lower.hasPrefix("settings:") || lower.hasPrefix("dflash")
            || lower.hasPrefix("env:") || lower.hasPrefix("args:")
            || (lower.hasPrefix("[") && lower.dropFirst().first?.isNumber == true) { return "ToshLLM" }
        if lower.contains("ggml_metal") || lower.contains("metal") || lower.contains("kioaccel") { return "Metal" }
        if lower.contains("llama_server") { return "Server" }
        return fallback
    }

    private static func friendlySource(_ source: String) -> String {
        switch source.lowercased() {
        case "srv", "server": return "Server"
        case "cmn", "common": return "Common"
        case "load": return "Loader"
        case "slot": return "Slot"
        case "sampler": return "Sampler"
        default: return source
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
