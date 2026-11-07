// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A local MCP server: launched by the app, one JSON-RPC message per line over its
/// pipes.
actor MCPStdioTransport {
    private struct Waiting {
        let token: UInt64
        let method: String?
        let continuation: CheckedContinuation<[String: Any], Error>
        let deadline: Task<Void, Never>
    }

    /// A class, not the dictionary itself: on Swift 5.7 the continuation closure that
    /// registers a request is not actor-isolated, so it writes through a captured reference.
    private final class PendingTable {
        private var byID: [Int: Waiting] = [:]
        subscript(_ id: Int) -> Waiting? {
            get { byID[id] }
            set { byID[id] = newValue }
        }
        var count: Int { byID.count }
        var keys: [Int] { Array(byID.keys) }
    }

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    /// Writes run off the actor: a server that stops reading fills the pipe, and a blocked
    /// write must not keep a deadline from resolving its request.
    private let writer = DispatchQueue(label: "MCPStdioTransport.writer")
    private let pending = PendingTable()
    private var tokens: UInt64 = 0
    private var buffer = Data()
    private var readerTask: Task<Void, Never>?
    private var closed: Error?
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
        // EPIPE instead of SIGPIPE, which ends the app when the server has closed its input.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
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
        let label = name
        stderr.fileHandleForReading.readabilityHandler = { handle in
            guard let line = Self.readAvailable(handle, max: 4096) else { return }
            if line.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { AppLog.chat.debug("MCP \(label, privacy: .public): \(text, privacy: .public)") }
        }
        // A dispatch source rather than a blocking read in a task: an idle server would
        // otherwise hold a thread of the shared concurrency pool.
        // The 5.7 stdlib has no AsyncStream.makeStream; the builder closure runs before
        // init returns, so its continuation can be lifted out.
        var captured: AsyncStream<Data>.Continuation?
        let chunks = AsyncStream(Data.self) { captured = $0 }
        let feed = captured!
        stdout.fileHandleForReading.readabilityHandler = { handle in
            guard let chunk = Self.readAvailable(handle, max: 65_536) else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                feed.finish()
            } else {
                feed.yield(chunk)
            }
        }
        readerTask = Task { await readLoop(chunks) }
    }

    /// Whatever the pipe holds: empty at end of file, nil when a wakeup found nothing yet.
    private static func readAvailable(_ handle: FileHandle, max: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: max)
        while true {
            let count = Darwin.read(handle.fileDescriptor, &bytes, max)
            if count >= 0 { return Data(bytes[0..<count]) }
            if errno == EAGAIN { return nil }
            if errno != EINTR { return Data() }
        }
    }

    /// One JSON object per line: read what arrives and split on the newline, since
    /// a pipe hands over bytes with no message boundaries of its own.
    private func readLoop(_ chunks: AsyncStream<Data>) async {
        for await chunk in chunks {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = buffer[buffer.index(after: newline)...]
                deliver(line)
            }
        }
        close(because: MCPError.launchFailed("\(name) closed its output."))
    }

    private func deliver(_ line: Data) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        // A notification from the server has no id and nothing is waiting on it.
        guard let id = object["id"] as? Int else { return }
        if let error = object["error"] as? [String: Any] {
            resolve(id, with: .failure(MCPError.remote(error["message"] as? String ?? "MCP JSON-RPC error")))
        } else {
            resolve(id, with: .success(object["result"] as? [String: Any] ?? [:]))
        }
    }

    func send(_ payload: [String: Any], id: Int?, timeout: Int) async throws -> [String: Any] {
        try await send(payload, id: id, timeout: .seconds(Double(max(5, timeout))))
    }

    /// Resolves once, by the answer, the deadline, the caller's cancellation or the server
    /// closing, whichever comes first; an answer after that finds nothing waiting and is dropped.
    func send(_ payload: [String: Any], id: Int?, timeout: Duration) async throws -> [String: Any] {
        if let closed { throw closed }
        guard process.isRunning else { throw MCPError.launchFailed("\(name) is not running.") }
        var line = try JSONSerialization.data(withJSONObject: payload)
        line.append(0x0A)
        guard let id else {
            try await write(line)
            return [:]
        }
        guard pending[id] == nil else { throw MCPError.invalidResponse }
        tokens += 1
        let token = tokens
        let method = payload["method"] as? String
        let late = MCPError.launchFailed("\(name) did not answer in time.")
        let table = pending
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: timeout.nanoseconds) } catch { return }
                    await self?.abandon(id, token, because: late)
                }
                table[id] = Waiting(token: token, method: method, continuation: continuation, deadline: deadline)
                if Task.isCancelled { return abandon(id, token, because: CancellationError()) }
                enqueue(line) { [weak self] error in
                    guard let error else { return }
                    Task { [weak self] in await self?.resolve(id, token: token, with: .failure(error)) }
                }
            }
        } onCancel: {
            Task { await self.abandon(id, token, because: CancellationError()) }
        }
    }

    /// For tests: requests still waiting.
    var waiting: Int { pending.count }

    /// The token tells a request from a later one reusing its id.
    private func resolve(_ id: Int, token: UInt64? = nil, with result: Result<[String: Any], Error>) {
        guard let waiting = pending[id], token == nil || waiting.token == token else { return }
        pending[id] = nil
        waiting.deadline.cancel()
        waiting.continuation.resume(with: result)
    }

    /// Stops waiting and tells the server, which may ignore it; `initialize` may not be cancelled.
    private func abandon(_ id: Int, _ token: UInt64, because error: Error) {
        guard let waiting = pending[id], waiting.token == token else { return }
        resolve(id, token: token, with: .failure(error))
        guard closed == nil, waiting.method != "initialize" else { return }
        let reason = error is CancellationError ? "Cancelled" : "Timed out"
        let notice: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/cancelled",
                                     "params": ["requestId": id, "reason": reason]]
        guard var line = try? JSONSerialization.data(withJSONObject: notice) else { return }
        line.append(0x0A)
        enqueue(line) { _ in }
    }

    private func enqueue(_ line: Data, then done: @escaping @Sendable (Error?) -> Void) {
        let handle = stdin.fileHandleForWriting
        writer.async {
            do { try handle.write(contentsOf: line); done(nil) } catch { done(error) }
        }
    }

    private func write(_ line: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enqueue(line) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func close(because error: Error) {
        if closed == nil { closed = error }
        for id in Array(pending.keys) { resolve(id, with: .failure(error)) }
    }

    func stop() {
        readerTask?.cancel()
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        close(because: CancellationError())
        // Terminating first lets a write blocked on a full pipe fail before its handle closes.
        if process.isRunning { process.terminate() }
        let handle = stdin.fileHandleForWriting
        writer.async { try? handle.close() }
    }
}
