// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A local MCP server: launched by the app, one JSON-RPC message per line over its
/// pipes.
actor MCPStdioTransport {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var buffer = Data()
    private var readerTask: Task<Void, Never>?
    private var finished = false
    private let name: String

    init(server: MCPServer) throws {
        name = server.name
        let command = server.command.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else {
            throw MCPError.launchFailed("No command set for \(server.name).")
        }
        // A bare name is resolved against the usual install locations: a GUI app
        // inherits a minimal PATH, so /opt/homebrew and /usr/local are not on it.
        let executable = command.contains("/") ? command : Self.resolve(command)
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw MCPError.launchFailed("\(command) was not found, or is not executable.")
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = server.arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.augmentedPath(environment["PATH"])
        for (key, value) in server.environment { environment[key] = value }
        process.environment = environment

        let directory = server.workingDirectory.trimmingCharacters(in: .whitespaces)
        if !directory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
    }

    private static let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin",
                                     "/opt/homebrew/sbin", "/usr/local/sbin"]

    private static func augmentedPath(_ path: String?) -> String {
        let existing = (path ?? "").split(separator: ":").map(String.init)
        return (existing + extraPaths.filter { !existing.contains($0) }).joined(separator: ":")
    }

    private static func resolve(_ command: String) -> String {
        let search = (augmentedPath(ProcessInfo.processInfo.environment["PATH"]))
            .split(separator: ":").map(String.init)
        for directory in search {
            let candidate = (directory as NSString).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return command
    }

    func start() throws {
        try process.run()
        // The server reports why it refused to start on stderr, and says nothing
        // on stdout, so without this a bad configuration looks like a timeout.
        let handle = stderr.fileHandleForReading
        let label = name
        Task.detached(priority: .utility) {
            while let line = try? handle.read(upToCount: 4096), !line.isEmpty {
                let text = String(decoding: line, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { AppLog.chat.debug("MCP \(label, privacy: .public): \(text, privacy: .public)") }
            }
        }
        readerTask = Task { await readLoop() }
    }

    /// One JSON object per line: read what arrives and split on the newline, since
    /// a pipe hands over bytes with no message boundaries of its own.
    private func readLoop() async {
        let handle = stdout.fileHandleForReading
        while !finished {
            let chunk = await Task.detached(priority: .utility) {
                (try? handle.read(upToCount: 65_536)) ?? Data()
            }.value
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = buffer[buffer.index(after: newline)...]
                deliver(line)
            }
        }
        failPending(MCPError.launchFailed("\(name) closed its output."))
    }

    private func deliver(_ line: Data) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        // A notification from the server has no id and nothing is waiting on it.
        guard let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) else { return }
        if let error = object["error"] as? [String: Any] {
            continuation.resume(throwing: MCPError.remote(error["message"] as? String ?? "MCP JSON-RPC error"))
        } else {
            continuation.resume(returning: object["result"] as? [String: Any] ?? [:])
        }
    }

    func send(_ payload: [String: Any], id: Int?, timeout: Int) async throws -> [String: Any] {
        guard process.isRunning else { throw MCPError.launchFailed("\(name) is not running.") }
        var line = try JSONSerialization.data(withJSONObject: payload)
        line.append(0x0A)
        guard let id else {
            try stdin.fileHandleForWriting.write(contentsOf: line)
            return [:]
        }
        return try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { await self.register(id: id, continuation: continuation, line: line) }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(max(5, timeout)))
                throw MCPError.launchFailed("\(self.name) did not answer in time.")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw MCPError.invalidResponse }
            return first
        }
    }

    private func register(id: Int, continuation: CheckedContinuation<[String: Any], Error>, line: Data) {
        pending[id] = continuation
        do {
            try stdin.fileHandleForWriting.write(contentsOf: line)
        } catch {
            pending.removeValue(forKey: id)?.resume(throwing: error)
        }
    }

    private func failPending(_ error: Error) {
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
    }

    func stop() {
        finished = true
        readerTask?.cancel()
        failPending(CancellationError())
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
