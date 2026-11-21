// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ToshLLM

final class ServerExposureTests: XCTestCase {
    private func makeSettings() -> ServerSettings {
        ServerSettings(serverBinary: "/usr/bin/true", modelPath: "/tmp/m.gguf", port: 8080,
                       ngl: 99, ncmoe: 0, ctx: 8192, threads: 6, flashAttn: "auto",
                       noMmap: true, jinja: true,
                       vramReserveMB: 1024, gpuIndex: -1, extraArgs: "",
                       cacheTypeK: "f16", cacheTypeV: "f16", mlock: false)
    }

    func testToolsOnTheNetworkWithoutAKeyStillStart() {
        var s = makeSettings()
        s.localNetworkDiscovery = true
        s.agentToolsEnabled = true
        XCTAssertTrue(s.arguments.contains("--allow-unauthenticated-tools"))
    }

    func testLoopbackNeedsNoPermission() {
        var s = makeSettings()
        s.agentToolsEnabled = true
        XCTAssertFalse(s.arguments.contains("--allow-unauthenticated-tools"))
    }

    func testNoToolsNeedNoPermission() {
        var s = makeSettings()
        s.localNetworkDiscovery = true
        XCTAssertEqual(s.unauthenticatedToolsArguments(toolsEnabled: false), [])
    }

    func testAKeyNeedsNoPermission() {
        var s = makeSettings()
        s.localNetworkDiscovery = true
        s.apiKeyEnabled = true
        XCTAssertEqual(s.unauthenticatedToolsArguments(toolsEnabled: true), [])
    }
}
