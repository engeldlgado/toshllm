import XCTest
@testable import ToshLLM

// MARK: - Memory estimator

final class EstimatorTests: XCTestCase {
    /// Reference hardware: the development machine (RX 6700 XT 12 GB + 32 GB RAM).
    private let referenceHW = HardwareInfo(
        cpuBrand: "Test CPU", physicalCores: 6, logicalCores: 12,
        ramGB: 32, arch: "x86_64",
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
            ramGB: 8, arch: "x86_64",
            gpus: [GPUDevice(index: 0, name: "GPU", vramMB: 8192)])
        let spec = ModelSpec(fileGB: 19.5, paramsB: 35.4, layers: 40, isMoE: true)
        XCTAssertEqual(Estimator.estimate(spec: spec, hw: smallRAM).level, .no)
    }

    func testEstimatedSpecFromFileSize() {
        let spec = ModelSpec.estimated(fileBytes: 5_000_000_000, isMoE: false)
        XCTAssertEqual(spec.fileGB, 4.66, accuracy: 0.05)
        XCTAssertGreaterThan(spec.paramsB, 5)
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
        XCTAssertFalse(args.contains("-ctk"), "f16 no debe emitir -ctk")
        XCTAssertFalse(args.contains("--mlock"))
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
}

// MARK: - Benchmarks and profiles

final class BenchAndProfileTests: XCTestCase {
    func testBenchConfigLabel() {
        let r = BenchResult(date: .now, model: "Qwen3.6-35B-A3B-UD-Q4_K_S.gguf",
                            ncmoe: 24, pp: 68.3, tg: 15.7,
                            ctk: "turbo4", ctv: "turbo3", engine: "turbo")
        XCTAssertEqual(r.configLabel, "ncmoe 24 · K:turbo4 · V:turbo3 · turbo")
        XCTAssertFalse(r.shortModel.contains(".gguf"))
    }

    func testLegacyBenchResultsDecode() throws {
        // results saved before ctk/ctv/engine fields existed
        let legacy = #"[{"id":"00000000-0000-0000-0000-000000000000","date":700000000,"model":"m.gguf","ncmoe":0,"pp":100,"tg":50}]"#
        let decoded = try JSONDecoder().decode([BenchResult].self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.first?.configLabel, "base")
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
        loc.isSpanish = true
        XCTAssertEqual(loc.t("hola", "hello"), "hola")
        loc.isSpanish = false
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
        ramGB: 32, arch: "x86_64",
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
        let rec = Catalog.recommended(for: referenceHW)
        XCTAssertNotNil(rec, "debe haber un modelo recomendado para 12GB VRAM + 32GB RAM")
        XCTAssertGreaterThanOrEqual(rec!.1.level, .good)
    }
}
