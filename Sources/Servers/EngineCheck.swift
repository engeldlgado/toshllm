// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Engine check

struct EngineCheckBackend: Equatable {
    var name: String
    var passed: Int
    var total: Int
}

struct EngineCheckResult: Equatable {
    var device = ""
    var simdWidth = 0
    var backends: [EngineCheckBackend] = []
    var failures: [String] = []
    /// Failures we already know about and that are not this app's doing.
    var knownFailures: [String] = []
    var cancelled = false

    var ok: Bool { failures.isEmpty && !backends.isEmpty }
}

/// Runs the engine's own operator tests and turns their output into something a
/// user can paste into a bug report.
enum EngineCheck {
    /// Upstream failures reported by every machine. Listing them as problems only
    /// produces false alarms: TIMESTEP_EMBEDDING is image-side and predates the AMD work.
    static let knownFailingOps: Set<String> = ["TIMESTEP_EMBEDDING"]

    /// The test binary sits next to whichever engine is selected.
    static func binaryPath(serverBinary: String) -> String {
        URL(fileURLWithPath: serverBinary)
            .deletingLastPathComponent()
            .appendingPathComponent("test-backend-ops").path
    }

    static func isAvailable(serverBinary: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: binaryPath(serverBinary: serverBinary))
    }

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m")

    static func stripANSI(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return ansi.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// Reads the op name out of a result line, which starts with the op in brackets.
    private static func opName(in line: String) -> String {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return "" }
        return String(line[line.index(after: line.startIndex)..<close])
    }

    static func parse(_ output: String) -> EngineCheckResult {
        var result = EngineCheckResult()
        var backend = ""

        for raw in stripANSI(output).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if result.simdWidth == 0, let r = line.range(of: "probed SIMD-group width = ") {
                result.simdWidth = Int(line[r.upperBound...].prefix { $0.isNumber }) ?? 0
            }
            if result.device.isEmpty, let r = line.range(of: "ggml_metal: device 0: ") {
                let rest = String(line[r.upperBound...])
                result.device = String(rest.split(separator: "(").first ?? "")
                    .trimmingCharacters(in: .whitespaces)
            }
            if trimmed.hasPrefix("Backend "), let colon = trimmed.lastIndex(of: ":") {
                backend = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                continue
            }
            if let r = trimmed.range(of: " tests passed") {
                let counts = trimmed[trimmed.startIndex..<r.lowerBound].split(separator: "/")
                if counts.count == 2, let p = Int(counts[0]), let t = Int(counts[1]), !backend.isEmpty {
                    result.backends.append(.init(name: backend, passed: p, total: t))
                }
                continue
            }
            if trimmed.hasSuffix(": FAIL"), trimmed.hasPrefix("[") {
                let entry = String(trimmed.dropLast(": FAIL".count))
                if knownFailingOps.contains(opName(in: trimmed)) {
                    result.knownFailures.append(entry)
                } else {
                    result.failures.append(entry)
                }
            }
        }
        return result
    }

    /// Plain-text section for the diagnostics file.
    static func report(_ r: EngineCheckResult, localized loc: (String, String) -> String) -> String {
        var out: [String] = ["## Engine check (test-backend-ops)"]
        if r.cancelled { out.append("CANCELLED by the user, the results below are incomplete") }
        if !r.device.isEmpty { out.append("GPU: \(r.device)") }
        if r.simdWidth > 0 {
            let kind = r.simdWidth == 64 ? "AMD GCN/Vega" : "Apple / AMD RDNA"
            out.append("SIMD width: \(r.simdWidth) (\(kind))")
        }
        for b in r.backends {
            out.append("\(b.name): \(b.passed)/\(b.total) ops passed")
        }
        if r.knownFailures.isEmpty {
            out.append("Known upstream failures: none")
        } else {
            out.append("Known upstream failures (not a problem, no need to report): \(r.knownFailures.count)")
            out.append(contentsOf: r.knownFailures.map { "  \($0)" })
        }
        if r.failures.isEmpty {
            out.append("Failures: none")
        } else {
            out.append("FAILURES: \(r.failures.count)")
            out.append(contentsOf: r.failures.map { "  \($0)" })
        }
        return out.joined(separator: "\n")
    }

    /// One-line verdict for the UI.
    static func verdict(_ r: EngineCheckResult, localized loc: (String, String) -> String) -> String {
        if r.cancelled { return loc("Comprobación cancelada", "Check cancelled") }
        if r.backends.isEmpty { return loc("El motor no completó la comprobación", "The engine did not finish the check") }
        let total = r.backends.reduce(0) { $0 + $1.total }
        let passed = r.backends.reduce(0) { $0 + $1.passed }
        if r.failures.isEmpty {
            return loc("Motor correcto: \(passed) de \(total) operaciones",
                       "Engine is correct: \(passed) of \(total) operations")
        }
        return loc("\(r.failures.count) operación(es) con resultado incorrecto de \(total)",
                   "\(r.failures.count) operation(s) returned wrong results out of \(total)")
    }
}

/// Drives `test-backend-ops` and publishes progress, so the UI can show what it is
/// doing during the minutes it takes and let the user stop it.
@MainActor
final class EngineChecker: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var currentOp = ""
    @Published private(set) var testCount = 0
    @Published private(set) var result: EngineCheckResult?

    private var process: Process?
    private var buffer = ""

    func start(settings: ServerSettings, onFinish: @escaping (EngineCheckResult) -> Void) {
        guard !running else { return }
        let path = EngineCheck.binaryPath(serverBinary: settings.serverBinary)
        guard FileManager.default.isExecutableFile(atPath: path) else { return }

        running = true
        currentOp = ""
        testCount = 0
        result = nil
        buffer = ""

        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        // The engine's own environment: without TOSH_FA_AMD the attention kernels are
        // never instantiated and the check would silently skip them.
        p.environment = settings.environment

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.consume(text) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                var parsed = EngineCheck.parse(self.buffer)
                parsed.cancelled = self.process == nil
                self.running = false
                self.process = nil
                self.result = parsed
                onFinish(parsed)
            }
        }

        do {
            try p.run()
            process = p
        } catch {
            running = false
        }
    }

    func cancel() {
        let p = process
        process = nil
        p?.terminate()
    }

    private func consume(_ text: String) {
        buffer += text
        for raw in text.split(separator: "\n") {
            let line = EngineCheck.stripANSI(String(raw)).trimmingCharacters(in: .whitespaces)
            guard let paren = line.firstIndex(of: "("), line.contains(": ") else { continue }
            let name = String(line[line.startIndex..<paren])
            guard !name.isEmpty, name.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }) else { continue }
            currentOp = name
            testCount += 1
        }
    }
}
