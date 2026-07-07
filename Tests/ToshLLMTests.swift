import XCTest
@testable import ToshLLM

// MARK: - Memory estimator

final class EstimatorTests: XCTestCase {
    /// Reference hardware: the development machine (RX 6700 XT 12 GB + 32 GB RAM).
    private let referenceHW = HardwareInfo(
        cpuBrand: "Test CPU", physicalCores: 6, logicalCores: 12,
        ramGB: 32, arch: "x86_64", model: "", osVersion: "",
        gpus: [GPUDevice(index: 0, name: "Test GPU", vramMB: 12868)])

    func testDenseModelThatFitsIsIdeal() {
        // Qwen3-8B Q4: fits entirely in 12 GB
        let spec = ModelSpec(fileGB: 4.7, paramsB: 8.2, layers: 36, isMoE: false)
        let est = Estimator.estimate(spec: spec, hw: referenceHW)
        XCTAssertEqual(est.level, .ideal)
        XCTAssertEqual(est.suggestedNcmoe, 0)
        XCTAssertLessThan(est.vramGB, referenceHW.vramGB)
    }

    func testLargeDenseModelDoesNotFit() {
        // 27B dense (14.7 GB Q4) on 12 GB VRAM: never "ideal"
        let spec = ModelSpec(fileGB: 14.7, paramsB: 27, layers: 64, isMoE: false)
        let est = Estimator.estimate(spec: spec, hw: referenceHW)
        XCTAssertNotEqual(est.level, .ideal)
    }

    func testMoEModelMatchesEmpiricalNcmoe() {
        // Qwen3.6-35B-A3B: the measured stable value on this hardware is ncmoe in the low-to-mid 20s
        let spec = ModelSpec(fileGB: 19.5, paramsB: 35.4, layers: 40, isMoE: true)
        let est = Estimator.estimate(spec: spec, hw: referenceHW)
        XCTAssertEqual(est.level, .good)
        XCTAssertTrue((20...28).contains(est.suggestedNcmoe),
                      "ncmoe sugerido (\(est.suggestedNcmoe)) fuera del rango validado 20-28")
        XCTAssertLessThan(est.ramGB, referenceHW.ramGB * 0.72)
    }

    func testMoETooBigForRAMIsRejected() {
        let smallRAM = HardwareInfo(
            cpuBrand: "Test", physicalCores: 4, logicalCores: 8,
            ramGB: 8, arch: "x86_64", model: "", osVersion: "",
            gpus: [GPUDevice(index: 0, name: "GPU", vramMB: 8192)])
        let spec = ModelSpec(fileGB: 19.5, paramsB: 35.4, layers: 40, isMoE: true)
        XCTAssertEqual(Estimator.estimate(spec: spec, hw: smallRAM).level, .no)
    }

    func testMoEFitsFullyAcrossMultiGPU() {
        // Two 16 GB cards (Lance's rig): the 35B MoE needs expert offload on one
        // card, but fits entirely in combined VRAM with the split enabled.
        let dualGPU = HardwareInfo(
            cpuBrand: "Test", physicalCores: 16, logicalCores: 32,
            ramGB: 96, arch: "x86_64", model: "", osVersion: "",
            gpus: [GPUDevice(index: 0, name: "GPU0", vramMB: 16368),
                   GPUDevice(index: 1, name: "GPU1", vramMB: 16368)])
        let spec = ModelSpec(fileGB: 19.5, paramsB: 35.4, layers: 40, isMoE: true)
        XCTAssertNotEqual(Estimator.estimate(spec: spec, hw: dualGPU).level, .ideal)
        let split = Estimator.estimate(spec: spec, hw: dualGPU, multiGPU: true)
        XCTAssertEqual(split.level, .ideal)
        XCTAssertEqual(split.suggestedNcmoe, 0)
    }

    func testEstimatedSpecFromFileSize() {
        let spec = ModelSpec.estimated(fileBytes: 5_000_000_000, isMoE: false)
        XCTAssertEqual(spec.fileGB, 4.66, accuracy: 0.05)
        XCTAssertGreaterThan(spec.paramsB, 5)
    }

    func testKVQuantizationShrinksTheEstimate() {
        let spec = ModelSpec(fileGB: 4.7, paramsB: 8.2, layers: 36, isMoE: false)
        let f16 = Estimator.estimate(spec: spec, hw: referenceHW, ctx: 32768)
        let quant = Estimator.estimate(spec: spec, hw: referenceHW, ctx: 32768,
                                       kvScale: Estimator.kvTypeScale("q8_0"))
        XCTAssertLessThan(quant.vramGB, f16.vramGB)
        XCTAssertEqual(Estimator.kvTypeScale("f16"), 1.0)
        XCTAssertEqual(Estimator.kvTypeScale("q8_0"), 0.53, accuracy: 0.01)
    }
}

// MARK: - Image generation

final class ImageGenTests: XCTestCase {
    private func hw(vramMB: Int) -> HardwareInfo {
        HardwareInfo(cpuBrand: "CPU", physicalCores: 6, logicalCores: 12,
                     ramGB: 32, arch: "x86_64", model: "", osVersion: "",
                     gpus: [GPUDevice(index: 0, name: "GPU", vramMB: vramMB)])
    }

    func testAspectDimensionsSnapToLatentGrid() {
        // Every edge is a multiple of 64 (the latent grid), and the base is the
        // long edge, so no preset exceeds base x base (keeps a step under the
        // GPU watchdog).
        for aspect in ImageAspect.allCases {
            let (w, h) = aspect.dimensions(base: 1024)
            XCTAssertEqual(w % 64, 0, "\(aspect.rawValue) width")
            XCTAssertEqual(h % 64, 0, "\(aspect.rawValue) height")
            XCTAssertLessThanOrEqual(max(w, h), 1024, "\(aspect.rawValue) exceeds base")
            XCTAssertEqual(max(w, h), 1024, "\(aspect.rawValue) long edge should equal base")
        }
        XCTAssertEqual(ImageAspect.square.dimensions(base: 1024).0, 1024)
        // Landscape is wider than tall; portrait is taller than wide.
        let land = ImageAspect.landscape.dimensions(base: 1024)
        XCTAssertGreaterThan(land.0, land.1)
        let port = ImageAspect.portrait.dimensions(base: 1024)
        XCTAssertGreaterThan(port.1, port.0)
    }

    func testRecommendationScalesWithVRAM() {
        // A tiny 2 GB card gets nothing; bigger cards get progressively larger models.
        XCTAssertNil(ImageGenCatalog.recommended(for: hw(vramMB: 2048)))
        let rec4 = ImageGenCatalog.recommended(for: hw(vramMB: 4096))
        let rec12 = ImageGenCatalog.recommended(for: hw(vramMB: 12868))
        let rec24 = ImageGenCatalog.recommended(for: hw(vramMB: 24576))
        XCTAssertNotNil(rec4)
        XCTAssertLessThanOrEqual(rec4!.minVRAMGB, rec12!.minVRAMGB)
        XCTAssertLessThanOrEqual(rec12!.minVRAMGB, rec24!.minVRAMGB)
        // 12 GB prefers Z-Image (curated tie-break); the largest card gets the heaviest.
        XCTAssertEqual(rec12?.id, ImageGenCatalog.zImageTurbo.id)
        XCTAssertEqual(rec24?.id, ImageGenCatalog.qwenImage.id)
    }

    func testResolutionLimitsScaleWithVRAM() {
        let r = ImageGenCatalog.zImageTurbo.residentGB
        // Bigger cards allow more pixels and larger base sizes.
        let px12 = ImageGenLimits.maxPixels(vramGB: 12, residentGB: r)
        let px8 = ImageGenLimits.maxPixels(vramGB: 8, residentGB: r)
        XCTAssertGreaterThan(px12, px8)
        // 12 GB fits a 1600x900 frame but not a 1600x1600 square (measured, Z-Image).
        XCTAssertTrue(ImageGenLimits.fits(width: 1600, height: 900, vramGB: 12, residentGB: r))
        XCTAssertFalse(ImageGenLimits.fits(width: 1600, height: 1600, vramGB: 12, residentGB: r))
        // A heavier model (larger resident) allows fewer pixels on the same card.
        XCTAssertLessThan(ImageGenLimits.maxPixels(vramGB: 12, residentGB: ImageGenCatalog.fluxSchnell.residentGB), px12)
        // The offered base sizes scale with the card: more VRAM unlocks larger.
        let max8 = ImageGenLimits.baseSizes(vramGB: 8, residentGB: r).max() ?? 0
        let max12 = ImageGenLimits.baseSizes(vramGB: 12, residentGB: r).max() ?? 0
        let max32 = ImageGenLimits.baseSizes(vramGB: 32, residentGB: r).max() ?? 0
        XCTAssertLessThan(max8, max12)
        XCTAssertLessThan(max12, max32)
    }

    func testCommandBufferSplitClearsWatchdog() {
        // 1024x1024 runs as one buffer; larger frames split, capped at 4.
        XCTAssertEqual(ImageGenLimits.nCB(width: 1024, height: 1024), 1)
        XCTAssertGreaterThan(ImageGenLimits.nCB(width: 1600, height: 900), 1)
        XCTAssertLessThanOrEqual(ImageGenLimits.nCB(width: 1600, height: 1600), 4)
    }
}

// MARK: - Server configuration

final class ServerSettingsTests: XCTestCase {
    private func makeSettings() -> ServerSettings {
        ServerSettings(serverBinary: "/usr/bin/true", modelPath: "/tmp/m.gguf", port: 8080,
                       ngl: 99, ncmoe: 24, ctx: 16384, threads: 6, flashAttn: "auto",
                       noMmap: true, jinja: true, concurrencyDisable: true,
                       vramReserveMB: 1024, gpuIndex: -1, extraArgs: "",
                       cacheTypeK: "f16", cacheTypeV: "f16", mlock: false)
    }

    func testBaseArguments() {
        let args = makeSettings().arguments
        XCTAssertTrue(args.contains("--no-mmap"))
        XCTAssertTrue(args.contains("--jinja"))
        XCTAssertTrue(args.contains("--n-cpu-moe"))
        XCTAssertEqual(args[args.firstIndex(of: "--host")! + 1], "127.0.0.1")
        XCTAssertFalse(args.contains("-ctk"), "f16 no debe emitir -ctk")
        XCTAssertFalse(args.contains("--mlock"))
        // The engine's 8 GiB host prompt cache must always be capped.
        XCTAssertEqual(args[args.firstIndex(of: "--cache-ram")! + 1], "2048")
        XCTAssertFalse(args.contains("--reasoning-format"), "inline reasoning is opt-in")
        // One slot by default: retries resume aborted prefills (VS Code).
        XCTAssertEqual(args[args.firstIndex(of: "--parallel")! + 1], "1")
        XCTAssertEqual(args[args.firstIndex(of: "--cache-reuse")! + 1], "256")
    }

    func testBenchmarkWorkloadArguments() {
        var s = makeSettings()
        // Defaults reproduce the classic pp512/tg128 run.
        var args = s.benchmarkArguments
        XCTAssertEqual(args[args.firstIndex(of: "-p")! + 1], "512")
        XCTAssertEqual(args[args.firstIndex(of: "-n")! + 1], "128")
        // Custom sizes pass through; out-of-range values are clamped.
        s.benchPP = 4096
        s.benchTG = 512
        args = s.benchmarkArguments
        XCTAssertEqual(args[args.firstIndex(of: "-p")! + 1], "4096")
        XCTAssertEqual(args[args.firstIndex(of: "-n")! + 1], "512")
        s.benchPP = 0
        s.benchTG = 1_000_000
        XCTAssertEqual(s.benchPPClamped, 16)
        XCTAssertEqual(s.benchTGClamped, 8192)
    }

    func testPromptCacheAndReasoningArguments() {
        var s = makeSettings()
        s.cacheRAM = 0
        s.reasoningInline = true
        let args = s.arguments
        XCTAssertEqual(args[args.firstIndex(of: "--cache-ram")! + 1], "0")
        XCTAssertEqual(args[args.firstIndex(of: "--reasoning-format")! + 1], "none")
    }

    func testVisionModelDisablesCacheReuseAndDetectsMultimodal() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("toshllm-vision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appendingPathComponent("gemma-3-4b-it-Q4_K_M.gguf")
        let mmproj = dir.appendingPathComponent("mmproj-gemma-3-4b-it-Q4_K_M.gguf")
        FileManager.default.createFile(atPath: model.path, contents: Data())
        FileManager.default.createFile(atPath: mmproj.path, contents: Data())

        var s = makeSettings()
        s.modelPath = model.path
        s.cacheReuse = true

        XCTAssertTrue(s.isMultimodal)
        XCTAssertTrue(s.arguments.contains("--mmproj"))
        XCTAssertFalse(s.arguments.contains("--cache-reuse"),
                       "llama.cpp does not support cache-reuse with multimodal prompts")
    }

    func testProjectorNotMispairedAcrossModels() throws {
        // A text model must not borrow another model's projector sitting in the same
        // folder, even when names share a family prefix (and would share a KV dim).
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("toshllm-vision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appendingPathComponent("Qwen3-8B-Q4_K_M.gguf")
        let mmproj = dir.appendingPathComponent("Qwen3.5-9B-Q4_K_M.mmproj.gguf")
        FileManager.default.createFile(atPath: model.path, contents: Data())
        FileManager.default.createFile(atPath: mmproj.path, contents: Data())

        var s = makeSettings()
        s.modelPath = model.path
        XCTAssertFalse(s.isMultimodal, "Qwen3-8B must not pair with Qwen3.5-9B's projector")
        XCTAssertNil(ServerSettings.mmprojPath(forModel: model.path))
    }

    func testRenamedProjectorsPairUnambiguouslyInSharedFolder() throws {
        // Repos ship projectors under generic, identical names (mmproj-F16.gguf),
        // so the downloader saves them as <model>.mmproj.gguf. Two vision models
        // plus their two model-named projectors must each pair to the right one,
        // with no cross-pairing — the bug we're fixing.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("toshllm-pair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func touch(_ name: String) -> String {
            let u = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: u.path, contents: Data())
            return u.path
        }
        let m12 = touch("gemma-4-12b-it-Q4_K_M.gguf")
        let m26 = touch("gemma-4-26B-A4B-it-UD-Q4_K_M.gguf")
        let p12 = touch("gemma-4-12b-it-Q4_K_M.mmproj.gguf")
        let p26 = touch("gemma-4-26B-A4B-it-UD-Q4_K_M.mmproj.gguf")

        func resolved(_ p: String?) -> String? {
            p.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        }
        XCTAssertEqual(resolved(ServerSettings.mmprojPath(forModel: m12)), resolved(p12))
        XCTAssertEqual(resolved(ServerSettings.mmprojPath(forModel: m26)), resolved(p26))
        // The projector files themselves are never treated as models.
        XCTAssertNil(ServerSettings.mmprojPath(forModel: p12))
    }

    func testExtraArgsSplitEnvFromCliTokens() {
        var s = makeSettings()
        s.extraArgs = "GGML_METAL_WAVE64_SAFEMODE=1 --foo=bar --verbose -x"
        let t = s.extraArgTokens
        // KEY=VALUE (valid env name) becomes an env var, applied to the process.
        XCTAssertEqual(t.env["GGML_METAL_WAVE64_SAFEMODE"], "1")
        XCTAssertEqual(s.environment["GGML_METAL_WAVE64_SAFEMODE"], "1")
        // --foo=bar keeps the leading dash → stays a CLI flag, never an env var.
        XCTAssertEqual(t.cli, ["--foo=bar", "--verbose", "-x"])
        XCTAssertNil(t.env["--foo"])
        // The env assignment is not leaked into llama-server's argument list.
        XCTAssertFalse(s.arguments.contains("GGML_METAL_WAVE64_SAFEMODE=1"))
        XCTAssertTrue(s.arguments.contains("--verbose"))
    }

    func testKVQuantAndMlockArguments() {
        var s = makeSettings()
        s.cacheTypeK = "q8_0"
        s.cacheTypeV = "turbo3"
        s.mlock = true
        let args = s.arguments
        XCTAssertEqual(args[args.firstIndex(of: "-ctk")! + 1], "q8_0")
        XCTAssertEqual(args[args.firstIndex(of: "-ctv")! + 1], "turbo3")
        XCTAssertTrue(args.contains("--mlock"))
    }

    func testExtraArgsAreAppended() {
        var s = makeSettings()
        s.extraArgs = #"--override-kv key=str:"two words""#
        let args = s.arguments
        XCTAssertTrue(args.contains("key=str:two words"))
    }

    func testMTPIsSkippedForModelsWithoutTheHead() {
        var s = makeSettings()
        s.specMTP = true
        s.modelPath = "/tmp/definitely-not-a-model.gguf"
        XCTAssertFalse(s.arguments.contains("--spec-type"),
                       "MTP must be silently skipped when the GGUF lacks the head")
    }

    func testStabilityEnvironment() {
        let env = makeSettings().environment
        XCTAssertEqual(env["GGML_METAL_CONCURRENCY_DISABLE"], "1")
        XCTAssertEqual(env["GGML_METAL_VRAM_RESERVE_MB"], "1024")
        XCTAssertNil(env["GGML_METAL_DEVICE_INDEX"], "gpuIndex -1 no debe fijar índice")
    }

    func testSingleGPUSelectionPinsDeviceUnlessMultiGPUIsEnabled() {
        var s = makeSettings()
        s.gpuIndex = 1
        XCTAssertEqual(s.environment["GGML_METAL_DEVICE_INDEX"], "1")

        s.multiGPU = true
        XCTAssertNil(s.environment["GGML_METAL_DEVICE_INDEX"],
                     "multi-GPU necesita que todos los dispositivos Metal sigan visibles")
    }

    func testServerAndBenchmarkEnableMultiGPUSplitMode() {
        var s = makeSettings()
        s.multiGPU = true

        XCTAssertEqual(s.arguments[s.arguments.firstIndex(of: "--split-mode")! + 1], "layer")
        XCTAssertEqual(s.benchmarkArguments[s.benchmarkArguments.firstIndex(of: "--split-mode")! + 1], "layer")
    }

    func testLocalNetworkDiscoveryBindsServerToAllInterfaces() {
        var s = makeSettings()
        s.localNetworkDiscovery = true

        XCTAssertEqual(s.arguments[s.arguments.firstIndex(of: "--host")! + 1], "0.0.0.0")
    }

    func testBenchmarkForcesFlashAttentionForEffectiveAmdKernel() {
        var s = makeSettings()
        s.faAmd = true
        s.flashAttn = "auto"
        s.cacheTypeV = "f16"

        XCTAssertEqual(s.benchmarkArguments[s.benchmarkArguments.firstIndex(of: "-fa")! + 1], "1")
    }

    func testAmdFlashAttentionDefaultsOnWhenUnset() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: SettingsKeys.faAmd)
        defaults.removeObject(forKey: SettingsKeys.faAmd)
        defer {
            if let previous {
                defaults.set(previous, forKey: SettingsKeys.faAmd)
            } else {
                defaults.removeObject(forKey: SettingsKeys.faAmd)
            }
        }

        XCTAssertTrue(ServerSettings.fromDefaults().faAmd)
    }

    func testQuantizedKVForcesFlashAttentionButNotAmdKernel() {
        var s = makeSettings()
        s.faAmd = false
        s.flashAttn = "off"
        s.cacheTypeK = "q8_0"
        s.cacheTypeV = "q8_0"

        XCTAssertEqual(s.arguments[s.arguments.firstIndex(of: "-fa")! + 1], "1")
        XCTAssertEqual(s.benchmarkArguments[s.benchmarkArguments.firstIndex(of: "-fa")! + 1], "1")
        XCTAssertNil(s.environment["TOSH_FA_AMD"])
    }

    func testAmdFlashAttentionIsOnlyUserToggle() {
        var s = makeSettings()
        s.serverBinary = "/tmp/bin-turbo/llama-server"
        s.faAmd = false
        s.cacheTypeK = "q8_0"

        XCTAssertFalse(s.effectiveFaAmd)
        XCTAssertEqual(s.arguments[s.arguments.firstIndex(of: "-fa")! + 1], "1")
        XCTAssertNil(s.environment["TOSH_FA_AMD"])

        s.faAmd = true
        XCTAssertTrue(s.effectiveFaAmd)
        XCTAssertEqual(s.arguments[s.arguments.firstIndex(of: "-fa")! + 1], "1")
        XCTAssertEqual(s.environment["TOSH_FA_AMD"], "1")
    }
}

// MARK: - Chat

final class ChatMessageTests: XCTestCase {
    func testThinkingBlockIsSeparated() {
        let msg = ChatMessage(role: "assistant",
                              content: "<think>razonando…</think>La respuesta es 4.")
        let parts = msg.parts
        XCTAssertEqual(parts.thinking, "razonando…")
        XCTAssertEqual(parts.body, "La respuesta es 4.")
    }

    func testUnclosedThinkingIsAllThinking() {
        let msg = ChatMessage(role: "assistant", content: "<think>aún pensando")
        XCTAssertEqual(msg.parts.thinking, "aún pensando")
        XCTAssertEqual(msg.parts.body, "")
    }

    func testUserMessageHasNoThinking() {
        let msg = ChatMessage(role: "user", content: "<think>esto es literal</think>")
        XCTAssertNil(msg.parts.thinking)
    }

    func testConversationRoundTripsThroughJSON() throws {
        var conv = Conversation(title: "Prueba")
        conv.messages.append(ChatMessage(role: "user", content: "hola"))
        conv.messages.append(ChatMessage(role: "assistant", content: "¡Hola!", genSpeed: 25.7))
        let data = try JSONEncoder().encode([conv])
        let back = try JSONDecoder().decode([Conversation].self, from: data)
        XCTAssertEqual(back.first?.messages.count, 2)
        XCTAssertEqual(back.first?.messages.last?.genSpeed, 25.7)
    }

    func testLegacyConversationWithoutCompactionFieldsDecodes() throws {
        var conv = Conversation(title: "Vieja")
        conv.messages.append(ChatMessage(role: "user", content: "hola"))
        // Simulate JSON saved before the summary fields existed.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(conv)) as! [String: Any]
        json.removeValue(forKey: "summary")
        json.removeValue(forKey: "summarizedCount")
        let data = try JSONSerialization.data(withJSONObject: json)
        let back = try JSONDecoder().decode(Conversation.self, from: data)
        XCTAssertNil(back.summary)
        XCTAssertNil(back.summarizedCount)
    }
}

@MainActor
final class LiveStreamTests: XCTestCase {
    func testCollapsedReasoningDoesNotPublishGrowingText() {
        let live = LiveStream()

        for i in 1...500 {
            live.update(reasoning: String(repeating: "x", count: i),
                        visible: "", speed: nil)
        }

        XCTAssertTrue(live.hasReasoning)
        XCTAssertFalse(live.reasoningExpanded)
        XCTAssertEqual(live.displayedReasoning, "")

        live.setReasoningExpanded(true)
        XCTAssertEqual(live.displayedReasoning.count, 500)

        live.setReasoningExpanded(false)
        XCTAssertEqual(live.displayedReasoning, "")
    }

    func testVisibleAnswerStillStreamsWhileReasoningIsCollapsed() {
        let live = LiveStream()
        live.update(reasoning: "hidden thought", visible: "Hola", speed: 12)

        XCTAssertEqual(live.displayedReasoning, "")
        XCTAssertEqual(live.visibleText, "Hola")
        XCTAssertEqual(live.speed, 12)
    }

    func testExpandedReasoningPublishesAtMostTwicePerSecond() {
        let live = LiveStream()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        live.update(reasoning: "a", visible: "", speed: nil, now: start)
        live.setReasoningExpanded(true, now: start)
        XCTAssertEqual(live.displayedReasoning, "a")

        live.update(reasoning: "ab", visible: "", speed: nil,
                    now: start.addingTimeInterval(0.1))
        XCTAssertEqual(live.displayedReasoning, "a")

        live.update(reasoning: "abc", visible: "", speed: nil,
                    now: start.addingTimeInterval(0.6))
        XCTAssertEqual(live.displayedReasoning, "abc")
    }
}

// MARK: - Auto-compaction

final class CompactionTests: XCTestCase {
    private func makeMessages(_ turns: Int) -> [ChatMessage] {
        (0..<turns).flatMap { i in
            [ChatMessage(role: "user", content: "pregunta \(i)"),
             ChatMessage(role: "assistant", content: "respuesta \(i)")]
        }
    }

    func testCutoffLandsOnUserMessageAndKeepsRecentTurns() {
        let messages = makeMessages(6)   // 12 messages
        let cutoff = ChatStore.compactionCutoff(messages: messages, alreadyCompacted: 0)
        XCTAssertEqual(cutoff, 8, "debe conservar los 2 últimos intercambios completos")
        XCTAssertEqual(messages[cutoff!].role, "user")
    }

    func testCutoffNilWhenTooLittleWouldBeGained() {
        XCTAssertNil(ChatStore.compactionCutoff(messages: makeMessages(2), alreadyCompacted: 0))
        XCTAssertNil(ChatStore.compactionCutoff(messages: makeMessages(6), alreadyCompacted: 8))
    }

    func testRequestHistoryFoldsSummaryIntoSystemAndSkipsCompactedMessages() {
        let messages = makeMessages(6)
        let history = ChatStore.requestHistory(system: "Eres útil.", summary: "Hablamos de A y B.",
                                               messages: messages, from: 8)
        XCTAssertEqual(history.count, 5)   // system + 4 recent messages
        XCTAssertEqual(history.first?["role"] as? String, "system")
        XCTAssertTrue((history.first!["content"] as? String)?.contains("Eres útil.") == true)
        XCTAssertTrue((history.first!["content"] as? String)?.contains("Hablamos de A y B.") == true)
        XCTAssertEqual(history[1]["content"] as? String, "pregunta 4")
    }

    func testRequestHistoryWithoutSummaryOrSystemHasNoSystemMessage() {
        let history = ChatStore.requestHistory(system: "  ", summary: nil,
                                               messages: makeMessages(2), from: 0)
        XCTAssertEqual(history.count, 4)
        XCTAssertEqual(history.first?["role"] as? String, "user")
    }

    func testRequestHistoryDropsReasoningOnlyAssistantMessage() {
        let messages = [
            ChatMessage(role: "user", content: "hola"),
            ChatMessage(role: "assistant", content: "<think>solo razonamiento"),
            ChatMessage(role: "user", content: "¿qué pasó?"),
        ]
        let history = ChatStore.requestHistory(system: "", summary: nil,
                                               messages: messages, from: 0)
        XCTAssertEqual(history.map { $0["role"] as? String ?? "" }, ["user", "user"])
        XCTAssertEqual(history.last?["content"] as? String, "¿qué pasó?")
    }

    func testAttachmentsAreFoldedIntoTheWireHistory() {
        let msg = ChatMessage(role: "user", content: "¿Qué hace este código?",
                              attachments: [ChatAttachment(name: "main.swift", content: "print(1)")])
        let history = ChatStore.requestHistory(system: "", summary: nil, messages: [msg], from: 0)
        XCTAssertEqual(history.count, 1)
        let wire = history[0]["content"] as? String ?? ""
        XCTAssertTrue(wire.contains("main.swift"))
        XCTAssertTrue(wire.contains("```swift\nprint(1)\n```"))
        XCTAssertTrue(wire.hasSuffix("¿Qué hace este código?"))
    }

    func testMessageWithoutAttachmentsKeepsItsPlainContentDecodable() throws {
        // Pre-attachment JSON (no 'attachments' key) must keep decoding.
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","role":"user","content":"hola","date":700000000}"#
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        XCTAssertNil(decoded.attachments)
        XCTAssertEqual(decoded.wireContent, "hola")
    }

    func testStreamingErrorIsExtractedFromSuccessfulHTTPStream() {
        let object: [String: Any] = ["error": ["message": "Compute error."]]
        XCTAssertEqual(ChatStore.streamedError(from: object), "Compute error.")
    }

    func testReasoningOnlyLengthMessageExplainsTokenLimit() {
        let message = ChatStore.emptyResponseMessage(finishReason: "length")
        XCTAssertTrue(message.contains("máximo de tokens"))
    }
}

// MARK: - Benchmarks and profiles

final class BenchAndProfileTests: XCTestCase {
    func testBenchConfigLabel() {
        let r = BenchResult(date: .now, model: "Qwen3.6-35B-A3B-UD-Q4_K_S.gguf",
                            ncmoe: 24, pp: 68.3, tg: 15.7,
                            ctk: "turbo4", ctv: "turbo3", engine: "turbo",
                            fa: "amd-gpu")
        XCTAssertEqual(r.configLabel, "ncmoe 24 · K:turbo4 · V:turbo3 · FA AMD GPU · turbo")
        XCTAssertFalse(r.shortModel.contains(".gguf"))
    }

    func testBenchmarkFlashAttentionRouteLabelsCPUAndGPU() {
        var s = ServerSettings(serverBinary: "/usr/bin/true", modelPath: "/tmp/m.gguf", port: 8080,
                               ngl: 99, ncmoe: 0, ctx: 16384, threads: 6, flashAttn: "off",
                               noMmap: true, jinja: true, concurrencyDisable: true,
                               vramReserveMB: 1024, gpuIndex: -1, extraArgs: "",
                               cacheTypeK: "q8_0", cacheTypeV: "q8_0", mlock: false)
        s.faAmd = false

        XCTAssertEqual(s.benchmarkFlashAttentionRoute, "standard-cpu")
        XCTAssertEqual(s.benchmarkFlashAttentionLabel, "standard Flash Attention (CPU)")

        s.faAmd = true
        XCTAssertEqual(s.benchmarkFlashAttentionRoute, "amd-gpu")
        XCTAssertEqual(s.benchmarkFlashAttentionLabel, "AMD Flash Attention (GPU)")
    }

    func testLegacyBenchResultsDecode() throws {
        // results saved before ctk/ctv/engine fields existed
        let legacy = #"[{"id":"00000000-0000-0000-0000-000000000000","date":700000000,"model":"m.gguf","ncmoe":0,"pp":100,"tg":50}]"#
        let decoded = try JSONDecoder().decode([BenchResult].self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.first?.configLabel, "base")
        XCTAssertNil(decoded.first?.fa)
    }

    func testProfileRoundTrip() throws {
        let p = Profile(name: "Diario", modelPath: "/m.gguf", ngl: 99, ncmoe: 24,
                        ctx: 32768, threads: 6, flashAttn: "auto", noMmap: true,
                        jinja: true, concurrencyDisable: true, vramReserve: 1024,
                        gpuIndex: -1, extraArgs: "--spec-type draft-mtp",
                        cacheTypeK: "f16", cacheTypeV: "f16", mlock: false,
                        port: 8080, engine: "bundled")
        let back = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.engine, "bundled")
        XCTAssertEqual(back.extraArgs, "--spec-type draft-mtp")
    }
}

// MARK: - Documentation and localization

@MainActor
final class LocalizationTests: XCTestCase {
    func testDocsHaveSameSectionsInBothLanguages() {
        XCTAssertEqual(DocsContent.es.count, DocsContent.en.count)
        XCTAssertGreaterThanOrEqual(DocsContent.es.count, 10)
        for (es, en) in zip(DocsContent.es, DocsContent.en) {
            XCTAssertEqual(es.icon, en.icon, "iconos desalineados: \(es.title) / \(en.title)")
            XCTAssertFalse(es.body.isEmpty)
            XCTAssertFalse(en.body.isEmpty)
        }
    }

    func testDocsNeverMentionForbiddenNames() {
        for section in DocsContent.es + DocsContent.en {
            XCTAssertFalse(section.body.localizedCaseInsensitiveContains("claude"),
                           "la documentación no debe mencionar asistentes de IA")
        }
    }

    func testLocalizerSwitchesLanguage() {
        let loc = Localizer()
        loc.language = "es"
        XCTAssertTrue(loc.isSpanish)
        XCTAssertEqual(loc.t("hola", "hello"), "hola")
        loc.language = "en"
        XCTAssertFalse(loc.isSpanish)
        XCTAssertEqual(loc.t("hola", "hello"), "hello")
    }
}

// MARK: - Shell-words parsing

final class ShellWordsTests: XCTestCase {
    func testPlainSplit() {
        XCTAssertEqual(ShellWords.split("-a 1  -b 2"), ["-a", "1", "-b", "2"])
    }

    func testQuotedArgumentsStayTogether() {
        XCTAssertEqual(ShellWords.split(#"--system "hola mundo" -x"#),
                       ["--system", "hola mundo", "-x"])
        XCTAssertEqual(ShellWords.split("--name 'San Juan' x"),
                       ["--name", "San Juan", "x"])
    }

    func testEmptyQuotesProduceEmptyArgument() {
        XCTAssertEqual(ShellWords.split(#"-p """#), ["-p", ""])
    }

    func testEmptyInput() {
        XCTAssertEqual(ShellWords.split("   "), [])
    }
}

// MARK: - Updates

final class UpdateCheckerTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isVersion("0.82", newerThan: "0.81.1"))
        XCTAssertTrue(UpdateChecker.isVersion("1.0", newerThan: "0.81.1"))
        XCTAssertTrue(UpdateChecker.isVersion("0.81.2", newerThan: "0.81.1"))
        XCTAssertFalse(UpdateChecker.isVersion("0.81.1", newerThan: "0.81.1"))
        XCTAssertFalse(UpdateChecker.isVersion("0.81", newerThan: "0.81.1"))
        XCTAssertFalse(UpdateChecker.isVersion("0.9", newerThan: "1.0"))
    }
}

// MARK: - Catalog

@MainActor
final class CatalogTests: XCTestCase {
    private let referenceHW = HardwareInfo(
        cpuBrand: "Test", physicalCores: 6, logicalCores: 12,
        ramGB: 32, arch: "x86_64", model: "", osVersion: "",
        gpus: [GPUDevice(index: 0, name: "GPU", vramMB: 12868)])

    func testCatalogURLsAreWellFormed() {
        for model in Catalog.models {
            let url = URL(string: model.urlString)
            XCTAssertEqual(url?.scheme, "https", "URL inválida en \(model.name)")
            XCTAssertEqual(url?.host, "huggingface.co")
            XCTAssertTrue(model.fileName.hasSuffix(".gguf"))
        }
    }

    func testRecommendationExistsForReferenceHardware() {
        let recs = Catalog.recommendations(for: referenceHW)
        XCTAssertFalse(recs.isEmpty, "debe haber modelos recomendados para 12GB VRAM + 32GB RAM")
        for rec in recs {
            XCTAssertGreaterThanOrEqual(rec.est.level, .good,
                                        "\(rec.model.name) no debería recomendarse si no corre bien")
        }
    }
}
