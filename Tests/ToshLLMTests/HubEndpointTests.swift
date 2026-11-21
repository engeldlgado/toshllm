// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import XCTest
@testable import ToshLLM

final class HubEndpointTests: XCTestCase {
    private let file = URL(string: "https://huggingface.co/owner/repo/resolve/main/sub%20dir/model.gguf")!

    func testHuggingFaceUnlessAMirrorOrHFEndpointIsSet() {
        XCTAssertNil(HubEndpoint.base(choice: nil, custom: nil, environment: [:]))
        XCTAssertNil(HubEndpoint.base(choice: HubEndpoint.huggingFace, custom: "https://mirror.example", environment: [:]))
        XCTAssertEqual(HubEndpoint.base(choice: nil, custom: nil, environment: ["HF_ENDPOINT": "https://hf-mirror.com/"]),
                       HubEndpoint.hfMirrorURL)
        XCTAssertEqual(HubEndpoint.base(choice: HubEndpoint.hfMirror, custom: nil,
                                        environment: ["HF_ENDPOINT": "https://other.example"]),
                       HubEndpoint.hfMirrorURL, "the choice in Settings wins over the environment")
        XCTAssertEqual(HubEndpoint.base(choice: HubEndpoint.custom, custom: " https://mirror.example/hf/ ", environment: [:]),
                       URL(string: "https://mirror.example/hf"))
    }

    func testOnlyWebAddressesWithAHostAreMirrors() {
        for text in ["", "hf-mirror.com", "ftp://mirror.example", "https://", "https://mirror.example/?a=1",
                     "https://huggingface.co"] {
            XCTAssertNil(HubEndpoint.validBase(text), text)
        }
        XCTAssertNil(HubEndpoint.base(choice: HubEndpoint.custom, custom: "not a url", environment: [:]))
        XCTAssertEqual(HubEndpoint.validBase("http://127.0.0.1:8080"), URL(string: "http://127.0.0.1:8080"))
    }

    func testRequestsGoToTheMirrorWithTheSamePath() {
        XCTAssertEqual(HubEndpoint.resolve(file, base: HubEndpoint.hfMirrorURL).absoluteString,
                       "https://hf-mirror.com/owner/repo/resolve/main/sub%20dir/model.gguf")
        let search = URL(string: "https://huggingface.co/api/models?search=qwen%203&filter=gguf")!
        XCTAssertEqual(HubEndpoint.resolve(search, base: URL(string: "http://127.0.0.1:8080/hf")).absoluteString,
                       "http://127.0.0.1:8080/hf/api/models?search=qwen%203&filter=gguf")
        let other = URL(string: "https://github.com/owner/repo/releases/download/v1/model.gguf")!
        XCTAssertEqual(HubEndpoint.resolve(other, base: HubEndpoint.hfMirrorURL), other)
        XCTAssertEqual(HubEndpoint.resolve(file, base: nil), file)
    }

    func testMirrorLinksAreKeptAsTheirHuggingFaceAddress() {
        let fromMirror = URL(string: "https://hf-mirror.com/owner/repo/resolve/main/sub%20dir/model.gguf")!
        XCTAssertEqual(HubEndpoint.canonical(fromMirror, base: nil), file)
        let custom = URL(string: "http://127.0.0.1:8080/hf")!
        XCTAssertEqual(HubEndpoint.canonical(HubEndpoint.resolve(file, base: custom), base: custom), file)
        let outside = URL(string: "http://127.0.0.1:8080/other/model.gguf")!
        XCTAssertEqual(HubEndpoint.canonical(outside, base: custom), outside)
        XCTAssertEqual(HubEndpoint.canonical(file, base: custom), file)
    }
}

/// The real download and search paths against a mirror on loopback.
@MainActor
final class HubMirrorDownloadTests: XCTestCase {
    private var server: LoopbackHTTPServer!
    private var savedChoice: Any?
    private var savedCustom: Any?
    private var savedDigests: Any?

    override func setUp() async throws {
        let defaults = UserDefaults.standard
        savedChoice = defaults.object(forKey: SettingsKeys.hubEndpoint)
        savedCustom = defaults.object(forKey: SettingsKeys.hubEndpointCustom)
        savedDigests = defaults.object(forKey: SettingsKeys.modelDigest)
        server = try LoopbackHTTPServer()
    }

    override func tearDown() async throws {
        server.stop()
        let defaults = UserDefaults.standard
        defaults.set(savedChoice, forKey: SettingsKeys.hubEndpoint)
        defaults.set(savedCustom, forKey: SettingsKeys.hubEndpointCustom)
        defaults.set(savedDigests, forKey: SettingsKeys.modelDigest)
    }

    private func useMirror(port: Int) {
        UserDefaults.standard.set(HubEndpoint.custom, forKey: SettingsKeys.hubEndpoint)
        UserDefaults.standard.set("http://127.0.0.1:\(port)/hub", forKey: SettingsKeys.hubEndpointCustom)
    }

    private func serveModel(_ payload: Data, listedDigest: String) async throws -> Int {
        let tree = try JSONSerialization.data(withJSONObject: [[
            "path": "model.gguf", "size": payload.count, "lfs": ["oid": listedDigest],
        ]])
        return try await server.start { request in
            switch request.path {
            case "/hub/api/models/owner/repo/tree/main":
                return .respond(status: 200, headers: ["Content-Type": "application/json"], body: tree)
            case "/hub/owner/repo/resolve/main/model.gguf":
                return .respond(status: 200, headers: [:], body: payload)
            default:
                return .respond(status: 404, headers: [:], body: Data())
            }
        }
    }

    private func download(into dir: URL) -> DownloadItem {
        DownloadItem(remote: URL(string: "https://huggingface.co/owner/repo/resolve/main/model.gguf")!,
                     destination: dir.appendingPathComponent("model.gguf"))
    }

    private func finish(_ item: DownloadItem) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if item.finished || item.error != nil { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hub-mirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testModelDownloadsFromTheMirrorAndIsChecked() async throws {
        let payload = Data((0..<300_000).map { UInt8($0 % 241) })
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        useMirror(port: try await serveModel(payload, listedDigest: digest))
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let item = download(into: dir)
        let done = await finish(item)
        XCTAssertTrue(done)
        XCTAssertEqual(item.phase, .finished)
        XCTAssertEqual(try Data(contentsOf: item.destination), payload)
        XCTAssertEqual(item.remote.host, "huggingface.co", "the recorded source keeps its Hugging Face address")
        XCTAssertEqual(server.requests.map(\.path),
                       ["/hub/api/models/owner/repo/tree/main", "/hub/owner/repo/resolve/main/model.gguf"])
    }

    func testMirrorFileThatDoesNotMatchItsChecksumIsDiscarded() async throws {
        let payload = Data((0..<300_000).map { UInt8($0 % 241) })
        let wrong = SHA256.hash(data: Data("other".utf8)).map { String(format: "%02x", $0) }.joined()
        useMirror(port: try await serveModel(payload, listedDigest: wrong))
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let item = download(into: dir)
        let done = await finish(item)
        XCTAssertTrue(done)
        XCTAssertTrue(item.error?.contains("SHA-256") == true, item.error ?? "no error")
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.destination.path))
    }

    func testSearchAsksTheMirror() async throws {
        let repos = try JSONSerialization.data(withJSONObject: [["id": "owner/repo-GGUF", "downloads": 10]])
        useMirror(port: try await server.start { _ in
            .respond(status: 200, headers: ["Content-Type": "application/json"], body: repos)
        })
        let store = SearchStore()
        store.query = "repo"
        await store.search()
        XCTAssertEqual(store.results.map(\.id), ["owner/repo-GGUF"])
        XCTAssertEqual(server.requests.first.map { URLComponents(string: $0.path)?.path }, "/hub/api/models")
    }

    /// Goes out to hf-mirror.com, which may redirect to huggingface.co depending on the network.
    func testLiveDownloadThroughHFMirror() async throws {
        guard ProcessInfo.processInfo.environment["TOSH_HUB_LIVE"] == "1" else {
            throw XCTSkip("Set TOSH_HUB_LIVE=1 to download a small file through hf-mirror.com")
        }
        UserDefaults.standard.set(HubEndpoint.hfMirror, forKey: SettingsKeys.hubEndpoint)
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let remote = URL(string: WhisperVADModel.downloadURL)!
        let meta = await HuggingFaceAPI.fileMetadata(for: remote)
        XCTAssertNotNil(meta?.sha256, "the tree API answered through the mirror")
        let item = DownloadItem(remote: remote, destination: dir.appendingPathComponent(remote.lastPathComponent))
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, !item.finished, item.error == nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(item.phase, .finished, item.error ?? "")
        let local = FileHash.sha256(of: item.destination)?.lowercased()
        XCTAssertEqual(local, meta?.sha256?.lowercased())
    }
}
