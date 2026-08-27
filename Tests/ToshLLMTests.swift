// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ToshLLM

final class WhisperTranscriptTests: XCTestCase {
    func testWhisperRuntimeForcesAMDFlashAttentionAndSafeMetalPolicy() {
        let environment = SpeechDictationController.runtimeEnvironment(base: [:])
        XCTAssertEqual(environment["TOSH_FA_AMD"], "1")
        XCTAssertEqual(environment["GGML_METAL_CONCURRENCY_DISABLE"], "1")
        XCTAssertEqual(environment["GGML_METAL_SHARED_BUFFERS_DISABLE"], "1")
    }

    func testWhisperCatalogDefaultsToTurboAndHasUniqueFiles() {
        XCTAssertEqual(WhisperModel.model(id: WhisperModel.recommendedID).id,
                       "large-v3-turbo")
        XCTAssertEqual(Set(WhisperModel.catalog.map(\.fileName)).count,
                       WhisperModel.catalog.count)
        XCTAssertTrue(WhisperModel.catalog.allSatisfy {
            $0.downloadURL.hasSuffix("/\($0.fileName)")
        })
    }

    func testNormalizesWhisperTextOutput() {
        XCTAssertEqual(WhisperTranscript.normalized("  Hola mundo.\n"), "Hola mundo.")
    }

    func testMicrophoneTranscriptCollapsesInternalLineBreaks() {
        XCTAssertEqual(
            WhisperTranscript.normalized(" Primera línea\n segunda\t línea  "),
            "Primera línea segunda línea"
        )
    }

    func testBlankAudioMarkerProducesNoTranscript() {
        XCTAssertEqual(WhisperTranscript.normalized(" [BLANK_AUDIO]\n"), "")
    }

    func testTimestampedJSONBecomesChatReadyText() throws {
        let json = #"{"transcription":[{"timestamps":{"from":"00:01:02,500"},"text":" Hola mundo. "}]}"#
        XCTAssertEqual(WhisperTranscript.timestamped(jsonData: Data(json.utf8)),
                       "[00:01:02] Hola mundo.")
    }

    func testPersistentServerJSONBecomesChatReadyText() {
        let json = #"{"segments":[{"start":62.5,"end":65.0,"text":" Hola desde la GPU. "}]}"#
        XCTAssertEqual(WhisperTranscript.timestamped(jsonData: Data(json.utf8)),
                       "[00:01:02] Hola desde la GPU.")
    }

    func testSpeechPreferencesHaveStablePersistedValues() {
        XCTAssertEqual(SpeechInputMethod.apple.rawValue, "apple")
        XCTAssertEqual(SpeechInputMethod.whisper.rawValue, "whisper")
        XCTAssertEqual(WhisperLoadPolicy.onDemand.rawValue, "onDemand")
        XCTAssertEqual(WhisperLoadPolicy.alwaysLoaded.rawValue, "alwaysLoaded")
    }

    func testSubtitleRoundTripPreservesTimingAndSingleLineText() {
        let raw = "1\n00:00:01,250 --> 00:00:03,500\nPrimera línea\nsegunda línea\n\n"
        let cues = SubtitleCue.parseSRT(raw)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 1.25, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 3.5, accuracy: 0.001)
        XCTAssertEqual(cues[0].text, "Primera línea segunda línea")
        XCTAssertEqual(SubtitleCue.srt(cues),
                       "1\n00:00:01,250 --> 00:00:03,500\nPrimera línea segunda línea\n")
    }

    func testAudioStudioPreferencesHaveStableValues() {
        XCTAssertEqual(AudioStudioOperation.transcribe.rawValue, "transcribe")
        XCTAssertEqual(AudioStudioOperation.translateEnglish.rawValue, "translateEnglish")
        XCTAssertEqual(AudioStudioOperation.translateLocal.rawValue, "translateLocal")
        XCTAssertEqual(AudioExportFormat.srt.fileExtension, "srt")
        XCTAssertEqual(AudioExportFormat.text.fileExtension, "txt")
    }

    func testAudioStudioRunsWhisperThroughCalibratedSileroVAD() {
        let arguments = AudioStudioController.whisperArguments(
            audioURL: URL(fileURLWithPath: "/tmp/source.wav"),
            modelURL: URL(fileURLWithPath: "/tmp/whisper.bin"),
            vadModelURL: URL(fileURLWithPath: "/tmp/silero.bin"),
            vadConfiguration: AudioVADConfiguration(
                mode: .calibrated, calibration: AudioVADProfile.strict.calibration
            ),
            outputBase: URL(fileURLWithPath: "/tmp/result"),
            gpuIndex: 2, language: "es"
        )
        XCTAssertTrue(arguments.contains("--vad"))
        guard let vad = arguments.firstIndex(of: "--vad-model"),
              let threshold = arguments.firstIndex(of: "--vad-threshold"),
              let minSpeech = arguments.firstIndex(of: "--vad-min-speech-duration-ms"),
              let minSilence = arguments.firstIndex(of: "--vad-min-silence-duration-ms"),
              let maxSpeech = arguments.firstIndex(of: "--vad-max-speech-duration-s"),
              let speechPad = arguments.firstIndex(of: "--vad-speech-pad-ms"),
              let overlap = arguments.firstIndex(of: "--vad-samples-overlap"),
              let gpu = arguments.firstIndex(of: "-dev"),
              let language = arguments.firstIndex(of: "-l") else {
            return XCTFail("Missing Audio transcription arguments")
        }
        XCTAssertEqual(arguments[vad + 1], "/tmp/silero.bin")
        XCTAssertEqual(arguments[threshold + 1], "0.75")
        XCTAssertEqual(arguments[minSpeech + 1], "500")
        XCTAssertEqual(arguments[minSilence + 1], "250")
        XCTAssertEqual(arguments[maxSpeech + 1], "25.0")
        XCTAssertEqual(arguments[speechPad + 1], "60")
        XCTAssertEqual(arguments[overlap + 1], "0.05")
        XCTAssertEqual(arguments[gpu + 1], "2")
        XCTAssertEqual(arguments[language + 1], "es")
        XCTAssertFalse(arguments.contains("--diarize"))
        XCTAssertFalse(arguments.contains("--tinydiarize"))
    }

    func testAudioStudioCanUseNativeVADDefaultsWithoutCalibration() {
        let arguments = AudioStudioController.whisperArguments(
            audioURL: URL(fileURLWithPath: "/tmp/source.wav"),
            modelURL: URL(fileURLWithPath: "/tmp/whisper.bin"),
            vadModelURL: URL(fileURLWithPath: "/tmp/silero.bin"),
            vadConfiguration: AudioVADConfiguration(mode: .standard, calibration: nil),
            outputBase: URL(fileURLWithPath: "/tmp/result"),
            gpuIndex: 0, language: "auto"
        )
        XCTAssertTrue(arguments.contains("--vad"))
        XCTAssertTrue(arguments.contains("--vad-model"))
        XCTAssertFalse(arguments.contains("--vad-threshold"))
        XCTAssertFalse(arguments.contains("--vad-min-speech-duration-ms"))
        XCTAssertFalse(arguments.contains("--vad-samples-overlap"))
    }

    func testAudioStudioCanDisableVAD() {
        let arguments = AudioStudioController.whisperArguments(
            audioURL: URL(fileURLWithPath: "/tmp/source.wav"),
            modelURL: URL(fileURLWithPath: "/tmp/whisper.bin"),
            vadModelURL: URL(fileURLWithPath: "/tmp/silero.bin"),
            vadConfiguration: AudioVADConfiguration(mode: .disabled, calibration: nil),
            outputBase: URL(fileURLWithPath: "/tmp/result"),
            gpuIndex: 0, language: "auto"
        )
        XCTAssertFalse(arguments.contains("--vad"))
        XCTAssertFalse(arguments.contains("--vad-model"))
        XCTAssertFalse(arguments.contains("--vad-threshold"))
    }

    func testCurrentSubtitleFollowsPlaybackPositionAndRespectsGaps() {
        let cues = [
            SubtitleCue(id: 1, start: 1, end: 3, text: "Uno"),
            SubtitleCue(id: 2, start: 4, end: 6, text: "Dos"),
            SubtitleCue(id: 3, start: 6, end: 8, text: "Tres")
        ]
        XCTAssertNil(AudioStudioController.cueID(at: 0.9, in: cues))
        XCTAssertEqual(AudioStudioController.cueID(at: 1, in: cues), 1)
        XCTAssertNil(AudioStudioController.cueID(at: 3.5, in: cues))
        XCTAssertEqual(AudioStudioController.cueID(at: 4.5, in: cues), 2)
        XCTAssertEqual(AudioStudioController.cueID(at: 6, in: cues), 3)
        XCTAssertNil(AudioStudioController.cueID(at: 8, in: cues))
    }

    func testSubtitleTranslationUsesAuthenticationAndStructuredJSON() throws {
        let cues = [SubtitleCue(id: 7, start: 1, end: 2, text: "Hello")]
        let request = try AudioStudioController.translationRequest(
            cues: cues, targetLanguage: "Español", port: 9090,
            routerModel: "translator", apiKey: "secret",
            glossary: "Mac Pro = Mac Pro", context: "[6] Previous => Anterior"
        )
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:9090/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["model"] as? String, "translator")
        XCTAssertEqual((body["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, false)
        let responseFormat = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
        let wrapper = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        let schema = try XCTUnwrap(wrapper["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let translations = try XCTUnwrap(properties["translations"] as? [String: Any])
        XCTAssertEqual(translations["minItems"] as? Int, 1)
        XCTAssertEqual(translations["maxItems"] as? Int, 1)
        let prefixItems = try XCTUnwrap(translations["prefixItems"] as? [[String: Any]])
        let itemProperties = try XCTUnwrap(prefixItems.first?["properties"] as? [String: Any])
        XCTAssertEqual((itemProperties["id"] as? [String: Any])?["const"] as? Int, 7)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertTrue(messages[0]["content"]?.contains("reference-only") == true)
        XCTAssertTrue(messages[1]["content"]?.contains("Mac Pro = Mac Pro") == true)
        XCTAssertTrue(messages[1]["content"]?.contains("Previous => Anterior") == true)
    }

    func testSubtitleTranslationCreatesOneRequestPerSegment() {
        let cues = (1...4).map {
            SubtitleCue(id: $0, start: Double($0), end: Double($0 + 1), text: "Cue \($0)")
        }
        let batches = AudioStudioController.translationBatches(cues)
        XCTAssertEqual(batches.count, cues.count)
        XCTAssertTrue(batches.allSatisfy { $0.count == 1 })
        XCTAssertEqual(batches.flatMap { $0 }.map(\.id), cues.map(\.id))
    }

    func testTranslationContextCarriesNeighboringSourceAndPriorTerminology() {
        let source = (1...20).map {
            SubtitleCue(id: $0, start: Double($0), end: Double($0 + 1), text: "Source \($0)")
        }
        let translated = Dictionary(uniqueKeysWithValues: (1...12).map { ($0, "Destino \($0)") })
        let context = AudioStudioController.translationContext(
            for: Array(source[12...14]), in: source, translated: translated
        )
        XCTAssertTrue(context.contains("CONSISTENCY MEMORY"))
        XCTAssertTrue(context.contains("Source 1 => Destino 1"))
        XCTAssertTrue(context.contains("NEIGHBORING CONTEXT"))
        XCTAssertTrue(context.contains("[13] Source 13"))
    }

    func testPlainTextCreatesParagraphsFromLongPauses() {
        let cues = [
            SubtitleCue(id: 1, start: 0, end: 1, text: "Hola"),
            SubtitleCue(id: 2, start: 1.2, end: 2, text: "mundo."),
            SubtitleCue(id: 3, start: 5, end: 6, text: "Nuevo párrafo.")
        ]
        XCTAssertEqual(SubtitleCue.plainText(cues), "Hola mundo.\n\nNuevo párrafo.\n")
    }

    func testAudioProjectRoundTripPreservesBothTracksAndTranslationSettings() throws {
        let document = AudioProjectDocument(
            version: 1, savedAt: .now, sourcePath: "/tmp/video.mp4",
            detectedLanguage: "en", targetLanguage: "Español",
            translationModel: "qwen", glossary: "ToshLLM = ToshLLM",
            originalCues: [SubtitleCue(id: 1, start: 0, end: 1, text: "Hello")],
            translatedCues: [SubtitleCue(id: 1, start: 0, end: 1, text: "Hola")]
        )
        let data = try JSONEncoder.audioProject.encode(document)
        let decoded = try JSONDecoder.audioProject.decode(AudioProjectDocument.self, from: data)
        XCTAssertEqual(decoded.translationModel, "qwen")
        XCTAssertEqual(decoded.glossary, "ToshLLM = ToshLLM")
        XCTAssertEqual(decoded.originalCues.first?.text, "Hello")
        XCTAssertEqual(decoded.translatedCues.first?.text, "Hola")
    }

    func testSubtitleTranslationParsesEveryExpectedSegment() throws {
        let cues = [
            SubtitleCue(id: 4, start: 0, end: 1, text: "Hello"),
            SubtitleCue(id: 9, start: 1, end: 2, text: "World")
        ]
        let content = #"{"translations":[{"id":4,"text":"Hola"},{"id":9,"text":"Mundo"}]}"#
        let response: [String: Any] = [
            "choices": [["message": ["content": content]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        let result = try AudioStudioController.translations(from: data, expectedCues: cues)
        XCTAssertEqual(result, [4: "Hola", 9: "Mundo"])
    }

    func testSubtitleTranslationRejectsMissingSegmentsWithSpecificError() throws {
        let cues = [
            SubtitleCue(id: 1, start: 0, end: 1, text: "One"),
            SubtitleCue(id: 2, start: 1, end: 2, text: "Two")
        ]
        let content = #"{"translations":[{"id":1,"text":"Uno"}]}"#
        let response: [String: Any] = [
            "choices": [["message": ["content": content]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        XCTAssertThrowsError(try AudioStudioController.translations(from: data, expectedCues: cues)) {
            XCTAssertTrue($0 is AudioTranslationError)
            XCTAssertTrue($0.localizedDescription.contains("subtítulos traducidos"))
        }
    }

    func testSubtitleTranslationRejectsGrosslyExpandedSegment() throws {
        let content = "{\"translations\":[{\"id\":1,\"text\":\"\(String(repeating: "invented ", count: 30))\"}]}"
        let response: [String: Any] = ["choices": [["message": ["content": content]]]]
        let data = try JSONSerialization.data(withJSONObject: response)
        let cues = [SubtitleCue(id: 1, start: 0, end: 1, text: "Hello")]
        XCTAssertThrowsError(try AudioStudioController.translations(from: data, expectedCues: cues))
    }

    func testAudioVADProfilesBecomeProgressivelyStricter() {
        let sensitive = AudioVADProfile.sensitive.calibration
        let balanced = AudioVADProfile.balanced.calibration
        let strict = AudioVADProfile.strict.calibration
        XCTAssertLessThan(sensitive.threshold, balanced.threshold)
        XCTAssertLessThan(balanced.threshold, strict.threshold)
        XCTAssertLessThan(sensitive.minSpeechDurationMS, balanced.minSpeechDurationMS)
        XCTAssertLessThan(balanced.minSpeechDurationMS, strict.minSpeechDurationMS)
        XCTAssertEqual(AudioVADProfile.defaultProfile, .balanced)
    }

    func testCustomVADCalibrationIsClampedBeforeLaunchingWhisper() {
        let calibration = AudioVADCalibration.custom(
            threshold: 2, minSpeechDurationMS: 1,
            minSilenceDurationMS: 9_000, maxSpeechDurationSeconds: 2,
            speechPadMS: 9_000
        )
        XCTAssertEqual(calibration.threshold, 0.95)
        XCTAssertEqual(calibration.minSpeechDurationMS, 100)
        XCTAssertEqual(calibration.minSilenceDurationMS, 2_000)
        XCTAssertEqual(calibration.maxSpeechDurationSeconds, 10)
        XCTAssertEqual(calibration.speechPadMS, 500)
    }

    func testCustomVADPreferencesPersistThroughSettingsKeys() {
        guard let defaults = UserDefaults(suiteName: "AudioVADPreferencesTests") else {
            return XCTFail("Unable to create isolated defaults")
        }
        defaults.removePersistentDomain(forName: "AudioVADPreferencesTests")
        defer { defaults.removePersistentDomain(forName: "AudioVADPreferencesTests") }
        defaults.set(AudioVADMode.calibrated.rawValue, forKey: SettingsKeys.audioVADMode)
        defaults.set(AudioVADProfile.custom.rawValue, forKey: SettingsKeys.audioVADProfile)
        defaults.set(0.65, forKey: SettingsKeys.audioVADThreshold)
        defaults.set(600.0, forKey: SettingsKeys.audioVADMinSpeechMS)
        defaults.set(350.0, forKey: SettingsKeys.audioVADMinSilenceMS)
        defaults.set(20.0, forKey: SettingsKeys.audioVADMaxSpeechSeconds)
        defaults.set(40.0, forKey: SettingsKeys.audioVADSpeechPadMS)

        let configuration = AudioVADPreferences.configuration(defaults: defaults)
        guard let calibration = configuration.calibration else {
            return XCTFail("Missing persisted calibration")
        }
        XCTAssertEqual(configuration.mode, .calibrated)
        XCTAssertEqual(calibration.threshold, 0.65)
        XCTAssertEqual(calibration.minSpeechDurationMS, 600)
        XCTAssertEqual(calibration.minSilenceDurationMS, 350)
        XCTAssertEqual(calibration.maxSpeechDurationSeconds, 20)
        XCTAssertEqual(calibration.speechPadMS, 40)
    }

    func testAudioVADDefaultsToNativeWhisperValues() {
        guard let defaults = UserDefaults(suiteName: "AudioVADDefaultTests") else {
            return XCTFail("Unable to create isolated defaults")
        }
        defaults.removePersistentDomain(forName: "AudioVADDefaultTests")
        defer { defaults.removePersistentDomain(forName: "AudioVADDefaultTests") }
        let configuration = AudioVADPreferences.configuration(defaults: defaults)
        XCTAssertEqual(configuration.mode, .standard)
        XCTAssertNil(configuration.calibration)
    }

    func testWhisperVADModelMatchesUpstreamArtifact() {
        XCTAssertEqual(WhisperVADModel.fileName, "ggml-silero-v6.2.0.bin")
        XCTAssertEqual(WhisperVADModel.sizeKB, 864)
        XCTAssertTrue(WhisperVADModel.downloadURL.hasSuffix("/ggml-silero-v6.2.0.bin"))
    }
}

final class DynamicMoeOptimizationTests: XCTestCase {
    func testCandidateSlotsFollowEachModelsExpertCount() {
        let qwen = DynamicMoeModelInfo(layerCount: 40, expertCount: 256, activeExpertCount: 8)
        XCTAssertEqual(BenchmarkController.dynamicMoeCandidateSlots(model: qwen, maximum: 75),
                       [8, 16, 32, 64, 75])
        XCTAssertEqual(BenchmarkController.dynamicMoeCandidateSlots(model: qwen, maximum: 132),
                       [8, 16, 32, 64, 76], "automatic profiling must not approach a full bank")

        let gptOSS = DynamicMoeModelInfo(layerCount: 24, expertCount: 32, activeExpertCount: 4)
        XCTAssertEqual(BenchmarkController.dynamicMoeCandidateSlots(model: gptOSS, maximum: 32),
                       [4, 8, 9])
    }

    func testHotMapValidatorAcceptsLegacyAndAdaptiveCounts() throws {
        let directory = FileManager.default.temporaryDirectory
        let legacy = directory.appendingPathComponent("tosh-dmoe-legacy-\(UUID().uuidString).map")
        let adaptive = directory.appendingPathComponent("tosh-dmoe-adaptive-\(UUID().uuidString).map")
        defer {
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: adaptive)
        }
        try "0 2 0 3 1\n".write(to: legacy, atomically: true, encoding: .utf8)
        try "0 2:91 0:47 3:12 1:1\n".write(to: adaptive, atomically: true, encoding: .utf8)

        XCTAssertTrue(BenchmarkController.dynamicMoeHotMapIsValid(legacy, expertCount: 4))
        XCTAssertTrue(BenchmarkController.dynamicMoeHotMapIsValid(adaptive, expertCount: 4))
    }
}

// MARK: - Memory estimator

final class EstimatorTests: XCTestCase {
    /// Reference hardware: the development machine (RX 6700 XT 12 GB + 32 GB RAM).
    private let referenceHW = HardwareInfo(
        cpuBrand: "Test CPU", physicalCores: 6, logicalCores: 12,
        ramGB: 32, arch: "x86_64", model: "", osVersion: "",
        gpus: [GPUDevice(index: 0, name: "Test GPU", vramMB: 12868)])

    private func dflashPlan(ncmoe: Int, ctx: Int) -> DflashMemoryPlan {
        DflashMemoryPlanner.plan(
            vramGB: 12272.0 / 1024, reserveGB: 1,
            baseFileGB: 20_893_015_008.0 / 1_073_741_824,
            baseLayers: 40, ncmoe: ncmoe, ctx: ctx, mainKVScale: 1,
            draftFileGB: 421_060_800.0 / 1_073_741_824,
            draftLayers: 7,
            draftKVBytesPerToken: 13_056)
    }

    func testDflashPlannerUsesNcmoeToProtectVRAM() {
        let tight = dflashPlan(ncmoe: 26, ctx: 16_384)
        XCTAssertNil(tight.gpuLayers, "ncmoe 26 at 16K exceeds the 1 GiB reserve")

        let safe = dflashPlan(ncmoe: 28, ctx: 16_384)
        XCTAssertEqual(safe.gpuLayers, 7)
        XCTAssertLessThanOrEqual(safe.estimatedVRAMGB, safe.budgetGB)
    }

    func testDflashPlannerRejectsContextWhoseFixedBuffersDoNotFit() {
        let plan = dflashPlan(ncmoe: 28, ctx: 32_768)
        XCTAssertNil(plan.gpuLayers)
        XCTAssertGreaterThan(plan.estimatedVRAMGB, plan.budgetGB)
    }

    func testDflashPlannerAccountsForEightKContext() {
        XCTAssertNil(dflashPlan(ncmoe: 26, ctx: 8_192).gpuLayers)
        XCTAssertEqual(dflashPlan(ncmoe: 28, ctx: 8_192).gpuLayers, 7)
    }

    func testDflashPlannerAllowsThirtyTwoKWhenVRAMIsLargeEnough() {
        let plan = DflashMemoryPlanner.plan(
            vramGB: 16, reserveGB: 1,
            baseFileGB: 20_893_015_008.0 / 1_073_741_824,
            baseLayers: 40, ncmoe: 26,
            ctx: 32_768, mainKVScale: 1,
            draftFileGB: 421_060_800.0 / 1_073_741_824,
            draftLayers: 7,
            draftKVBytesPerToken: 13_056)
        XCTAssertEqual(plan.gpuLayers, 7)
        XCTAssertLessThanOrEqual(plan.estimatedVRAMGB, plan.budgetGB)
    }

    func testDflashPlannerCanSelectPartialDraftOffload() {
        let plan = DflashMemoryPlanner.plan(
            vramGB: 11.75, reserveGB: 1,
            baseFileGB: 19.45, baseLayers: 40, ncmoe: 28,
            ctx: 16_384, mainKVScale: 1,
            draftFileGB: 0.392, draftLayers: 7,
            draftKVBytesPerToken: 13_056)
        guard let layers = plan.gpuLayers else { return XCTFail("expected partial DFlash offload") }
        XCTAssertTrue((0..<7).contains(layers))
        XCTAssertLessThanOrEqual(plan.estimatedVRAMGB, plan.budgetGB)
    }

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

    func testNcmoeOverrideDrivesEstimate() {
        // A user-set offload must be mirrored in the estimate: more layers on CPU
        // means a lower suggested ncmoe reflected back and a slower expected speed.
        let spec = ModelSpec(fileGB: 19.5, paramsB: 35.4, layers: 40, isMoE: true)
        let auto = Estimator.estimate(spec: spec, hw: referenceHW)
        let forced = Estimator.estimate(spec: spec, hw: referenceHW, ncmoeOverride: 36)
        XCTAssertEqual(forced.suggestedNcmoe, 36)
        XCTAssertGreaterThan(forced.suggestedNcmoe, auto.suggestedNcmoe)
        XCTAssertGreaterThan(forced.ramGB, auto.ramGB, "more CPU offload needs more RAM")
        XCTAssertNotEqual(forced.expectedSpeed, auto.expectedSpeed)
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

    func testIntegratedGPUExcludedFromSplitBudget() {
        // An Intel iGPU next to two discrete cards must not inflate the split
        // budget nor count as a split device (it is never auto-selected).
        let withIGPU = HardwareInfo(
            cpuBrand: "Test", physicalCores: 16, logicalCores: 32,
            ramGB: 96, arch: "x86_64", model: "", osVersion: "",
            gpus: [GPUDevice(index: 0, name: "GPU0", vramMB: 16368),
                   GPUDevice(index: 1, name: "GPU1", vramMB: 16368),
                   GPUDevice(index: 2, name: "Intel UHD 630", vramMB: 1024, isIntegrated: true)])
        XCTAssertEqual(withIGPU.combinedVramGB, 2 * 16368.0 / 1024, accuracy: 0.01)
        let spec = ModelSpec(fileGB: 19.5, paramsB: 35.4, layers: 40, isMoE: true)
        let split = Estimator.estimate(spec: spec, hw: withIGPU, multiGPU: true)
        XCTAssertEqual(split.level, .ideal)
        XCTAssertEqual(split.suggestedNcmoe, 0)
        // iGPU-only Mac: the fallback keeps the old behavior instead of a zero budget.
        let igpuOnly = HardwareInfo(
            cpuBrand: "Test", physicalCores: 4, logicalCores: 8,
            ramGB: 16, arch: "x86_64", model: "", osVersion: "",
            gpus: [GPUDevice(index: 0, name: "Intel Iris", vramMB: 1536, isIntegrated: true)])
        XCTAssertEqual(igpuOnly.combinedVramGB, 1536.0 / 1024, accuracy: 0.01)
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

final class ResumableDownloadTests: XCTestCase {
    private final class RangeProtocol: URLProtocol, @unchecked Sendable {
        static let payload = Data((0..<(256 * 1024)).map { UInt8($0 % 251) })
        static let lock = NSLock()
        nonisolated(unsafe) static var observedRanges: [String?] = []

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "resume.test"
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let range = request.value(forHTTPHeaderField: "Range")
            Self.lock.lock(); Self.observedRanges.append(range); Self.lock.unlock()
            let offset = range.flatMap { Int($0.dropFirst("bytes=".count).dropLast()) } ?? 0
            let headers: [String: String]
            let status: Int
            let body: Data
            if offset > 0 {
                status = 206
                body = Self.payload.suffix(from: offset)
                headers = [
                    "Content-Length": String(body.count),
                    "Content-Range": "bytes \(offset)-\(Self.payload.count - 1)/\(Self.payload.count)"
                ]
            } else {
                status = 200
                body = Self.payload.prefix(64 * 1024)
                headers = ["Content-Length": String(Self.payload.count)]
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            // Stall the initial response so the test can pause it.
            if offset > 0 { client?.urlProtocolDidFinishLoading(self) }
        }

        override func stopLoading() {}

        static func reset() {
            lock.lock(); observedRanges = []; lock.unlock()
        }

        static func ranges() -> [String?] {
            lock.lock(); defer { lock.unlock() }
            return observedRanges
        }
    }

    @MainActor
    private func waitUntil(_ predicate: @escaping () -> Bool,
                           timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    func testResumeAlwaysUsesStableURLAndByteRange() {
        let remote = URL(string: "https://huggingface.co/owner/repo/resolve/main/model.gguf")!
        let fresh = ResumableDownload.request(remote: remote, partialBytes: 0)
        XCTAssertEqual(fresh.url, remote)
        XCTAssertNil(fresh.value(forHTTPHeaderField: "Range"))

        let resumed = ResumableDownload.request(remote: remote, partialBytes: 12_345)
        XCTAssertEqual(resumed.url, remote, "a stale presigned redirect must never be persisted")
        XCTAssertEqual(resumed.value(forHTTPHeaderField: "Range"), "bytes=12345-")
        XCTAssertEqual(resumed.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testResumeAppendsOnlyAResponseForTheRequestedOffset() {
        XCTAssertEqual(
            ResumableDownload.responsePlan(statusCode: 206,
                                            contentRange: "bytes 12345-19999/20000",
                                            contentLength: 7_655,
                                            partialBytes: 12_345,
                                            expectedBytes: 20_000),
            .append(totalBytes: 20_000))
        XCTAssertEqual(
            ResumableDownload.responsePlan(statusCode: 206,
                                            contentRange: "bytes 0-19999/20000",
                                            contentLength: 20_000,
                                            partialBytes: 12_345,
                                            expectedBytes: 20_000),
            .reject)
    }

    func testServerIgnoringRangeRestartsInsteadOfCorruptingPartialFile() {
        XCTAssertEqual(
            ResumableDownload.responsePlan(statusCode: 200, contentRange: nil,
                                            contentLength: 20_000, partialBytes: 12_345,
                                            expectedBytes: 20_000),
            .restart(totalBytes: 20_000))
        XCTAssertEqual(
            ResumableDownload.responsePlan(statusCode: 416, contentRange: "bytes */20000",
                                            contentLength: 0, partialBytes: 20_000,
                                            expectedBytes: 20_000),
            .alreadyComplete)
        XCTAssertEqual(
            ResumableDownload.responsePlan(statusCode: 403, contentRange: nil,
                                            contentLength: 0, partialBytes: 12_345,
                                            expectedBytes: 20_000),
            .reject)
    }

    @MainActor
    func testDownloadItemPausesAndResumesFromPartialFile() async throws {
        RangeProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RangeProtocol.self]
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("model.gguf")
        let item = DownloadItem(remote: URL(string: "https://resume.test/model.gguf")!,
                                destination: destination, sessionConfiguration: config)

        let receivedPartial = await waitUntil { item.receivedMB > 0 }
        XCTAssertTrue(receivedPartial)
        item.pause()
        XCTAssertEqual(item.phase, .paused)
        item.resume()
        let completed = await waitUntil({ item.finished }, timeout: 5)
        XCTAssertTrue(completed)
        XCTAssertEqual(try Data(contentsOf: destination), RangeProtocol.payload)

        let ranges = RangeProtocol.ranges()
        XCTAssertEqual(ranges.count, 2)
        XCTAssertNil(ranges[0])
        XCTAssertEqual(ranges[1], "bytes=65536-")
    }
}

final class DflashPolicyTests: XCTestCase {
    func testAutoAllowsDenseAndFullGPUModels() {
        XCTAssertTrue(DflashPolicy.autoEligible(isMoE: true, ncmoe: 1))
        XCTAssertTrue(DflashPolicy.autoEligible(isMoE: true, ncmoe: 0))
        XCTAssertTrue(DflashPolicy.autoEligible(isMoE: false, ncmoe: 0))
    }

    func testRuntimeWarningRequiresThreeCriticalSamples() {
        XCTAssertFalse(DflashPolicy.shouldWarn(fractions: [0.96, 0.94, 0.97]))
        XCTAssertTrue(DflashPolicy.shouldWarn(fractions: [0.96, 0.95, 0.94, 0.97]))
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
        // With the attention streamed instead of built in full, 12 GB fits far more than it
        // used to: 2048x2048 measured 2757 MB of graph and 2560x1440 measured 2423 (08-19).
        XCTAssertTrue(ImageGenLimits.fits(width: 1600, height: 900, vramGB: 12, residentGB: r))
        XCTAssertTrue(ImageGenLimits.fits(width: 2048, height: 2048, vramGB: 12, residentGB: r))
        // 8 GB now reaches 1600x900 (966 MB of graph, measured), but not a 3072 square.
        XCTAssertTrue(ImageGenLimits.fits(width: 1600, height: 900, vramGB: 8, residentGB: r))
        XCTAssertFalse(ImageGenLimits.fits(width: 3072, height: 3072, vramGB: 8, residentGB: r))
        // A heavier model (larger resident) needs more VRAM for the same frame.
        XCTAssertGreaterThan(
            ImageGenLimits.estVRAMGB(px: 1600*900, residentGB: ImageGenCatalog.fluxSchnell.residentGB, attnVRAMSq: 0),
            ImageGenLimits.estVRAMGB(px: 1600*900, residentGB: r, attnVRAMSq: 0))
        // The offered base sizes still scale with the card at the low end, where the
        // resident weights, not the graph, are what a small card runs out of.
        let max6 = ImageGenLimits.baseSizes(vramGB: 6, residentGB: r).max() ?? 0
        let max12 = ImageGenLimits.baseSizes(vramGB: 12, residentGB: r).max() ?? 0
        XCTAssertLessThan(max6, max12)
        // On a card without the attention kernels (a 64-wide one in safe mode) the score
        // matrix is built whole again, so the same frame stops fitting and the estimate has
        // to say so: SD 1.5 measured 2.7 GB of scores at 768 before the kernels covered it.
        XCTAssertFalse(ImageGenLimits.fits(width: 2048, height: 2048, vramGB: 12,
                                           residentGB: ImageGenCatalog.sd15.residentGB,
                                           attnVRAMSq: ImageGenCatalog.sd15.attnVRAMSq,
                                           streamedAttention: false))
        XCTAssertTrue(ImageGenLimits.fits(width: 2048, height: 2048, vramGB: 12,
                                          residentGB: ImageGenCatalog.sd15.residentGB,
                                          attnVRAMSq: ImageGenCatalog.sd15.attnVRAMSq))
        // Safe mode only takes the kernels away from the 64-wide cards.
        XCTAssertTrue(ImageGenLimits.streamsAttention(gpuName: "AMD Radeon RX 6700 XT",
                                                     extraArgs: "GGML_METAL_WAVE64_SAFEMODE=1"))
        XCTAssertFalse(ImageGenLimits.streamsAttention(gpuName: "AMD Radeon RX Vega 64",
                                                      extraArgs: "GGML_METAL_WAVE64_SAFEMODE=1"))
        XCTAssertTrue(ImageGenLimits.streamsAttention(gpuName: "AMD Radeon RX Vega 64", extraArgs: ""))
    }

    func testVideoVRAMEstimateSeparatesSamplingAndDecode() {
        let estimated = VideoGenLimits.estVRAMGB(
            px: 1280 * 704, frames: 33,
            samplingResidentGB: VideoGenCatalog.wan22TI2V5B.diffusionResidentGB,
            decodeResidentGB: VideoGenCatalog.wan22TI2V5B.decodeResidentGB)
        XCTAssertGreaterThan(estimated, 10.5)
        XCTAssertLessThan(estimated, 12.0)
    }

    func testWan22VideoStageWeightsMatchCatalog() {
        XCTAssertEqual(VideoGenCatalog.wan22TI2V5B.diffusionResidentGB, 10.0,
                       accuracy: 0.001)
        XCTAssertEqual(VideoGenCatalog.wan22TI2V5B.decodeResidentGB, 1.41,
                       accuracy: 0.001)
        let lat = Double(VideoGenLimits.latentFrames(33))
        let decodePeak = VideoGenCatalog.wan22TI2V5B.decodeResidentGB
            + (3320 + 10 * lat) / 1024
            + VideoGenCatalog.wan22TI2V5B.decodeWorkspaceAdjustmentGB
        XCTAssertEqual(decodePeak, 5.09, accuracy: 0.03)

        func measuredEstimate(_ frames: Int) -> Double {
            VideoGenLimits.estVRAMGB(
                px: 1280 * 704, frames: frames,
                samplingResidentGB: VideoGenCatalog.wan22TI2V5B.diffusionResidentGB,
                decodeResidentGB: VideoGenCatalog.wan22TI2V5B.decodeResidentGB,
                decodeWorkspaceAdjustmentGB: VideoGenCatalog.wan22TI2V5B.decodeWorkspaceAdjustmentGB,
                samplingWorkspaceBaseMB: VideoGenCatalog.wan22TI2V5B.samplingWorkspaceBaseMB,
                samplingWorkspaceCoefficient: VideoGenCatalog.wan22TI2V5B.samplingWorkspaceCoefficient)
        }
        XCTAssertEqual(measuredEstimate(33), 10.71, accuracy: 0.04)
        XCTAssertEqual(measuredEstimate(49), 11.00, accuracy: 0.04)
    }

    func testWan22LongFrameSettingsRecommend16GB() {
        XCTAssertNil(VideoGenLimits.recommendedVRAMGB(model: VideoGenCatalog.wan22TI2V5B,
                                                      frames: 33))
        XCTAssertEqual(VideoGenLimits.recommendedVRAMGB(model: VideoGenCatalog.wan22TI2V5B,
                                                        frames: 49), 16)
        XCTAssertEqual(VideoGenLimits.recommendedVRAMGB(model: VideoGenCatalog.wan22TI2V5B,
                                                        frames: 81), 16)
    }

    func testWan22UsesOfficialInferenceValuesRepresentableByEngine() {
        XCTAssertEqual(VideoGenCatalog.wan22TI2V5B.defaultSteps, 50)
        XCTAssertEqual(VideoGenCatalog.wan22TI2V5B.cfgScale, 5.0, accuracy: 0.001)
        XCTAssertEqual(VideoGenCatalog.wan22TI2V5B.flowShift, 5.0, accuracy: 0.001)
        XCTAssertEqual(VideoGenCatalog.wan22TI2V5B.fps, 24)
        XCTAssertEqual(VideoGenCatalog.wan22TI2V5B.nativeFrames, 121)
    }

    func testWan21UsesOfficialInferenceValuesRepresentableByEngine() {
        let t2v = VideoGenCatalog.wan21T2V13B
        XCTAssertEqual(t2v.defaultSteps, 50)
        XCTAssertEqual(t2v.cfgScale, 5.0, accuracy: 0.001)
        XCTAssertEqual(t2v.flowShift, 5.0, accuracy: 0.001)
        XCTAssertEqual(t2v.fps, 16)
        XCTAssertEqual(t2v.nativeFrames, 81)
        XCTAssertEqual(t2v.sizes.map(\.label), ["832x480", "480x832"])

        let i2v = VideoGenCatalog.wan21I2V14B
        XCTAssertEqual(i2v.defaultSteps, 40)
        XCTAssertEqual(i2v.cfgScale, 5.0, accuracy: 0.001)
        XCTAssertEqual(i2v.flowShift, 3.0, accuracy: 0.001)
        XCTAssertEqual(i2v.fps, 16)
        XCTAssertEqual(i2v.nativeFrames, 81)
        XCTAssertTrue(i2v.supportsI2V)
        XCTAssertEqual(i2v.sizes.map(\.label), ["832x480", "480x832"])
        XCTAssertEqual(t2v.negativePrompt, VideoGenCatalog.defaultNegative)
        XCTAssertEqual(i2v.negativePrompt, VideoGenCatalog.defaultNegative)
    }

    func testHunyuan15UsesOfficialRecipeAndCompleteConditioning() {
        let model = VideoGenCatalog.hunyuanVideo15
        XCTAssertEqual(model.defaultSteps, 50)
        XCTAssertEqual(model.cfgScale, 6.0, accuracy: 0.001)
        XCTAssertEqual(model.flowShift, 7.0, accuracy: 0.001)
        XCTAssertEqual(model.fps, 24)
        XCTAssertEqual(model.nativeFrames, 121)
        XCTAssertFalse(model.supportsI2V)
        XCTAssertTrue(model.components.contains {
            $0.fileName == "byt5_small_glyphxl_fp16.safetensors"
        })
        XCTAssertTrue(model.negativePrompt.isEmpty)
        XCTAssertEqual(VideoGenCatalog.ltx23Distilled.negativePrompt,
                       "worst quality, low quality, blurry, distorted, artifacts")
    }

    func testCommandBufferSplitClearsWatchdog() {
        // 1024x1024 runs as one buffer; larger frames split, capped at 4.
        XCTAssertEqual(ImageGenLimits.nCB(width: 1024, height: 1024), 1)
        XCTAssertGreaterThan(ImageGenLimits.nCB(width: 1600, height: 900), 1)
        XCTAssertLessThanOrEqual(ImageGenLimits.nCB(width: 1600, height: 1600), 4)
    }

    func testQueueTargetingRunsOnlyOnItsOwnInstance() {
        var a = ImageInstanceConfig(); a.id = UUID()
        var b = ImageInstanceConfig(); b.id = UUID()
        let existingIDs: Set<UUID> = [a.id, b.id]

        // Untargeted: runnable anywhere.
        let anyJob = QueuedPrompt(text: "x")
        XCTAssertTrue(ImageGenPool.runnable(anyJob, on: a, existingIDs: existingIDs))
        XCTAssertTrue(ImageGenPool.runnable(anyJob, on: b, existingIDs: existingIDs))

        // Targeted at A: only runnable on A, not on B.
        let targetedJob = QueuedPrompt(text: "x", targetInstanceID: a.id)
        XCTAssertTrue(ImageGenPool.runnable(targetedJob, on: a, existingIDs: existingIDs))
        XCTAssertFalse(ImageGenPool.runnable(targetedJob, on: b, existingIDs: existingIDs))

        // Target removed from the pool: falls back to "any free instance".
        let orphanedJob = QueuedPrompt(text: "x", targetInstanceID: UUID())
        XCTAssertTrue(ImageGenPool.runnable(orphanedJob, on: a, existingIDs: existingIDs))
        XCTAssertTrue(ImageGenPool.runnable(orphanedJob, on: b, existingIDs: existingIDs))
    }

    func testSplitBackendSpec() {
        XCTAssertEqual(ImageGenerator.splitBackendSpec(overriding: nil),
                       "diffusion=mtl0,te=mtl1,vae=mtl1")
        // A model's own assignment wins per module (qwen-image forces vae=cpu).
        XCTAssertEqual(ImageGenerator.splitBackendSpec(overriding: "vae=cpu"),
                       "diffusion=mtl0,te=mtl1,vae=cpu")
        // Synonyms sd-cli accepts must override the same module, not add a duplicate.
        XCTAssertEqual(ImageGenerator.splitBackendSpec(overriding: "clip=cpu, tae=cpu"),
                       "diffusion=mtl0,te=cpu,vae=cpu")
    }

    func testAuxGPUResolution() {
        var c = ImageInstanceConfig()
        c.gpuIndex = 0
        c.auxGPUIndex = 1
        XCTAssertEqual(c.auxGPU(gpuCount: 2), 1)
        XCTAssertNil(c.auxGPU(gpuCount: 1))    // slot gone (GPU unplugged)
        c.auxGPUIndex = 0
        XCTAssertNil(c.auxGPU(gpuCount: 2))    // same as main = split off
        c.auxGPUIndex = -1
        XCTAssertNil(c.auxGPU(gpuCount: 2))
    }
}

// MARK: - Server configuration

final class ServerSettingsTests: XCTestCase {
    private func makeSettings() -> ServerSettings {
        ServerSettings(serverBinary: "/usr/bin/true", modelPath: "/tmp/m.gguf", port: 8080,
                       ngl: 99, ncmoe: 24, ctx: 16384, threads: 6, flashAttn: "auto",
                       noMmap: true, jinja: true,
                       vramReserveMB: 1024, gpuIndex: -1, extraArgs: "",
                       cacheTypeK: "f16", cacheTypeV: "f16", mlock: false)
    }

    private func writeMinimalMoEGGUF(_ url: URL) throws {
        var data = Data("GGUF".utf8)
        func u32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func u64(_ value: UInt64) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func string(_ value: String) {
            u64(UInt64(value.utf8.count)); data.append(contentsOf: value.utf8)
        }
        let values: [(String, UInt32)] = [
            ("qwen35moe.block_count", 40),
            ("qwen35moe.expert_count", 256),
            ("qwen35moe.expert_used_count", 8),
        ]
        u32(3); u64(0); u64(UInt64(values.count))
        for (key, value) in values {
            string(key); u32(4); u32(value)
        }
        try data.write(to: url)
    }

    func testBaseArguments() {
        let args = makeSettings().arguments
        XCTAssertEqual(args[args.firstIndex(of: "--load-mode")! + 1], "none")
        XCTAssertTrue(args.contains("--jinja"))
        XCTAssertTrue(args.contains("--n-cpu-moe"))
        XCTAssertEqual(args[args.firstIndex(of: "--host")! + 1], "127.0.0.1")
        XCTAssertFalse(args.contains("-ctk"), "f16 no debe emitir -ctk")
        XCTAssertFalse(args.contains("--mlock"), "the deprecated pair let mlock decide mmap")
        // The engine's 8 GiB host prompt cache must always be capped.
        XCTAssertEqual(args[args.firstIndex(of: "--cache-ram")! + 1], "2048")
        XCTAssertFalse(args.contains("--reasoning-format"), "inline reasoning is opt-in")
        // One slot by default: retries resume aborted prefills (VS Code).
        XCTAssertEqual(args[args.firstIndex(of: "--parallel")! + 1], "1")
        XCTAssertEqual(args[args.firstIndex(of: "--cache-reuse")! + 1], "256")
    }

    func testDynamicMoeIsCompiledButRequiresPrivateUIFlagAndToggle() throws {
        let model = FileManager.default.temporaryDirectory
            .appendingPathComponent("tosh-dynamic-moe-\(UUID().uuidString).gguf")
        try writeMinimalMoEGGUF(model)
        defer { try? FileManager.default.removeItem(at: model) }
        var s = makeSettings()
        s.modelPath = model.path
        s.dynamicMoe = true
        s.dynamicMoeSlots = 16
        s.dynamicMoePrefetch = 7

        XCTAssertFalse(s.effectiveDynamicMoe)
        XCTAssertNil(s.environment["TOSH_MOE_MODE"])
        XCTAssertFalse(s.arguments.contains("-ot"))
        XCTAssertEqual(s.arguments[s.arguments.firstIndex(of: "--n-cpu-moe")! + 1], "24")

        s.extraArgs = "TOSH_MOE_UI=1 TOSH_MOE_SLOTS=999"

        XCTAssertTrue(s.effectiveDynamicMoe)
        XCTAssertEqual(s.environment["TOSH_MOE_MODE"], "cache")
        XCTAssertEqual(s.environment["TOSH_MOE_SLOTS"], "16")
        XCTAssertEqual(s.environment["TOSH_MOE_CPU_BANK"], "1")
        XCTAssertEqual(s.environment["GGML_SCHED_PREFETCH_EXPERTS"], "7")
        XCTAssertEqual(s.environment["GGML_METAL_NCB"], "8")
        XCTAssertFalse(s.arguments.contains("--n-cpu-moe"), "the cache decides the split on its own")
        XCTAssertEqual(s.arguments[s.arguments.firstIndex(of: "--load-mode")! + 1], "mlock")
        XCTAssertEqual(s.arguments[s.arguments.firstIndex(of: "-ot")! + 1],
                       ServerSettings.dynamicMoeTensorOverride)
        XCTAssertFalse(s.benchmarkArguments.contains("-ncmoe"))
        XCTAssertEqual(s.benchmarkArguments[s.benchmarkArguments.firstIndex(of: "-ot")! + 1],
                       ServerSettings.dynamicMoeTensorOverride)

        s.routerMode = true
        XCTAssertFalse(s.effectiveDynamicMoe, "router presets cannot carry the tensor override")
        XCTAssertNil(s.environment["TOSH_MOE_MODE"])
    }

    func testDynamicMoeAutoSelectsCacheOnlyWhenItProvidesAUsefulFit() {
        let gib = UInt64(1024 * 1024 * 1024)
        func route(
            isMoE: Bool = true,
            modelGB: UInt64 = 12,
            vramMB: Int = 12_288,
            reserveMB: Int = 1_024,
            ramGB: UInt64 = 32,
            hasDiscreteGPU: Bool = true,
            splitOrRouter: Bool = false
        ) -> DynamicMoeAutoRoute {
            ServerSettings.resolveDynamicMoeAuto(
                isMoE: isMoE,
                modelBytes: modelGB * gib,
                gpuVRAMMB: vramMB,
                reserveMB: reserveMB,
                physicalRAMBytes: ramGB * gib,
                hasDiscreteGPU: hasDiscreteGPU,
                splitOrRouter: splitOrRouter)
        }

        // 12 GiB does not fit in 12 GiB VRAM after the 1 GiB user reserve and
        // 512 MiB runtime margin, while 32 GiB RAM can safely pin its bank.
        XCTAssertEqual(route(), .cache)
        XCTAssertEqual(route(modelGB: 8), .normalFitsVRAM)
        XCTAssertEqual(route(ramGB: 14), .normalInsufficientRAM)
        XCTAssertEqual(route(isMoE: false), .normalDense)
        XCTAssertEqual(route(hasDiscreteGPU: false), .normalUnsupportedGPU)
        XCTAssertEqual(route(splitOrRouter: true), .normalSplitOrRouter)
        XCTAssertEqual(ServerSettings.resolveDynamicMoeAuto(
            isMoE: true, modelBytes: 0, gpuVRAMMB: 12_288, reserveMB: 1_024,
            physicalRAMBytes: 32 * gib, hasDiscreteGPU: true, splitOrRouter: false),
                       .normalMissingModel)
    }

    func testDynamicMoeSlotsFollowEachModelsMetadataAndVRAMBudget() throws {
        let gib = UInt64(1024 * 1024 * 1024)
        func plan(gb: Double, layers: Int, experts: Int, active: Int) throws -> DynamicMoeSlotPlan {
            try XCTUnwrap(ServerSettings.resolveDynamicMoeSlots(
                modelBytes: UInt64(gb * Double(gib)),
                model: DynamicMoeModelInfo(layerCount: layers, expertCount: experts,
                                           activeExpertCount: active),
                gpuVRAMMB: 12_288, reserveMB: 1_024, prefetch: 4))
        }

        let qwen = try plan(gb: 11.44, layers: 40, experts: 256, active: 8)
        XCTAssertEqual(qwen.automaticSlots, 8)
        XCTAssertEqual(qwen.minimumSlots, 8)
        XCTAssertEqual(qwen.maximumSlots, 256)
        XCTAssertGreaterThanOrEqual(qwen.recommendedMaximumSlots, 114)

        let gptOSS = try plan(gb: 11.0, layers: 24, experts: 32, active: 4)
        XCTAssertEqual(gptOSS.automaticSlots, 4)
        XCTAssertEqual(gptOSS.maximumSlots, 32)
        XCTAssertEqual(gptOSS.clamped(114), 32)

        let olmoe = try plan(gb: 4.5, layers: 16, experts: 64, active: 8)
        XCTAssertEqual(olmoe.automaticSlots, 8)
        XCTAssertEqual(olmoe.maximumSlots, 64)
        XCTAssertEqual(olmoe.clamped(4), 8)
    }

    func testDynamicMoeAutoRejectsAWorkingSetSmallerThanTopK() {
        let gib = UInt64(1024 * 1024 * 1024)
        XCTAssertNil(ServerSettings.resolveDynamicMoeSlots(
            modelBytes: 11 * gib,
            model: DynamicMoeModelInfo(layerCount: 24, expertCount: 32,
                                       activeExpertCount: 16),
            gpuVRAMMB: 3_072, reserveMB: 1_024, prefetch: 4))
    }

    func testDynamicMoeAutoKeepsDirectMetalBankInsideGPUWorkingSet() {
        let gib = UInt64(1024 * 1024 * 1024)
        XCTAssertTrue(ServerSettings.dynamicMoeHostBankFitsDirectMetal(
            modelBytes: UInt64(11.44 * Double(gib)), gpuVRAMMB: 12_288))
        XCTAssertFalse(ServerSettings.dynamicMoeHostBankFitsDirectMetal(
            modelBytes: UInt64(19.45 * Double(gib)), gpuVRAMMB: 12_288))
    }

    func testAgentToolsArgumentsAreEmittedExactlyOnce() {
        var settings = makeSettings()
        settings.jinja = false
        settings.agentToolsEnabled = true
        var args = settings.arguments
        XCTAssertEqual(args.filter { $0 == "--jinja" }.count, 1)
        XCTAssertEqual(args.filter { $0 == "--tools" }.count, 1)
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "all")

        settings.routerMode = true
        args = settings.arguments
        XCTAssertEqual(args.filter { $0 == "--jinja" }.count, 1)
        XCTAssertEqual(args.filter { $0 == "--tools" }.count, 1)
        XCTAssertEqual(args[args.firstIndex(of: "--tools")! + 1], "all")
        XCTAssertLessThanOrEqual(args.filter { $0 == "--path" }.count, 1)
    }

    func testAgentToolsArgumentsStayAbsentWhenDisabled() {
        var settings = makeSettings()
        settings.jinja = false
        settings.agentToolsEnabled = false
        XCTAssertFalse(settings.arguments.contains("--tools"))

        settings.routerMode = true
        XCTAssertFalse(settings.arguments.contains("--tools"))
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

    func testSlotSavePathFollowsLoadedVision() {
        var s = makeSettings()
        s.persistCache = true
        s.faAmd = true
        // No projector on disk for this model path: persistence stays on
        // regardless of the vision toggle.
        s.loadVision = true
        XCTAssertTrue(s.arguments.contains("--slot-save-path"))
        s.loadVision = false
        XCTAssertTrue(s.arguments.contains("--slot-save-path"))
        s.persistCache = false
        XCTAssertFalse(s.arguments.contains("--slot-save-path"))
    }

    func testBenchmarkDepthArgument() {
        var s = makeSettings()
        // Depth 0 (default) must not emit -d.
        XCTAssertNil(s.benchmarkArguments.firstIndex(of: "-d"))
        s.benchDepth = 4096
        let args = s.benchmarkArguments
        XCTAssertEqual(args[args.firstIndex(of: "-d")! + 1], "4096")
        s.benchDepth = -5
        XCTAssertEqual(s.benchDepthClamped, 0)
    }

    func testBenchResultLabels() {
        var r = BenchResult(date: .now, model: "m.gguf", ncmoe: 0, pp: 100, tg: 30)
        XCTAssertEqual(r.configLabel, "base")
        r.depth = 4096
        r.kind = "real"
        r.accept = 0.784
        XCTAssertTrue(r.configLabel.contains("d4096"))
        XCTAssertTrue(r.configLabel.contains("gen real"))
        XCTAssertTrue(r.configLabel.contains("MTP 78%"))
    }

    func testChatMessageDecodesWithoutMtpAccept() throws {
        // Pre-MTP-badge JSON (no mtpAccept key) must keep decoding.
        let json = #"{"id":"\#(UUID().uuidString)","role":"assistant","content":"hi","date":700000000}"#
        let msg = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        XCTAssertNil(msg.mtpAccept)
        XCTAssertEqual(msg.content, "hi")
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

    func testBenchmarkUsesTheServerLoadMode() {
        var s = makeSettings()
        s.mlock = true
        let args = s.benchmarkArguments
        XCTAssertEqual(args[args.firstIndex(of: "--load-mode")! + 1], "mlock",
                       "medir sin bloquear el modelo no da los números que entrega la app")
        XCTAssertFalse(args.contains("--mmap"), "flag obsoleto en el motor nuevo")
        s.mlock = false
        XCTAssertEqual(s.benchmarkArguments[s.benchmarkArguments.firstIndex(of: "--load-mode")! + 1], "none")
    }

    func testChatFontScaleStaysInRange() {
        XCTAssertEqual(ChatFont.clamp(1), 1)
        XCTAssertEqual(ChatFont.clamp(5), ChatFont.range.upperBound)
        XCTAssertEqual(ChatFont.clamp(0), ChatFont.range.lowerBound)
        // one step from either end must not escape it
        XCTAssertEqual(ChatFont.clamp(ChatFont.range.upperBound + ChatFont.step), ChatFont.range.upperBound)
        XCTAssertEqual(ChatFont.clamp(ChatFont.range.lowerBound - ChatFont.step), ChatFont.range.lowerBound)
        XCTAssertEqual(ChatFont.Base.body.points, 13, "el 100% debe seguir siendo el tamaño del sistema")
    }

    func testMlockKeepsMmapWhenAsked() {
        var s = makeSettings()
        s.noMmap = false
        s.mlock = true
        let args = s.arguments
        XCTAssertEqual(args[args.firstIndex(of: "--load-mode")! + 1], "mmap+mlock")
        s.mlock = false
        XCTAssertFalse(s.arguments.contains("--load-mode"), "sin ninguna opción, el motor decide")
    }

    func testKVQuantAndMlockArguments() {
        var s = makeSettings()
        s.cacheTypeK = "q8_0"
        s.cacheTypeV = "turbo3"
        s.mlock = true
        let args = s.arguments
        XCTAssertEqual(args[args.firstIndex(of: "-ctk")! + 1], "q8_0")
        XCTAssertEqual(args[args.firstIndex(of: "-ctv")! + 1], "turbo3")
        XCTAssertEqual(args[args.firstIndex(of: "--load-mode")! + 1], "mlock")
        XCTAssertTrue(args.contains("--cache-reuse"),
                      "TurboQuant has a dequantize/shift/requantize path")
        XCTAssertFalse(s.usesUnsupportedTurboQ4Mix)

        s.cacheTypeK = "q4_0"
        XCTAssertTrue(s.usesUnsupportedTurboQ4Mix)

        s.cacheTypeK = "turbo4"
        s.cacheTypeV = "q4_0"
        XCTAssertTrue(s.usesUnsupportedTurboQ4Mix)
    }

    func testExtraArgsAreAppended() {
        var s = makeSettings()
        s.extraArgs = #"--override-kv key=str:"two words""#
        let args = s.arguments
        XCTAssertTrue(args.contains("key=str:two words"))
    }

    func testMTPIsSkippedForModelsWithoutTheHead() {
        var s = makeSettings()
        s.ncmoe = 12
        s.modelPath = "/tmp/definitely-not-a-model.gguf"
        XCTAssertFalse(s.arguments.contains("--spec-type"),
                       "MTP must be silently skipped when the GGUF lacks the head")
    }

    func testMTPAppliesAutomaticallyWithExpertOffload() {
        var s = makeSettings()
        s.ncmoe = 12
        s.modelPath = makeGGUF(nextnLayers: 1, tensorName: "blk.0.nextn.eh_proj.weight").path
        XCTAssertTrue(s.arguments.contains("--spec-type"),
                      "MTP must apply automatically when the model has a head and experts are offloaded")
    }

    func testMTPAppliesAutomaticallyWithoutExpertOffload() {
        var s = makeSettings()
        s.ncmoe = 0
        s.specMTP = true
        s.modelPath = makeGGUF(nextnLayers: 1, tensorName: "blk.0.nextn.eh_proj.weight").path
        XCTAssertTrue(s.arguments.contains("--spec-type"),
                      "MTP must apply to dense and full-GPU models when the head is present")
    }

    func testStabilityEnvironment() {
        let env = makeSettings().environment
        XCTAssertNil(env["GGML_METAL_CONCURRENCY_DISABLE"],
                     "la concurrencia la decide el engine según el tipo de GPU, la app no la fija")
        XCTAssertEqual(env["GGML_METAL_VRAM_RESERVE_MB"], "1024")
        XCTAssertNil(env["GGML_METAL_DEVICE_INDEX"], "gpuIndex -1 no debe fijar índice")
        XCTAssertTrue(env["PATH"]?.contains("/usr/local/bin") == true)
        XCTAssertTrue(env["PATH"]?.contains("/opt/homebrew/bin") == true)
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

    func testTensorSplitModeReachesServerAndBenchmark() {
        var s = makeSettings()
        s.multiGPU = true
        s.splitMode = "tensor"

        XCTAssertEqual(s.arguments[s.arguments.firstIndex(of: "--split-mode")! + 1], "tensor")
        XCTAssertEqual(s.benchmarkArguments[s.benchmarkArguments.firstIndex(of: "--split-mode")! + 1], "tensor")

        s.splitMode = "capas"
        XCTAssertEqual(s.arguments[s.arguments.firstIndex(of: "--split-mode")! + 1], "layer",
                       "un valor guardado que el motor no acepta debe caer en layer")
    }

    func testFastHandOffOnlyTravelsWithASplit() {
        var s = makeSettings()
        XCTAssertNil(s.environment["TOSH_MGPU_EVENTS"], "sin reparto no hay traspaso entre GPUs")

        s.multiGPU = true
        XCTAssertEqual(s.environment["TOSH_MGPU_EVENTS"], "1")

        s.mgpuEvents = false
        XCTAssertNil(s.environment["TOSH_MGPU_EVENTS"])
    }

    func testLocalNetworkDiscoveryBindsServerToAllInterfaces() {
        var s = makeSettings()
        s.localNetworkDiscovery = true

        XCTAssertEqual(s.arguments[s.arguments.firstIndex(of: "--host")! + 1], "0.0.0.0")
    }

    /// Minimal GGUF: magic + v3 header, one uint32 KV (optional), one tensor info.
    private func makeGGUF(nextnLayers: UInt32?, tensorName: String) -> URL {
        var d = Data("GGUF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func str(_ s: String) { u64(UInt64(s.utf8.count)); d.append(contentsOf: Array(s.utf8)) }
        u32(3)                          // version
        u64(1)                          // tensor count
        u64(nextnLayers != nil ? 1 : 0) // kv count
        if let layers = nextnLayers {
            str("qwen35moe.nextn_predict_layers")
            u32(4)                      // GGUF_TYPE_UINT32
            u32(layers)
        }
        str(tensorName)                 // tensor info: name, n_dims, dims, type, offset
        u32(1); u64(8); u32(0); u64(0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtp-\(UUID().uuidString).gguf")
        try? d.write(to: url)
        return url
    }

    func testMTPDetectionReadsKeyValueAndTensors() {
        // Key present decides by value: 1 = MTP, 0 = stripped head (the common
        // quantizer case that used to false-positive on a bare "nextn" grep).
        XCTAssertTrue(ServerSettings.modelHasMTP(at: makeGGUF(nextnLayers: 1, tensorName: "blk.0.attn_q.weight").path))
        XCTAssertFalse(ServerSettings.modelHasMTP(at: makeGGUF(nextnLayers: 0, tensorName: "blk.0.attn_q.weight").path))
        // No key: the .nextn. tensor names decide.
        XCTAssertTrue(ServerSettings.modelHasMTP(at: makeGGUF(nextnLayers: nil, tensorName: "blk.0.nextn.eh_proj.weight").path))
        XCTAssertFalse(ServerSettings.modelHasMTP(at: makeGGUF(nextnLayers: nil, tensorName: "blk.0.attn_q.weight").path))
    }

    func testSeparateMTPAssistantIsHiddenPairedAndPassedAsDraft() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtp-pair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = dir.appendingPathComponent("gemma-4-E2B-it-UD-Q4_K_XL.gguf")
        let draft = dir.appendingPathComponent("mtp-gemma-4-E2B-it.gguf")
        try Data("base".utf8).write(to: base)
        try Data("draft".utf8).write(to: draft)

        let models = LocalModel.scan(in: dir)
        let canonicalBase = base.resolvingSymlinksInPath().path
        let canonicalDraft = draft.resolvingSymlinksInPath().path
        XCTAssertEqual(models.map { $0.url.resolvingSymlinksInPath().path }, [canonicalBase],
                       "the assistant must not appear as a standalone model")
        XCTAssertEqual(ServerSettings.mtpDraftPath(forModel: base.path).map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }, canonicalDraft)
        XCTAssertTrue(ServerSettings.modelUsesMTP(at: base.path))

        var settings = makeSettings()
        settings.modelPath = base.path
        let args = settings.arguments
        XCTAssertEqual(URL(fileURLWithPath: args[args.firstIndex(of: "-md")! + 1])
            .resolvingSymlinksInPath().path, canonicalDraft)
        XCTAssertEqual(args[args.firstIndex(of: "--spec-type")! + 1], "draft-mtp")
    }

    func testSeparateMTPAssistantDoesNotPairWithAnotherModel() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mtp-mismatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = dir.appendingPathComponent("qwen3-8b-Q4_K_M.gguf")
        let draft = dir.appendingPathComponent("mtp-gemma-4-E2B-it.gguf")
        try Data("base".utf8).write(to: base)
        try Data("draft".utf8).write(to: draft)

        XCTAssertNil(ServerSettings.mtpDraftPath(forModel: base.path))
    }

    func testFlashAttentionPolicy() {
        // AMD kernel rides on auto: the engine keeps FA on GPU only where the
        // kernel covers the model, instead of a forced "1" falling back to CPU.
        var s = makeSettings()
        s.faAmd = true
        s.flashAttn = "auto"
        s.cacheTypeV = "f16"
        XCTAssertEqual(s.benchmarkArguments[s.benchmarkArguments.firstIndex(of: "-fa")! + 1], "auto")
        XCTAssertEqual(s.arguments[s.arguments.firstIndex(of: "-fa")! + 1], "auto")

        // Quantized KV still forces FA on (the engine requires it).
        s.cacheTypeV = "q8_0"
        XCTAssertEqual(s.benchmarkArguments[s.benchmarkArguments.firstIndex(of: "-fa")! + 1], "1")
        XCTAssertEqual(s.arguments[s.arguments.firstIndex(of: "-fa")! + 1], "1")

        // Manual fa=on keeps the explicit CPU-capable route for whoever asks.
        s.cacheTypeV = "f16"
        s.faAmd = false
        s.flashAttn = "on"
        XCTAssertEqual(s.benchmarkArguments[s.benchmarkArguments.firstIndex(of: "-fa")! + 1], "1")
        XCTAssertEqual(s.arguments[s.arguments.firstIndex(of: "-fa")! + 1], "on")
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
        s.serverBinary = "/tmp/custom/llama-server"
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
    func testInlineMathDetectionSupportsDollarAndParenthesizedForms() {
        XCTAssertTrue(RichText.containsInlineMath("Energy is $E = mc^2$."))
        XCTAssertTrue(RichText.containsInlineMath(#"Energy is \(E = mc^2\)."#))
        XCTAssertFalse(RichText.containsInlineMath(#"The price is \$5."#))
        XCTAssertFalse(RichText.containsInlineMath("A display block uses $$x$$"))
    }

    func testCachedInlineFormattingMatchesAFreshOneAndKeepsParagraphsApart() {
        let bold = "A **bold** word and a [link](https://example.test)."
        let other = "A *different* paragraph."
        let first = RichText.inline(bold)

        XCTAssertEqual(String(RichText.inline(bold).characters), "A bold word and a link.")
        XCTAssertEqual(first, RichText.inline(bold))
        XCTAssertEqual(String(RichText.inline(other).characters), "A different paragraph.")
        XCTAssertEqual(String(RichText.inline(bold).characters), "A bold word and a link.")
    }

    func testSVGIsEncodedAsAnIsolatedImageResource() {
        let input = #"<svg onload="bad()"><foreignObject><iframe src="https://evil.test"></iframe></foreignObject><path style="fill:url(https://evil.test/x)"/><script>bad()</script></svg>"#
        let output = RichContentIsolation.svgDataURL(input)
        let prefix = "data:image/svg+xml;base64,"
        XCTAssertTrue(output.hasPrefix(prefix))
        XCTAssertFalse(output.contains("<svg"), "untrusted markup must not be injected into the host document")
        let encoded = String(output.dropFirst(prefix.count))
        XCTAssertEqual(Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) }, input)
    }

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
        conv.messages.append(ChatMessage(
            role: "assistant", content: "¡Hola!", genSpeed: 25.7,
            timings: ChatTimings(cachedTokens: 100, promptTokens: 20,
                                 promptMilliseconds: 10, generatedTokens: 5,
                                 generationMilliseconds: 250)))
        conv.draft = ChatDraft(text: "pendiente")
        let data = try JSONEncoder().encode([conv])
        let back = try JSONDecoder().decode([Conversation].self, from: data)
        XCTAssertEqual(back.first?.messages.count, 2)
        XCTAssertEqual(back.first?.messages.last?.genSpeed, 25.7)
        XCTAssertEqual(back.first?.messages.last?.timings?.generatedTokens, 5)
        XCTAssertEqual(back.first?.draft?.text, "pendiente")
    }

    func testServerTimingsAreParsedAndRatesCalculated() throws {
        let timings = try XCTUnwrap(ChatTimings(json: [
            "cache_n": 300,
            "prompt_n": 200,
            "prompt_ms": 500.0,
            "predicted_n": 40,
            "predicted_ms": 2_000.0
        ]))
        XCTAssertEqual(timings.cachedTokens, 300)
        XCTAssertEqual(try XCTUnwrap(timings.promptTokensPerSecond), 400, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(timings.generationTokensPerSecond), 20, accuracy: 0.001)
    }

    func testStreamAccumulatorCombinesReasoningContentAndFinalMetadata() throws {
        var stream = ChatStreamAccumulator()
        let reasoning = #"data: {"choices":[{"delta":{"reasoning_content":"think "}}]}"#
        let answer = #"data: {"choices":[{"delta":{"content":"answer"},"finish_reason":"stop"}],"timings":{"prompt_n":20,"predicted_n":4,"predicted_ms":200},"usage":{"prompt_tokens":20,"completion_tokens":4}}"#
        XCTAssertTrue(try XCTUnwrap(stream.consume(reasoning)).receivedContent)
        XCTAssertTrue(try XCTUnwrap(stream.consume(answer)).receivedContent)
        XCTAssertTrue(try XCTUnwrap(stream.consume("data: [DONE]")).completed)
        XCTAssertEqual(stream.reasoning, "think ")
        XCTAssertEqual(stream.visible, "answer")
        XCTAssertEqual(stream.finishReason, "stop")
        XCTAssertEqual(stream.timings?.generatedTokens, 4)
        XCTAssertEqual(stream.usage?.completion, 4)
    }

    func testStreamAccumulatorMergesFragmentedToolCallsByIndex() throws {
        var stream = ChatStreamAccumulator()
        let first = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_7","function":{"name":"read_","arguments":"{\"path\":"}}]}}]}"#
        let second = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"file","arguments":"\"a.txt\"}"}}]},"finish_reason":"tool_calls"}]}"#
        XCTAssertTrue(try XCTUnwrap(stream.consume(first)).receivedToolCall)
        XCTAssertTrue(try XCTUnwrap(stream.consume(second)).receivedToolCall)
        let call = try XCTUnwrap(stream.toolCalls.first)
        XCTAssertEqual(call.serverID, "call_7")
        XCTAssertEqual(call.name, "read_file")
        XCTAssertEqual(call.arguments, #"{"path":"a.txt"}"#)
        XCTAssertEqual(stream.finishReason, "tool_calls")
    }

    func testToolArgumentsRequireAJSONObject() throws {
        let value = try ChatToolsService.parseArguments(#"{"path":"a.txt","line":4}"#)
        XCTAssertEqual(value["path"] as? String, "a.txt")
        XCTAssertEqual(value["line"] as? Int, 4)
        XCTAssertThrowsError(try ChatToolsService.parseArguments("[]"))
    }

    func testToolMessagesRoundTripThroughOpenAIHistory() throws {
        let call = ChatToolCall(serverID: "call_1", name: "get_datetime", arguments: "{}",
                                result: "2026-07-21", state: .completed)
        let messages = [
            ChatMessage(role: "assistant", content: "", toolCalls: [call]),
            ChatMessage(role: "tool", content: "2026-07-21", toolCallID: "call_1")
        ]
        let history = ChatStore.requestHistory(system: "", summary: nil, messages: messages, from: 0)
        XCTAssertEqual(history.count, 2)
        let toolCalls = try XCTUnwrap(history[0]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.first?["id"] as? String, "call_1")
        XCTAssertEqual((toolCalls.first?["function"] as? [String: Any])?["name"] as? String,
                       "get_datetime")
        XCTAssertEqual(history[1]["role"] as? String, "tool")
        XCTAssertEqual(history[1]["tool_call_id"] as? String, "call_1")
    }

    func testBuiltinToolMetadataPreservesDefinition() throws {
        let json: [String: Any] = [
            "display_name": "Read file", "tool": "read_file", "type": "builtin",
            "permissions": ["write": false],
            "definition": ["type": "function", "function": ["name": "read_file"]]
        ]
        let tool = try XCTUnwrap(BuiltinToolInfo(json: json))
        XCTAssertEqual(tool.displayName, "Read file")
        XCTAssertFalse(tool.writesData)
        XCTAssertEqual((tool.openAIDefinition?["function"] as? [String: Any])?["name"] as? String,
                       "read_file")
    }

    func testJavaScriptSandboxToolMatchesLlamaContract() throws {
        let tool = JavaScriptSandboxService.tool
        XCTAssertEqual(tool.name, "run_javascript")
        XCTAssertFalse(tool.writesData)
        let function = try XCTUnwrap(tool.openAIDefinition?["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "run_javascript")
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["required"] as? [String], ["code"])
    }

    func testJavaScriptSandboxReplyFormattingAndTruncation() {
        XCTAssertEqual(
            JavaScriptSandboxService.formatReply(logs: ["one", "warn: two"],
                                                  result: "3", error: nil),
            ToolExecutionResult(content: "one\nwarn: two\n=> 3", isError: false))
        XCTAssertEqual(
            JavaScriptSandboxService.formatReply(logs: [], result: nil, error: nil).content,
            "(no output)")
        let error = JavaScriptSandboxService.formatReply(logs: [], result: nil, error: "bad")
        XCTAssertTrue(error.isError)
        XCTAssertEqual(error.content, "Error: bad")
        let long = JavaScriptSandboxService.formatReply(
            logs: [String(repeating: "x", count: 9_000)], result: nil, error: nil)
        XCTAssertTrue(long.content.hasSuffix("\n[output truncated]"))
        XCTAssertEqual(long.content.count,
                       JavaScriptSandboxService.maximumOutputCharacters + "\n[output truncated]".count)
    }

    @MainActor
    func testJavaScriptSandboxExecutesAwaitAndCapturesConsole() async {
        let result = await JavaScriptSandboxService.execute(arguments: [
            "code": "console.log('sum'); return await Promise.resolve(2 + 2);",
            "timeout_ms": 3_000
        ])
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.content, "sum\n=> 4")
    }

    func testSpecializedToolPresentationAcceptsArgumentAliases() {
        let shell = ToolCallPresentation.make(ChatToolCall(
            name: "exec_shell_command", arguments: #"{"cmd":"pwd"}"#))
        XCTAssertEqual(shell.kind, .shell)
        XCTAssertEqual(shell.code, "pwd")

        let read = ToolCallPresentation.make(ChatToolCall(
            name: "read_file",
            arguments: #"{"filePath":"/tmp/a.swift","startLine":3,"count":4}"#))
        XCTAssertEqual(read.kind, .read)
        XCTAssertEqual(read.path, "/tmp/a.swift")
        XCTAssertEqual(read.language, "swift")
        XCTAssertEqual(read.detail, "lines 3–6")
    }

    func testSettingsArchiveRoundTripFiltersRuntimeAndUnknownKeys() throws {
        let sourceName = "ToshLLMTests.Settings.Source.\(UUID().uuidString)"
        let targetName = "ToshLLMTests.Settings.Target.\(UUID().uuidString)"
        let source = try XCTUnwrap(UserDefaults(suiteName: sourceName))
        let target = try XCTUnwrap(UserDefaults(suiteName: targetName))
        defer {
            source.removePersistentDomain(forName: sourceName)
            target.removePersistentDomain(forName: targetName)
        }
        source.set(0.42, forKey: SettingsKeys.chatTopP)
        let mcpData = Data(#"[{"name":"local"}]"#.utf8)
        source.set(mcpData, forKey: SettingsKeys.mcpServers)
        source.set("must-not-export", forKey: SettingsKeys.modelPath)
        let data = try SettingsArchive.exportData(defaults: source)
        let count = try SettingsArchive.importData(data, defaults: target)
        XCTAssertGreaterThanOrEqual(count, 1)
        XCTAssertEqual(target.double(forKey: SettingsKeys.chatTopP), 0.42, accuracy: 0.001)
        XCTAssertEqual(target.data(forKey: SettingsKeys.mcpServers), mcpData)
        XCTAssertNil(target.object(forKey: SettingsKeys.modelPath))
    }

    func testMCPResourceTemplateExpandsPathAndQueryExpressions() {
        let template = "repo://{owner}/{name}/file{?ref,path}"
        XCTAssertEqual(MCPURITemplate.variables(in: template), ["owner", "name", "ref", "path"])
        XCTAssertEqual(
            MCPURITemplate.expand(template, values: [
                "owner": "open ai", "name": "llama", "ref": "main", "path": "a/b.swift"
            ]),
            "repo://open%20ai/llama/file?ref=main&path=a%2Fb.swift")
    }

    func testConversationBranchesPreserveAndSwitchCompletePaths() throws {
        let user = ChatMessage(role: "user", content: "Pregunta")
        let first = ChatMessage(role: "assistant", content: "Respuesta A")
        var conversation = Conversation(title: "Ramas", messages: [user, first])
        conversation.beginAlternativeBranch(messages: [user])
        conversation.messages.append(ChatMessage(role: "assistant", content: "Respuesta B"))
        let firstBranch = try XCTUnwrap(conversation.branches?.first)
        XCTAssertEqual(conversation.branches?.count, 2)
        XCTAssertTrue(conversation.activateBranch(firstBranch.id))
        XCTAssertEqual(conversation.messages.last?.content, "Respuesta A")
        let secondBranch = try XCTUnwrap(conversation.branches?.last)
        XCTAssertTrue(conversation.activateBranch(secondBranch.id))
        XCTAssertEqual(conversation.messages.last?.content, "Respuesta B")

        let decoded = try JSONDecoder().decode(
            Conversation.self, from: JSONEncoder().encode(conversation))
        XCTAssertEqual(decoded.branches?.count, 2)
        XCTAssertEqual(decoded.activeBranchID, secondBranch.id)
    }

    func testLlamaJSONLRoundTripPreservesBranchesReasoningAndAttachments() throws {
        let user = ChatMessage(role: "user", content: "Pregunta",
                               attachments: [ChatAttachment(name: "notes.txt", content: "context")],
                               imageURIs: ["data:image/jpeg;base64,aW1hZ2U="])
        let first = ChatMessage(role: "assistant", content: "<think>plan</think>Respuesta A")
        var conversation = Conversation(title: "JSONL", messages: [user, first], pinned: true,
                                        systemPrompt: "Be useful", enabledToolNames: ["read_file"])
        conversation.beginAlternativeBranch(messages: [user])
        conversation.messages.append(ChatMessage(role: "assistant", content: "Respuesta B"))

        let data = try ChatJSONL.encode([conversation])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains(#""harness":"llama.app""#))
        let decoded = try XCTUnwrap(ChatJSONL.decode(data).first)
        XCTAssertEqual(decoded.title, "JSONL")
        XCTAssertEqual(decoded.branches?.count, 2)
        XCTAssertEqual(decoded.systemPrompt, "Be useful")
        XCTAssertEqual(decoded.enabledToolNames, ["read_file"])
        XCTAssertEqual(decoded.branches?.flatMap(\.messages).first(where: { $0.parts.thinking == "plan" })?.parts.body,
                       "Respuesta A")
        XCTAssertEqual(decoded.messages.first?.attachments?.first?.content, "context")
        XCTAssertEqual(decoded.messages.first?.imageURIs?.count, 1)
    }

    func testAudioAndVideoAttachmentsUseOpenAIMultimodalParts() throws {
        let audio = ChatAttachment(name: "voice.wav", content: "", mimeType: "audio/wav",
                                   dataURI: "data:audio/wav;base64,YXVkaW8=")
        let video = ChatAttachment(name: "clip.mp4", content: "", mimeType: "video/mp4",
                                   dataURI: "data:video/mp4;base64,dmlkZW8=")
        let message = ChatMessage(role: "user", content: "Describe", attachments: [audio, video])
        let history = ChatStore.requestHistory(system: "", summary: nil,
                                               messages: [message], from: 0)
        let parts = try XCTUnwrap(history.first?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.map { $0["type"] as? String }, ["text", "input_audio", "input_video"])
        let inputAudio = try XCTUnwrap(parts[1]["input_audio"] as? [String: Any])
        XCTAssertEqual(inputAudio["data"] as? String, "YXVkaW8=")
        XCTAssertEqual(inputAudio["format"] as? String, "wav")
        let inputVideo = try XCTUnwrap(parts[2]["input_video"] as? [String: Any])
        XCTAssertEqual(inputVideo["format"] as? String, "mp4")
    }

    func testMultimediaFormatsMatchLlamaWebUICompatibilityRules() {
        XCTAssertEqual(ChatAttachment(name: "voice.wav", content: "", mimeType: "audio/x-wav").audioInputFormat, "wav")
        XCTAssertEqual(ChatAttachment(name: "voice.flac", content: "", mimeType: "audio/flac").audioInputFormat, "mp3")
        XCTAssertEqual(ChatAttachment(name: "clip.ogg", content: "", mimeType: "video/ogg").videoInputFormat, "ogg")
        XCTAssertEqual(ChatAttachment(name: "clip.mov", content: "", mimeType: "video/quicktime").videoInputFormat, "auto")
    }

    func testUnsupportedHistoricalMediaIsFilteredForSelectedModel() throws {
        let audio = ChatAttachment(name: "voice.wav", content: "", mimeType: "audio/wav",
                                   dataURI: "data:audio/wav;base64,YXVkaW8=")
        let video = ChatAttachment(name: "clip.mp4", content: "", mimeType: "video/mp4",
                                   dataURI: "data:video/mp4;base64,dmlkZW8=")
        let message = ChatMessage(role: "user", content: "Describe",
                                  attachments: [audio, video], imageURIs: ["data:image/jpeg;base64,aW1hZ2U="])
        let history = ChatStore.requestHistory(
            system: "", summary: nil, messages: [message], from: 0,
            modalities: ModelModalities(vision: false, audio: true, video: false))
        let parts = try XCTUnwrap(history.first?["content"] as? [[String: Any]])
        XCTAssertEqual(parts.compactMap { $0["type"] as? String }, ["text", "input_audio"])
    }

    func testResumableStreamIdentityIncludesRouterModelAndEscapesURL() throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let identity = ChatStreamIdentity.value(conversationID: id, model: "model/name")
        XCTAssertEqual(identity, "11111111-1111-1111-1111-111111111111::model/name")
        let url = try XCTUnwrap(ChatStreamIdentity.resumeURL(port: 8080, identity: identity, from: 42))
        XCTAssertTrue(url.absoluteString.contains("model%2Fname"))
        XCTAssertTrue(url.absoluteString.hasSuffix("?from=42"))
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

    func testSnapshotKeepsTheAnswerAsItStoodWhileGenerationContinues() {
        let live = LiveStream()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        live.setReasoningExpanded(true, now: start)
        live.update(reasoning: "thinking", visible: "first half", speed: 30,
                    now: start.addingTimeInterval(1))

        let frozen = live.snapshot
        live.update(reasoning: "thinking more", visible: "first half and the rest", speed: 30,
                    now: start.addingTimeInterval(10))

        XCTAssertEqual(frozen.visible, "first half")
        XCTAssertEqual(frozen.reasoning, "thinking")
        XCTAssertEqual(live.visibleText, "first half and the rest")
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
    func testBenchmarkVRAMFractionUsesBufferSizeInsteadOfDeviceIndex() throws {
        let log = """
        ggml_metal_device_init: 12271 MiB free
        MTL0_Private model buffer size = 9000.00 MiB
        MTL0_Private compute buffer size = 200.00 MiB
        MTL0_Private KV buffer size = 100.00 MiB
        MTL0_Private RS buffer size = 50.00 MiB
        """
        let value = try XCTUnwrap(BenchmarkController.vramFraction(fromLog: log))
        XCTAssertEqual(value, (9000 + 200 + 100 + 50 + 650) / 12271, accuracy: 0.0001)
    }

    func testSweepChoosesBestMeasuredSafeCandidateWithoutCliff() {
        let pp = [24: 351.0, 22: 366.0, 20: 370.0]
        let vram = [24: 0.80, 22: 0.90, 20: 0.97]
        XCTAssertEqual(BenchmarkController.bestSweepCandidate(pp: pp, vram: vram, ceiling: 0.95), 22)
    }

    func testSweepAddsThreeStepsOfVRAMHeadroom() {
        XCTAssertEqual(BenchmarkController.sweepHeadroomCandidate(lowestSafe: 20, cliff: nil), 23)
        XCTAssertEqual(BenchmarkController.sweepHeadroomCandidate(lowestSafe: 20, cliff: 24), 23)
        XCTAssertEqual(BenchmarkController.sweepHeadroomCandidate(lowestSafe: 20, cliff: 22), 21)
    }

    func testBenchConfigLabel() {
        let r = BenchResult(date: .now, model: "Qwen3.6-35B-A3B-UD-Q4_K_S.gguf",
                            ncmoe: 24, pp: 68.3, tg: 15.7,
                            ctk: "turbo4", ctv: "turbo3", engine: "turbo",
                            fa: "amd-gpu")
        XCTAssertEqual(r.configLabel, "ncmoe 24 · K:turbo4 · V:turbo3 · FA AMD GPU · turbo")
        XCTAssertFalse(r.shortModel.contains(".gguf"))
        XCTAssertEqual(r.quantization, "UD-Q4_K_S")
    }

    func testBenchmarkFlashAttentionRouteLabelsCPUAndGPU() {
        var s = ServerSettings(serverBinary: "/usr/bin/true", modelPath: "/tmp/m.gguf", port: 8080,
                               ngl: 99, ncmoe: 0, ctx: 16384, threads: 6, flashAttn: "off",
                               noMmap: true, jinja: true,
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
                        jinja: true, vramReserve: 1024,
                        gpuIndex: -1, extraArgs: "--spec-type draft-mtp",
                        cacheTypeK: "f16", cacheTypeV: "f16", mlock: false,
                        port: 8080, engine: "bundled")
        let back = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.engine, "bundled")
        XCTAssertEqual(back.extraArgs, "--spec-type draft-mtp")
    }

    func testLegacyProfileDecodesWithNilPinned() throws {
        // servers saved before the pinned field existed keep full-snapshot behavior
        let legacy = #"{"id":"00000000-0000-0000-0000-000000000000","name":"S2","modelPath":"/m.gguf","ngl":99,"ncmoe":0,"ctx":16384,"threads":6,"flashAttn":"auto","noMmap":true,"jinja":true,"concurrencyDisable":true,"vramReserve":1024,"gpuIndex":-1,"extraArgs":"","cacheTypeK":"f16","cacheTypeV":"f16","mlock":false,"port":8081}"#
        let p = try JSONDecoder().decode(Profile.self, from: Data(legacy.utf8))
        XCTAssertNil(p.pinned)
    }

    func testBenchmarkBase64URLIsUnpadded() {
        // "+/" bytes must map to "-_" with no "=" padding (RFC 4648 base64url).
        let data = Data([0xfb, 0xff, 0xbf])   // base64 "+/+/" territory
        let encoded = BenchmarkSharing.base64URL(data)
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
    }

    func testBenchmarkSignatureMessageFormat() {
        // Exact framing: five lines, lowercase hex of the payload, no trailing newline.
        let payload = Data("hello".utf8)
        let msg = BenchmarkSharing.signatureMessage(
            purpose: "benchmark", challengeId: "CID", nonce: "NONCE", payload: payload)
        let text = String(data: msg, encoding: .utf8)!
        let expectedHash = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        XCTAssertEqual(text, "toshllm-benchmark-v2\nbenchmark\nCID\nNONCE\n\(expectedHash)")
        XCTAssertFalse(text.hasSuffix("\n"))
    }

    func testApplyPinnedOnlyOverlaysPinnedFields() {
        var s = ServerSettings.fromDefaults()
        s.ctx = 32768
        s.modelPath = "/global.gguf"
        var p = s.makeProfile(name: "S2")
        p.ctx = 4096
        p.modelPath = "/pinned.gguf"
        p.port = 9090

        s.applyPinned(p, [Profile.Pin.ctx])
        XCTAssertEqual(s.ctx, 4096)
        XCTAssertEqual(s.modelPath, "/global.gguf", "unpinned fields keep the global value")
        XCTAssertEqual(s.port, 9090, "the port always comes from the server's profile")

        s.applyPinned(p, [])
        XCTAssertEqual(s.modelPath, "/global.gguf")
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

    func testDynamicMoeOptimizationStatesUseActiveLanguage() {
        let loc = Localizer()
        loc.language = "es"
        XCTAssertEqual(DynamicMoeOptimizationState.testingDirect(slots: 8).localized(using: loc),
                       "Probando dMoE directo K8…")
        XCTAssertEqual(DynamicMoeOptimizationState.optimizedSplit(slots: 64, ringSlots: 8)
            .localized(using: loc), "Optimizado: ruta dividida K64 + ring8")

        loc.language = "en"
        XCTAssertEqual(DynamicMoeOptimizationState.testingDirect(slots: 8).localized(using: loc),
                       "Testing direct dMoE K8…")
        XCTAssertEqual(DynamicMoeOptimizationState.optimizedSplit(slots: 64, ringSlots: 8)
            .localized(using: loc), "Optimized: split route K64 + ring8")
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

// MARK: - Router mode

final class RouterModeTests: XCTestCase {
    private func makeSettings(routerMode: Bool = true) -> ServerSettings {
        var s = ServerSettings(serverBinary: "/usr/bin/true", modelPath: "/tmp/unused.gguf", port: 8099,
                                ngl: 99, ncmoe: 0, ctx: 8192, threads: 6, flashAttn: "auto",
                                noMmap: true, jinja: false,
                                vramReserveMB: 1024, gpuIndex: -1, extraArgs: "",
                                cacheTypeK: "f16", cacheTypeV: "f16", mlock: false)
        s.routerMode = routerMode
        s.routerModelsMax = 2
        return s
    }

    func testRouterArgumentsHaveNoFixedModel() {
        let args = makeSettings().arguments
        XCTAssertFalse(args.contains("-m"), "el router no fija un solo modelo")
        XCTAssertTrue(args.contains("--models-preset"))
        XCTAssertTrue(args.contains("--models-autoload"))
        XCTAssertEqual(args[args.firstIndex(of: "--models-max")! + 1], "2")
    }

    func testNonRouterArgumentsUnaffected() {
        let args = makeSettings(routerMode: false).arguments
        XCTAssertTrue(args.contains("-m"))
        XCTAssertFalse(args.contains("--models-preset"))
    }

    func testRouterAliasIsSlugAndStable() {
        XCTAssertEqual(ServerSettings.routerAlias(for: "/models/Qwen3.6-14B-A3B.gguf"), "qwen3-6-14b-a3b")
        XCTAssertEqual(ServerSettings.routerAlias(for: "/other/Qwen3.6-14B-A3B.gguf"),
                       ServerSettings.routerAlias(for: "/models/Qwen3.6-14B-A3B.gguf"),
                       "el alias depende solo del nombre de archivo, no de la carpeta")
    }

    func testRouterPresetINIHasOneSectionPerModelWithNcmoe() {
        let ini = makeSettings().routerPresetINI(
            modelPaths: ["/models/dense-4b.gguf", "/models/moe-a3b.gguf"],
            ncmoeByPath: ["/models/moe-a3b.gguf": 12])
        XCTAssertTrue(ini.contains("[dense-4b]"))
        XCTAssertTrue(ini.contains("[moe-a3b]"))
        XCTAssertTrue(ini.contains("model = /models/dense-4b.gguf"))
        XCTAssertTrue(ini.contains("n-cpu-moe = 12"))
        // Dense entry has no ncmoe line: no false n-cpu-moe on a model with no experts.
        let denseSection = ini.components(separatedBy: "\n\n").first { $0.contains("dense-4b") } ?? ""
        XCTAssertFalse(denseSection.contains("n-cpu-moe"))
        XCTAssertTrue(ini.contains("--host") == false, "el router no repite --host/--port por modelo")
    }

    func testRouterPresetAliasCollisionIsDisambiguated() {
        let ini = makeSettings().routerPresetINI(
            modelPaths: ["/a/model.gguf", "/b/model.gguf"], ncmoeByPath: [:])
        let sections = ini.components(separatedBy: "\n\n").filter { $0.contains("model = ") }
        XCTAssertEqual(sections.count, 2, "dos archivos con el mismo nombre deben quedar en secciones separadas")
    }
}

final class ConversationDecodingTests: XCTestCase {
    // New Conversation fields must be `Type?`, not just `= default`: the
    // synthesized decoder still requires the key otherwise.
    func testDecodesConversationSavedBeforePinnedExisted() throws {
        let json = """
        [{"id":"11111111-1111-1111-1111-111111111111","title":"Old chat",
          "messages":[],"created":700000000,"updated":700000000}]
        """.data(using: .utf8)!
        let list = try JSONDecoder().decode([Conversation].self, from: json)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].pinned, nil)
        XCTAssertNil(list[0].projectID)
        XCTAssertNil(list[0].systemPrompt)
    }
}

final class SystemPromptResolutionTests: XCTestCase {
    func testChatPromptWinsOverProjectAndGlobal() {
        XCTAssertEqual(ChatStore.resolvePrompt(chat: "chat", project: "proj", global: "glob"), "chat")
    }

    func testProjectPromptWinsWhenChatIsEmptyOrNil() {
        XCTAssertEqual(ChatStore.resolvePrompt(chat: "  \n", project: "proj", global: "glob"), "proj")
        XCTAssertEqual(ChatStore.resolvePrompt(chat: nil, project: "proj", global: "glob"), "proj")
    }

    func testGlobalIsTheFallback() {
        XCTAssertEqual(ChatStore.resolvePrompt(chat: nil, project: "", global: "glob"), "glob")
        XCTAssertEqual(ChatStore.resolvePrompt(chat: nil, project: nil, global: ""), "")
    }
}

final class ReleaseNotesRangeTests: XCTestCase {
    let all = [("0.81.66", "c"), ("0.81.65", "b"), ("0.81.64", "a"), ("0.81.63", "z")]

    func testShowsEverythingNewerThanCurrentNewestFirst() {
        let out = UpdateChecker.notesToShow(all: all, current: "0.81.64")
        XCTAssertEqual(out.map(\.0), ["0.81.66", "0.81.65"])
    }

    func testUpToDateShowsOnlyTheCurrentVersion() {
        let out = UpdateChecker.notesToShow(all: all, current: "0.81.66")
        XCTAssertEqual(out.map(\.0), ["0.81.66"])
    }
}

final class SmartTitleTests: XCTestCase {
    func testStripsMarkdownAndCutsAtWordBoundary() {
        XCTAssertEqual(ChatStore.smartTitle(from: "## Hola mundo"), "Hola mundo")
        let long = "Explícame paso a paso cómo funciona el prefill descompuesto en tarjetas AMD"
        let t = ChatStore.smartTitle(from: long)
        XCTAssertTrue(t.hasSuffix("…"))
        XCTAssertLessThanOrEqual(t.count, 50)
    }

    func testUsesFirstMeaningfulLine() {
        XCTAssertEqual(ChatStore.smartTitle(from: "\n\n- item uno\nresto"), "item uno")
        XCTAssertEqual(ChatStore.smartTitle(from: "hola"), "hola")
    }
}

final class SpeedEstimateTests: XCTestCase {
    // 12 GB VRAM / 32 GB RAM, like the dev machine.
    private let hw = HardwareInfo(
        cpuBrand: "Test CPU", physicalCores: 6, logicalCores: 12,
        ramGB: 32, arch: "x86_64", model: "", osVersion: "",
        gpus: [GPUDevice(index: 0, name: "RX 6700 XT", vramMB: 12868)])

    private func tgHi(_ s: String) -> Int {
        Int(s.replacingOccurrences(of: "~", with: "").replacingOccurrences(of: " t/s", with: "")
            .split(separator: "-").last.map(String.init) ?? "0") ?? 0
    }

    func testSmallerQuantEstimatesFaster() {
        let big = ModelSpec(fileGB: 19.5, paramsB: 35, layers: 48, isMoE: true, activeParamsB: 3)
        let small = ModelSpec(fileGB: 10.0, paramsB: 35, layers: 48, isMoE: true, activeParamsB: 3)
        let sBig = Estimator.estimate(spec: big, hw: hw).expectedSpeed
        let sSmall = Estimator.estimate(spec: small, hw: hw).expectedSpeed
        XCTAssertGreaterThan(tgHi(sSmall), tgHi(sBig))
    }

    func testMoreActiveParamsEstimatesSlower() {
        let a3 = ModelSpec(fileGB: 17.0, paramsB: 30, layers: 48, isMoE: true, activeParamsB: 3)
        let a4 = ModelSpec(fileGB: 17.0, paramsB: 30, layers: 48, isMoE: true, activeParamsB: 4)
        XCTAssertGreaterThan(tgHi(Estimator.estimate(spec: a3, hw: hw).expectedSpeed),
                             tgHi(Estimator.estimate(spec: a4, hw: hw).expectedSpeed))
    }
}

final class ModelNameTests: XCTestCase {
    func testDenseWithFinetune() {
        let m = ModelName("Qwen3-8B-Q4_K_M.gguf")
        XCTAssertEqual(m.title, "Qwen3 8B")
        XCTAssertEqual(m.quant, "Q4_K_M")
        XCTAssertTrue(m.badges.isEmpty)
    }

    func testMoEActiveParams() {
        let m = ModelName("Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf")
        XCTAssertEqual(m.title, "Qwen3 Coder 30B-A3B")
        XCTAssertEqual(m.quant, "Q4_K_M")
        XCTAssertTrue(m.badges.contains("MoE"))
        XCTAssertTrue(m.badges.contains("Instruct"))
        XCTAssertFalse(m.badges.contains("Coder"))   // stays in the title
    }

    func testAttributeBeforeSize() {
        let m = ModelName("GLM-4.7-Flash-REAP-23B-A3B-Q4_K_M.gguf")
        XCTAssertEqual(m.title, "GLM 4.7 Flash 23B-A3B")
        XCTAssertTrue(m.badges.contains("REAP"))
        XCTAssertTrue(m.badges.contains("MoE"))
    }

    func testUncensoredWithNickname() {
        let m = ModelName("Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf")
        XCTAssertEqual(m.title, "Qwen3.5 9B")
        XCTAssertEqual(m.quant, "Q4_K_M")
        XCTAssertEqual(m.badges, ["Uncensored"])
    }

    func testVisionAndVersionAndDotQuant() {
        XCTAssertEqual(ModelName("Qwen3-VL-2B-Instruct-Q8_0.gguf").badges.contains("Vision") ||
                       ModelName("Qwen3-VL-2B-Instruct-Q8_0.gguf").title.contains("VL"), true)
        let m = ModelName("Llama-3.2-1B-Instruct-RLHF-v0.1.Q4_K_M.gguf")
        XCTAssertEqual(m.title, "Llama 3.2 1B")
        XCTAssertEqual(m.quant, "Q4_K_M")
        XCTAssertTrue(m.badges.contains("Instruct"))
    }

    func testGemmaEffectiveSizeAndIt() {
        let m = ModelName("gemma-4-E2B-it-Q4_K_M.gguf")
        XCTAssertEqual(m.title, "Gemma 4 E2B")
        XCTAssertEqual(m.quant, "Q4_K_M")
        XCTAssertTrue(m.badges.contains("Instruct"))
    }

    func testAcronymCapitalization() {
        XCTAssertEqual(ModelName("gpt-oss-20B-Q4_K_M.gguf").title, "GPT OSS 20B")
        XCTAssertEqual(ModelName("gemma-4-27b-it.gguf").title, "Gemma 4 27B")
    }

    func testMetadataNameWithSpaces() {
        let m = ModelName("Gemma 4 E2B it")
        XCTAssertEqual(m.title, "Gemma 4 E2B")
        XCTAssertTrue(m.badges.contains("Instruct"))
    }

    func testLooksMoEAcrossActiveParamCounts() {
        XCTAssertTrue(ModelName.looksMoE("Gemma-4-26B-A4B-it-UD-Q4_K_M.gguf"))
        XCTAssertTrue(ModelName.looksMoE("Qwen3.5-122B-A10B-UD-Q8_K_XL.gguf"))
        XCTAssertTrue(ModelName.looksMoE("Qwen3-Coder-30B-A3B-Q4_K_M.gguf"))
        XCTAssertTrue(ModelName.looksMoE("Mixtral-8x7B-Q4_K_M.gguf"))
        XCTAssertTrue(ModelName.looksMoE("gpt-oss-20B-Q4_K_M.gguf"))
        XCTAssertFalse(ModelName.looksMoE("Qwen3-8B-Q4_K_M.gguf"))
        XCTAssertFalse(ModelName.looksMoE("Llama-3.1-8B-Q4_K_M.gguf"))
    }

    func testBF16AndUnslothDynamic() {
        XCTAssertEqual(ModelName("Qwen3-0.6B-BF16.gguf").quant, "BF16")
        XCTAssertEqual(ModelName("Qwen3.5-122B-A10B-UD-Q8_K_XL-00001-of-00005.gguf").quant, "UD-Q8_K_XL")
        XCTAssertEqual(ModelName("Qwen3.5-122B-A10B-UD-Q8_K_XL-00001-of-00005.gguf").title, "Qwen3.5 122B-A10B")
    }

    // MARK: engine check

    private var engineCheckSample: String {
        """
        ggml_metal_device_init: probed SIMD-group width = 64
        ggml_metal: device 0: AMD Radeon RX Vega 64 (peer group 0, not bridged) probed SIMD-group width = 64
        Backend 1/3: MTL0
        [TIMESTEP_EMBEDDING] ERR = 0.0013 > 0.0000 sentinel mismatch: sent_2   TIMESTEP_EMBEDDING(type=f32,dim=320): \u{1B}[1;31mFAIL\u{1B}[0m
        [MUL_MAT] ERR = 0.9 > 0.0001   MUL_MAT(type_a=q4_K,m=16): \u{1B}[1;31mFAIL\u{1B}[0m
          10726/10727 tests passed
          Backend MTL0: \u{1B}[1;31mFAIL\u{1B}[0m
        Backend 2/3: BLAS
          12/12 tests passed
          Backend BLAS: \u{1B}[1;32mOK\u{1B}[0m
        """
    }

    func testEngineCheckParsesDeviceAndCounts() {
        let r = EngineCheck.parse(engineCheckSample)
        XCTAssertEqual(r.simdWidth, 64)
        XCTAssertEqual(r.device, "AMD Radeon RX Vega 64")
        XCTAssertEqual(r.backends, [EngineCheckBackend(name: "MTL0", passed: 10726, total: 10727),
                                    EngineCheckBackend(name: "BLAS", passed: 12, total: 12)])
    }

    func testEngineCheckSeparatesKnownUpstreamFailure() {
        let r = EngineCheck.parse(engineCheckSample)
        XCTAssertEqual(r.knownFailures.count, 1)
        XCTAssertTrue(r.knownFailures[0].contains("TIMESTEP_EMBEDDING"))
        XCTAssertEqual(r.failures.count, 1)
        XCTAssertTrue(r.failures[0].contains("MUL_MAT"))
        XCTAssertFalse(r.ok)
    }

    func testEngineCheckCleanRunHasNoFailures() {
        let clean = """
        ggml_metal_device_init: probed SIMD-group width = 32
        Backend 1/2: MTL0
        [TIMESTEP_EMBEDDING] ERR   TIMESTEP_EMBEDDING(type=f32): FAIL
          10726/10727 tests passed
        """
        let r = EngineCheck.parse(clean)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.simdWidth, 32)
        XCTAssertTrue(EngineCheck.report(r, localized: { _, en in en }).contains("no need to report"))
    }

    func testEngineCheckBinarySitsNextToTheEngine() {
        XCTAssertEqual(EngineCheck.binaryPath(serverBinary: "/a/bin/llama-server"), "/a/bin/test-backend-ops")
    }
}
