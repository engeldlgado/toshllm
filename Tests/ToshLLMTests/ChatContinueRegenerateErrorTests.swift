// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import ToshLLM

/// Continuation and regeneration start a fresh stream and must drop any stale `lastError` banner.
@MainActor
final class ChatContinueRegenerateErrorTests: XCTestCase {
    private final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private var savedDefaults: [(String, Any?)] = []
    private var servers: [LoopbackHTTPServer] = []
    private var tempDirectories: [URL] = []

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        let overrides: [(String, Any?)] = [
            (SettingsKeys.ctx, 16_384),
            (SettingsKeys.chatAutoCompact, false),
            (SettingsKeys.agentToolsEnabled, false),
            (SettingsKeys.sympyEnabled, false),
            (SettingsKeys.scientificEnabled, false),
            (SettingsKeys.mathAgentEnabled, false),
            (SettingsKeys.jsSandboxEnabled, false),
            (SettingsKeys.memoryToolsEnabled, false),
            (SettingsKeys.chatMapToolEnabled, false),
            (SettingsKeys.chatRoadRouteEnabled, false),
            (SettingsKeys.routerMode, false),
            (SettingsKeys.persistCache, false),
            (SettingsKeys.apiKeyEnabled, false),
            (SettingsKeys.extensionsFolder,
             FileManager.default.temporaryDirectory.appendingPathComponent("tosh-no-ext-\(UUID().uuidString)").path),
            (SettingsKeys.mcpServers, nil)
        ]
        savedDefaults = overrides.map { ($0.0, defaults.object(forKey: $0.0)) }
        for (key, value) in overrides {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    override func tearDown() {
        for server in servers {
            server.stop()
        }
        servers.removeAll()
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        let defaults = UserDefaults.standard
        for (key, original) in savedDefaults {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        savedDefaults.removeAll()
        super.tearDown()
    }

    func testContinueResponseClearsStaleLastError() async throws {
        let (store, port, counter) = try await makeStoreWithServer { attempt in
            switch attempt {
            case 1:
                return Self.sseStream(content: "First part", finishReason: "length",
                                       promptTokens: 10, completionTokens: 512)
            default:
                return Self.sseStream(content: " second part", finishReason: "stop",
                                       promptTokens: 20, completionTokens: 4)
            }
        }

        try await sendTruncatedPrompt(store: store, port: port)

        store.continueResponse(port: port, temperature: 0.7, maxTokens: 512, system: "", thinking: false)
        XCTAssertTrue(store.generating)
        XCTAssertNil(store.lastError, "continueResponse must clear stale lastError when starting")

        try await waitUntil { !store.generating }
        XCTAssertNil(store.lastError)
        XCTAssertEqual(counter.count, 2)
        XCTAssertTrue(store.current?.messages.last?.parts.body.contains("second part") == true)
    }

    func testRegenerateClearsStaleLastError() async throws {
        let (store, port, counter) = try await makeStoreWithServer { attempt in
            switch attempt {
            case 1:
                return Self.sseStream(content: "Truncated draft", finishReason: "length",
                                       promptTokens: 10, completionTokens: 512)
            default:
                return Self.sseStream(content: "Complete answer", finishReason: "stop",
                                       promptTokens: 10, completionTokens: 3)
            }
        }

        try await sendTruncatedPrompt(store: store, port: port)

        store.regenerate(port: port, temperature: 0.7, maxTokens: 512, system: "", thinking: false)
        XCTAssertTrue(store.generating)
        XCTAssertNil(store.lastError, "regenerate must clear stale lastError when starting")

        try await waitUntil { !store.generating }
        XCTAssertNil(store.lastError)
        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(store.current?.messages.last?.parts.body, "Complete answer")
    }

    private func makeStoreWithServer(
        _ respond: @escaping @Sendable (Int) -> Data
    ) async throws -> (ChatStore, Int, RequestCounter) {
        let counter = RequestCounter()
        let server = try LoopbackHTTPServer()
        servers.append(server)
        let port = try await server.start { _ in
            let attempt = counter.next()
            return .respond(status: 200,
                            headers: ["Content-Type": "text/event-stream"],
                            body: respond(attempt))
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tosh-chat-error-\(UUID().uuidString)")
        tempDirectories.append(directory)
        let store = ChatStore(storageDirectory: directory)
        store.newConversation()
        return (store, Int(port), counter)
    }

    private func sendTruncatedPrompt(store: ChatStore, port: Int) async throws {
        store.send(text: "Write an answer", port: port, temperature: 0.7, maxTokens: 512,
                   system: "", thinking: false)
        try await waitUntil { !store.generating }
        XCTAssertEqual(store.lastError, ChatStore.cutAnswerMessage())
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private nonisolated static func sseStream(content: String, finishReason: String,
                                              promptTokens: Int, completionTokens: Int) -> Data {
        let chunks = [
            #"data: {"choices":[{"index":0,"delta":{"content":"\#(content)"},"finish_reason":null}]}"#,
            #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"\#(finishReason)"}]}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":\#(promptTokens),"completion_tokens":\#(completionTokens)}}"#,
            "data: [DONE]"
        ]
        return Data((chunks.joined(separator: "\n\n") + "\n\n").utf8)
    }
}
