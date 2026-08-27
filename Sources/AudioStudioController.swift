// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Combine
import Foundation

@MainActor
final class AudioStudioController: ObservableObject {
    static let shared = AudioStudioController()

    @Published private(set) var sourceURL: URL?
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var fileSize = 0
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isPlaying = false
    @Published private(set) var stage: AudioStudioStage = .idle
    @Published private(set) var progress = 0.0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var cues: [SubtitleCue] = []
    @Published private(set) var originalCues: [SubtitleCue] = []
    @Published private(set) var translatedCues: [SubtitleCue] = []
    @Published private(set) var transcriptMode = AudioTranscriptMode.original
    @Published private(set) var translatedBatchCount = 0
    @Published private(set) var translationBatchCount = 0
    @Published private(set) var translationTargetLanguage = ""
    @Published private(set) var translationModel = ""
    @Published private(set) var translationGlossary = ""
    @Published private(set) var vadPreviewState = AudioVADPreviewState.idle
    @Published private(set) var vadPreviewCues: [SubtitleCue] = []
    @Published private(set) var detectedLanguage = ""
    @Published private(set) var error: String?

    private var process: Process?
    private var stderrPipe: Pipe?
    private var stderrBuffer = ""
    private var workDirectory: URL?
    private var outputBase: URL?
    private var runID: UUID?
    private var ticker: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var restoreModelURL: URL?
    private var restoreGPUIndex = 0
    private var shouldRestorePersistentModel = false
    private var undoHistory: [([SubtitleCue], [SubtitleCue])] = []
    private var redoHistory: [([SubtitleCue], [SubtitleCue])] = []

    private static var recoveryURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "ToshLLM", directoryHint: .isDirectory)
            .appending(path: "AudioRecovery.json")
    }

    var isBusy: Bool {
        switch stage {
        case .preparing, .analyzingVAD, .transcribing, .translating: true
        default: false
        }
    }

    var isVideo: Bool {
        guard let ext = sourceURL?.pathExtension.lowercased() else { return false }
        return ["mp4", "mov", "m4v", "webm", "mkv"].contains(ext)
    }

    var remaining: TimeInterval? {
        guard progress > 0.08, progress < 1 else { return nil }
        return max(0, elapsed / progress - elapsed)
    }

    var currentCueID: Int? {
        Self.cueID(at: currentTime, in: originalCues.isEmpty ? cues : originalCues)
    }

    var hasTranslation: Bool { !translatedCues.isEmpty }

    var canRetryTranslation: Bool { !originalCues.isEmpty && !isBusy }

    var hasRecoveryProject: Bool {
        FileManager.default.fileExists(atPath: Self.recoveryURL.path)
    }

    func select(_ url: URL) {
        cancel(clearResult: true)
        player?.pause()
        isPlaying = false
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        sourceURL = url
        duration = 0
        currentTime = 0
        vadPreviewState = .idle
        vadPreviewCues = []
        fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let player = AVPlayer(url: url)
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.currentTime = max(0, time.seconds) }
        }
        Task { await loadDuration(url) }
    }

    func togglePlayback() {
        guard let player else { return }
        if player.rate == 0 {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    func seek(to seconds: TimeInterval) {
        let target = max(0, seconds)
        currentTime = target
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func start(modelURL: URL, vadModelURL: URL, vadConfiguration: AudioVADConfiguration,
               gpuIndex: Int, language: String,
               operation: AudioStudioOperation, targetLanguage: String,
               chatPort: Int, routerModel: String?, glossary: String,
               restorePersistentModel: Bool) {
        guard let sourceURL, !isBusy else { return }
        guard !SpeechDictationController.shared.isDictating,
              !SpeechDictationController.shared.isTranscribing,
              !AppleSpeechDictationController.shared.isDictating else {
            fail("Termina primero el dictado del micrófono o la transcripción adjunta / finish microphone dictation or the attached transcription first.")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: SpeechDictationController.binary) else {
            fail("No se encontró Whisper.cpp / Whisper.cpp is missing.")
            return
        }
        guard !vadConfiguration.isEnabled || FileManager.default.fileExists(atPath: vadModelURL.path) else {
            fail("No se encontró el detector de voz Silero / the Silero voice detector is missing.")
            return
        }
        if operation == .translateLocal && targetLanguage.trimmingCharacters(in: .whitespaces).isEmpty {
            fail("Elige un idioma de destino / choose a target language.")
            return
        }

        cancel(clearResult: true)
        self.sourceURL = sourceURL
        restoreModelURL = modelURL
        restoreGPUIndex = max(0, gpuIndex)
        shouldRestorePersistentModel = restorePersistentModel
        SpeechDictationController.shared.shutdown()

        let id = UUID()
        runID = id
        stage = .preparing
        progress = 0.02
        error = nil
        startTicker()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToshLLM-audio-\(id.uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fail(error.localizedDescription)
            return
        }
        workDirectory = directory
        let converted = directory.appendingPathComponent("source.wav")
        let converter = Process()
        converter.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        converter.arguments = [sourceURL.path, converted.path, "-f", "WAVE", "-d", "LEI16@16000", "-c", "1"]
        converter.standardOutput = FileHandle.nullDevice
        let diagnostics = Pipe()
        converter.standardError = diagnostics
        converter.terminationHandler = { [weak self] completed in
            let data = diagnostics.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                guard let self, self.runID == id else { return }
                self.process = nil
                guard completed.terminationStatus == 0 else {
                    self.fail(message.trimmingCharacters(in: .whitespacesAndNewlines))
                    return
                }
                self.runWhisper(audioURL: converted, modelURL: modelURL, vadModelURL: vadModelURL,
                                vadConfiguration: vadConfiguration, gpuIndex: gpuIndex, language: language,
                                operation: operation, targetLanguage: targetLanguage,
                                chatPort: chatPort, routerModel: routerModel, glossary: glossary)
            }
        }
        do {
            try converter.run()
            process = converter
        } catch {
            fail(error.localizedDescription)
        }
    }

    func previewVAD(modelURL: URL, vadModelURL: URL,
                    vadConfiguration: AudioVADConfiguration,
                    gpuIndex: Int, language: String) {
        guard let sourceURL, !isBusy, vadConfiguration.isEnabled else { return }
        guard FileManager.default.isExecutableFile(atPath: SpeechDictationController.binary),
              FileManager.default.fileExists(atPath: vadModelURL.path) else {
            vadPreviewState = .failed("Falta Whisper o Silero VAD / Whisper or Silero VAD is missing.")
            return
        }
        let id = UUID()
        runID = id
        stage = .analyzingVAD
        progress = 0.05
        vadPreviewState = .running
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToshLLM-vad-preview-\(id.uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            finishVADPreview(.failed(error.localizedDescription))
            return
        }
        workDirectory = directory
        let audioURL = directory.appendingPathComponent("preview.wav")
        let converter = Process()
        converter.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        converter.arguments = [sourceURL.path, audioURL.path, "-f", "WAVE", "-d", "LEI16@16000", "-c", "1"]
        converter.standardOutput = FileHandle.nullDevice
        converter.standardError = FileHandle.nullDevice
        converter.terminationHandler = { [weak self] completed in
            Task { @MainActor in
                guard let self, self.runID == id else { return }
                guard completed.terminationStatus == 0 else {
                    self.finishVADPreview(.failed("No se pudo preparar la muestra / the sample could not be prepared."))
                    return
                }
                self.runVADPreview(audioURL: audioURL, modelURL: modelURL,
                                   vadModelURL: vadModelURL, configuration: vadConfiguration,
                                   gpuIndex: gpuIndex, language: language, runID: id)
            }
        }
        do {
            try converter.run()
            process = converter
        } catch {
            finishVADPreview(.failed(error.localizedDescription))
        }
    }

    private func runVADPreview(audioURL: URL, modelURL: URL, vadModelURL: URL,
                               configuration: AudioVADConfiguration, gpuIndex: Int,
                               language: String, runID id: UUID) {
        guard let workDirectory else { return }
        let base = workDirectory.appendingPathComponent("vad-preview")
        let preview = Process()
        preview.executableURL = URL(fileURLWithPath: SpeechDictationController.binary)
        var arguments = Self.whisperArguments(
            audioURL: audioURL, modelURL: modelURL, vadModelURL: vadModelURL,
            vadConfiguration: configuration, outputBase: base,
            gpuIndex: gpuIndex, language: language
        )
        arguments.append(contentsOf: ["--duration", "30000"])
        preview.arguments = arguments
        preview.environment = SpeechDictationController.runtimeEnvironment(base: ProcessInfo.processInfo.environment)
        preview.standardOutput = FileHandle.nullDevice
        preview.standardError = FileHandle.nullDevice
        preview.terminationHandler = { [weak self] completed in
            Task { @MainActor in
                guard let self, self.runID == id else { return }
                guard completed.terminationStatus == 0 else {
                    self.finishVADPreview(.failed("VAD no pudo analizar la muestra / VAD could not analyze the sample."))
                    return
                }
                let raw = (try? String(contentsOf: base.appendingPathExtension("srt"), encoding: .utf8)) ?? ""
                let previewCues = SubtitleCue.parseSRT(raw)
                self.vadPreviewCues = previewCues
                let speech = previewCues.reduce(0) { $0 + max(0, $1.end - $1.start) }
                let sample = min(30, self.duration > 0 ? self.duration : 30)
                self.finishVADPreview(.ready(segmentCount: previewCues.count,
                                             speechSeconds: speech, sampleSeconds: sample))
            }
        }
        do {
            try preview.run()
            process = preview
            progress = 0.5
        } catch {
            finishVADPreview(.failed(error.localizedDescription))
        }
    }

    private func finishVADPreview(_ state: AudioVADPreviewState) {
        runID = nil
        process = nil
        stage = .idle
        progress = 0
        vadPreviewState = state
        cleanupWorkDirectory()
    }

    func cancel(clearResult: Bool = false) {
        runID = nil
        process?.terminate()
        process = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        translationTask?.cancel()
        translationTask = nil
        ticker?.cancel()
        ticker = nil
        cleanupWorkDirectory()
        progress = 0
        elapsed = 0
        stage = .idle
        if clearResult {
            cues = []
            originalCues = []
            translatedCues = []
            transcriptMode = .original
            translatedBatchCount = 0
            translationBatchCount = 0
            detectedLanguage = ""
            error = nil
        }
    }

    func shutdown() {
        player?.pause()
        isPlaying = false
        cancel()
    }

    func content(for format: AudioExportFormat,
                 track: AudioExportTrack = .translated) -> String {
        let selected = exportCues(track: track)
        switch format {
        case .srt: return SubtitleCue.srt(selected)
        case .vtt: return SubtitleCue.vtt(selected)
        case .text: return SubtitleCue.plainText(selected)
        case .json:
            let rows: [[String: Any]] = selected.map {
                ["id": $0.id, "start": $0.start, "end": $0.end, "text": $0.text]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: ["segments": rows], options: [.prettyPrinted, .sortedKeys]) else { return "" }
            return String(decoding: data, as: UTF8.self) + "\n"
        }
    }

    func exportCues(for track: AudioExportTrack) -> [SubtitleCue] {
        exportCues(track: track)
    }

    private func loadDuration(_ url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let value = try? await asset.load(.duration), sourceURL == url else { return }
        duration = max(0, value.seconds)
    }

    private func runWhisper(audioURL: URL, modelURL: URL, vadModelURL: URL,
                            vadConfiguration: AudioVADConfiguration, gpuIndex: Int,
                            language: String, operation: AudioStudioOperation,
                            targetLanguage: String, chatPort: Int, routerModel: String?,
                            glossary: String) {
        guard let id = runID, let workDirectory else { return }
        stage = .transcribing
        progress = 0.08
        let base = workDirectory.appendingPathComponent("result")
        outputBase = base

        let whisper = Process()
        whisper.executableURL = URL(fileURLWithPath: SpeechDictationController.binary)
        var arguments = Self.whisperArguments(
            audioURL: audioURL, modelURL: modelURL, vadModelURL: vadModelURL,
            vadConfiguration: vadConfiguration, outputBase: base,
            gpuIndex: gpuIndex, language: language
        )
        if operation == .translateEnglish { arguments.append("-tr") }
        whisper.arguments = arguments
        whisper.environment = SpeechDictationController.runtimeEnvironment(base: ProcessInfo.processInfo.environment)
        whisper.standardOutput = FileHandle.nullDevice
        let diagnostics = Pipe()
        stderrPipe = diagnostics
        whisper.standardError = diagnostics
        diagnostics.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.consumeDiagnostics(chunk, runID: id) }
        }
        whisper.terminationHandler = { [weak self] completed in
            Task { @MainActor in
                guard let self, self.runID == id else { return }
                self.stderrPipe?.fileHandleForReading.readabilityHandler = nil
                self.stderrPipe = nil
                self.process = nil
                guard completed.terminationStatus == 0 else {
                    self.fail(self.stderrBuffer.split(whereSeparator: \.isNewline).last.map(String.init) ?? "Whisper.cpp no pudo completar la transcripción / could not complete the transcription.")
                    return
                }
                self.loadWhisperResult(operation: operation, targetLanguage: targetLanguage,
                                       chatPort: chatPort, routerModel: routerModel, glossary: glossary)
            }
        }
        do {
            try whisper.run()
            process = whisper
        } catch {
            fail(error.localizedDescription)
        }
    }

    nonisolated static func whisperArguments(audioURL: URL, modelURL: URL, vadModelURL: URL,
                                             vadConfiguration: AudioVADConfiguration,
                                             outputBase: URL, gpuIndex: Int,
                                             language: String) -> [String] {
        var arguments = [
            "-m", modelURL.path, "-f", audioURL.path,
            "-l", language, "-dev", String(max(0, gpuIndex)),
            "-t", String(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount)))
        ]
        arguments.append(contentsOf: vadConfiguration.arguments(modelURL: vadModelURL))
        arguments.append(contentsOf: [
            "-of", outputBase.path, "-osrt", "-oj", "-pp", "-sow"
        ])
        return arguments
    }

    nonisolated static func cueID(at time: TimeInterval, in cues: [SubtitleCue]) -> Int? {
        guard time >= 0, !cues.isEmpty else { return nil }
        var lower = 0
        var upper = cues.count - 1
        while lower <= upper {
            let middle = lower + (upper - lower) / 2
            let cue = cues[middle]
            if time < cue.start {
                upper = middle - 1
            } else if time >= cue.end {
                lower = middle + 1
            } else {
                return cue.id
            }
        }
        return nil
    }

    private func consumeDiagnostics(_ chunk: String, runID: UUID) {
        guard self.runID == runID else { return }
        stderrBuffer += chunk
        if stderrBuffer.count > 32_000 { stderrBuffer = String(stderrBuffer.suffix(16_000)) }
        let pattern = #"progress\s*=\s*(\d+)%"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.matches(in: stderrBuffer, range: NSRange(stderrBuffer.startIndex..., in: stderrBuffer)).last,
              let range = Range(match.range(at: 1), in: stderrBuffer),
              let percent = Double(stderrBuffer[range]) else { return }
        progress = 0.08 + min(100, percent) / 100 * 0.67
    }

    private func loadWhisperResult(operation: AudioStudioOperation, targetLanguage: String,
                                   chatPort: Int, routerModel: String?, glossary: String) {
        guard let outputBase else { return }
        let srtURL = outputBase.appendingPathExtension("srt")
        let raw = (try? String(contentsOf: srtURL, encoding: .utf8)) ?? ""
        let parsed = SubtitleCue.parseSRT(raw)
        guard !parsed.isEmpty else {
            fail("No se detectó voz / no speech was detected.")
            return
        }
        originalCues = parsed
        translatedCues = []
        transcriptMode = .original
        refreshVisibleCues()
        readDetectedLanguage(outputBase.appendingPathExtension("json"))
        saveRecovery()
        if operation == .translateLocal {
            translate(parsed, targetLanguage: targetLanguage, port: chatPort,
                      routerModel: routerModel, glossary: glossary)
        } else {
            complete()
        }
    }

    private func readDetectedLanguage(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let result = root["result"] as? [String: Any], let language = result["language"] as? String {
            detectedLanguage = language
        } else if let language = root["language"] as? String {
            detectedLanguage = language
        }
    }

    func retryTranslation(targetLanguage: String, port: Int,
                          routerModel: String?, glossary: String) {
        guard canRetryTranslation else { return }
        switch stage {
        case .failed: break
        default: translatedCues = []
        }
        error = nil
        translate(originalCues, targetLanguage: targetLanguage, port: port,
                  routerModel: routerModel, glossary: glossary)
    }

    private func translate(_ source: [SubtitleCue], targetLanguage: String,
                           port: Int, routerModel: String?, glossary: String) {
        let sameTranslation = translationTargetLanguage == targetLanguage
            && translationModel == (routerModel ?? "")
            && translationGlossary == glossary
        let preserved = sameTranslation
            ? Dictionary(uniqueKeysWithValues: translatedCues.map { ($0.id, $0.text) })
            : [:]
        let pending = source.filter { preserved[$0.id] == nil }
        stage = .translating
        progress = 0.76
        let batches = Self.translationBatches(pending)
        translationTargetLanguage = targetLanguage
        translationModel = routerModel ?? ""
        translationGlossary = glossary
        translatedBatchCount = 0
        translationBatchCount = batches.count
        if !sameTranslation { translatedCues = [] }
        refreshVisibleCues()
        saveRecovery()
        guard !batches.isEmpty else {
            transcriptMode = .translated
            refreshVisibleCues()
            complete()
            return
        }
        translationTask = Task { [weak self] in
            guard let self else { return }
            do {
                var translated = preserved
                for (index, batch) in batches.enumerated() {
                    try Task.checkCancellation()
                    let context = Self.translationContext(for: batch, in: source, translated: translated)
                    let result = try await self.translateBatchResilient(
                        batch, targetLanguage: targetLanguage,
                        port: port, routerModel: routerModel,
                        glossary: glossary, context: context
                    )
                    translated.merge(result) { _, new in new }
                    self.translatedCues = source.compactMap { cue in
                        translated[cue.id].map {
                            SubtitleCue(id: cue.id, start: cue.start, end: cue.end, text: $0)
                        }
                    }
                    self.translatedBatchCount = index + 1
                    self.refreshVisibleCues()
                    self.saveRecovery()
                    self.progress = 0.76 + Double(index + 1) / Double(batches.count) * 0.22
                }
                self.translatedCues = source.map {
                    SubtitleCue(id: $0.id, start: $0.start, end: $0.end,
                                text: translated[$0.id] ?? $0.text)
                }
                self.transcriptMode = .translated
                self.refreshVisibleCues()
                self.saveRecovery()
                self.complete()
            } catch is CancellationError {
                return
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    private func translateBatch(_ cues: [SubtitleCue], targetLanguage: String,
                                port: Int, routerModel: String?, glossary: String,
                                context: String) async throws -> [Int: String] {
        let request = try Self.translationRequest(
            cues: cues, targetLanguage: targetLanguage, port: port,
            routerModel: routerModel, apiKey: ServerSettings.activeAPIKey(),
            glossary: glossary, context: context
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw AudioTranslationError.server(http.statusCode, Self.serverError(from: data))
        }
        return try Self.translations(from: data, expectedCues: cues)
    }

    private func translateBatchResilient(_ cues: [SubtitleCue], targetLanguage: String,
                                         port: Int, routerModel: String?, glossary: String,
                                         context: String) async throws -> [Int: String] {
        do {
            return try await translateBatch(cues, targetLanguage: targetLanguage,
                                            port: port, routerModel: routerModel,
                                            glossary: glossary, context: context)
        } catch AudioTranslationError.invalidResponse where cues.count > 1 {
            let middle = cues.count / 2
            let first = try await translateBatchResilient(
                Array(cues[..<middle]), targetLanguage: targetLanguage,
                port: port, routerModel: routerModel,
                glossary: glossary, context: context
            )
            let second = try await translateBatchResilient(
                Array(cues[middle...]), targetLanguage: targetLanguage,
                port: port, routerModel: routerModel,
                glossary: glossary, context: context
            )
            return first.merging(second) { _, translated in translated }
        } catch AudioTranslationError.invalidResponse where !context.isEmpty {
            return try await translateBatch(
                cues, targetLanguage: targetLanguage, port: port,
                routerModel: routerModel, glossary: glossary, context: ""
            )
        }
    }

    nonisolated static func translationRequest(cues: [SubtitleCue], targetLanguage: String,
                                               port: Int, routerModel: String?,
                                               apiKey: String?, glossary: String = "",
                                               context: String = "") throws -> URLRequest {
        let rows = cues.map { ["id": $0.id, "text": $0.text] as [String: Any] }
        let payload: [String: Any] = [
            "target_language": targetLanguage,
            "glossary": glossary,
            "neighboring_context": context,
            "cues": rows
        ]
        let input = try JSONSerialization.data(withJSONObject: payload)
        let prompt = String(decoding: input, as: UTF8.self)
        let itemSchemas: [[String: Any]] = cues.map { cue in
            [
                "type": "object",
                "properties": [
                    "id": ["const": cue.id],
                    "text": ["type": "string", "minLength": 1]
                ],
                "required": ["id", "text"],
                "additionalProperties": false
            ]
        }
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "translations": [
                    "type": "array", "prefixItems": itemSchemas,
                    "minItems": cues.count, "maxItems": cues.count
                ]
            ],
            "required": ["translations"],
            "additionalProperties": false
        ]
        var body: [String: Any] = [
            "stream": false,
            "temperature": 0.1,
            "max_tokens": min(8192, max(2048, cues.reduce(0) { $0 + $1.text.count } * 2)),
            "chat_template_kwargs": ["enable_thinking": false],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "subtitle_translation", "strict": true, "schema": schema
                ]
            ],
            "messages": [
                ["role": "system", "content": "Translate only the text inside the cues array into the requested target language. The source cue is authoritative: do not summarize, omit, invent, reorder, merge, split or expand its content. The glossary and neighboring_context are reference-only; never translate, copy, paraphrase or include their text in the answer. Keep terminology, names, tone and grammatical references consistent. Preserve each exact id and return one concise, non-empty translation for every cue. Return only the required JSON."],
                ["role": "user", "content": prompt]
            ]
        ]
        if let routerModel, !routerModel.isEmpty { body["model"] = routerModel }
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    nonisolated static func translations(from data: Data,
                                         expectedCues cues: [SubtitleCue]) throws -> [Int: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AudioTranslationError.invalidResponse
        }
        guard let first = content.firstIndex(of: "{"), let last = content.lastIndex(of: "}") else {
            throw AudioTranslationError.invalidResponse
        }
        let json = Data(content[first...last].utf8)
        guard let translatedRoot = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let translations = translatedRoot["translations"] as? [[String: Any]] else {
            throw AudioTranslationError.invalidResponse
        }
        var result: [Int: String] = [:]
        for row in translations {
            guard let id = row["id"] as? Int, let text = row["text"] as? String else { continue }
            result[id] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard result.count == cues.count,
              cues.allSatisfy({ result[$0.id]?.isEmpty == false }) else {
            throw AudioTranslationError.invalidResponse
        }
        for cue in cues {
            guard let text = result[cue.id], text.count <= max(100, cue.text.count * 3) else {
                throw AudioTranslationError.invalidResponse
            }
        }
        return result
    }

    nonisolated private static func serverError(from data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String else { return "" }
        return String(message.prefix(240))
    }

    nonisolated static func translationBatches(_ cues: [SubtitleCue]) -> [[SubtitleCue]] {
        cues.map { [$0] }
    }

    nonisolated static func translationContext(for batch: [SubtitleCue], in source: [SubtitleCue],
                                               translated: [Int: String]) -> String {
        guard let first = batch.first, let last = batch.last,
              let start = source.firstIndex(where: { $0.id == first.id }),
              let end = source.firstIndex(where: { $0.id == last.id }) else { return "" }
        let lower = max(0, start - 3)
        let upper = min(source.count - 1, end + 3)
        let neighboring = source[lower...upper].map { cue in
            let prior = translated[cue.id].map { " => \($0)" } ?? ""
            return "[\(cue.id)] \(cue.text)\(prior)"
        }.joined(separator: "\n")
        let memoryIDs = Array(translated.keys.sorted().prefix(6))
            + Array(translated.keys.sorted().suffix(8))
        let memory = Array(Set(memoryIDs)).sorted().compactMap { id -> String? in
            guard let sourceCue = source.first(where: { $0.id == id }),
                  let translatedText = translated[id] else { return nil }
            return "[\(id)] \(sourceCue.text) => \(translatedText)"
        }.joined(separator: "\n")
        return memory.isEmpty ? neighboring : "CONSISTENCY MEMORY:\n\(memory)\n\nNEIGHBORING CONTEXT:\n\(neighboring)"
    }

    func setTranscriptMode(_ mode: AudioTranscriptMode) {
        transcriptMode = mode
        refreshVisibleCues()
    }

    func cuePair(id: Int) -> (original: SubtitleCue?, translated: SubtitleCue?) {
        (originalCues.first { $0.id == id }, translatedCues.first { $0.id == id })
    }

    func updateCue(id: Int, text: String, translated: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recordEdit()
        if translated {
            guard let index = translatedCues.firstIndex(where: { $0.id == id }) else { return }
            translatedCues[index].text = trimmed
        } else {
            guard let index = originalCues.firstIndex(where: { $0.id == id }) else { return }
            originalCues[index].text = trimmed
        }
        refreshVisibleCues()
        saveRecovery()
    }

    func deleteCue(id: Int) {
        recordEdit()
        originalCues.removeAll { $0.id == id }
        translatedCues.removeAll { $0.id == id }
        normalizeCueIDs()
    }

    func mergeCueWithNext(id: Int) {
        guard let index = originalCues.firstIndex(where: { $0.id == id }),
              originalCues.indices.contains(index + 1) else { return }
        recordEdit()
        originalCues[index].end = originalCues[index + 1].end
        originalCues[index].text += " " + originalCues[index + 1].text
        originalCues.remove(at: index + 1)
        if let translatedIndex = translatedCues.firstIndex(where: { $0.id == id }),
           translatedCues.indices.contains(translatedIndex + 1) {
            translatedCues[translatedIndex].end = translatedCues[translatedIndex + 1].end
            translatedCues[translatedIndex].text += " " + translatedCues[translatedIndex + 1].text
            translatedCues.remove(at: translatedIndex + 1)
        }
        normalizeCueIDs()
    }

    func splitCue(id: Int) {
        guard let index = originalCues.firstIndex(where: { $0.id == id }) else { return }
        let cue = originalCues[index]
        let words = cue.text.split(whereSeparator: \.isWhitespace)
        guard words.count > 1 else { return }
        recordEdit()
        let middleWord = words.count / 2
        let middleTime = cue.start + (cue.end - cue.start) / 2
        originalCues[index] = SubtitleCue(id: cue.id, start: cue.start, end: middleTime,
                                          text: words[..<middleWord].joined(separator: " "))
        originalCues.insert(SubtitleCue(id: cue.id + 1, start: middleTime, end: cue.end,
                                       text: words[middleWord...].joined(separator: " ")), at: index + 1)
        if let translatedIndex = translatedCues.firstIndex(where: { $0.id == id }) {
            let translatedCue = translatedCues[translatedIndex]
            let translatedWords = translatedCue.text.split(whereSeparator: \.isWhitespace)
            if translatedWords.count > 1 {
                let translatedMiddle = translatedWords.count / 2
                translatedCues[translatedIndex] = SubtitleCue(
                    id: translatedCue.id, start: translatedCue.start, end: middleTime,
                    text: translatedWords[..<translatedMiddle].joined(separator: " ")
                )
                translatedCues.insert(SubtitleCue(
                    id: translatedCue.id + 1, start: middleTime, end: translatedCue.end,
                    text: translatedWords[translatedMiddle...].joined(separator: " ")
                ), at: translatedIndex + 1)
            } else {
                translatedCues.remove(at: translatedIndex)
            }
        }
        normalizeCueIDs()
    }

    func replaceAll(_ search: String, with replacement: String) {
        guard !search.isEmpty else { return }
        recordEdit()
        originalCues = originalCues.map { cue in
            var updated = cue
            updated.text = cue.text.replacingOccurrences(of: search, with: replacement,
                                                         options: [.caseInsensitive, .diacriticInsensitive])
            return updated
        }
        translatedCues = translatedCues.map { cue in
            var updated = cue
            updated.text = cue.text.replacingOccurrences(of: search, with: replacement,
                                                         options: [.caseInsensitive, .diacriticInsensitive])
            return updated
        }
        refreshVisibleCues()
        saveRecovery()
    }

    func undoEdit() {
        guard let previous = undoHistory.popLast() else { return }
        redoHistory.append((originalCues, translatedCues))
        originalCues = previous.0
        translatedCues = previous.1
        refreshVisibleCues()
        saveRecovery()
    }

    func redoEdit() {
        guard let next = redoHistory.popLast() else { return }
        undoHistory.append((originalCues, translatedCues))
        originalCues = next.0
        translatedCues = next.1
        refreshVisibleCues()
        saveRecovery()
    }

    var canUndoEdit: Bool { !undoHistory.isEmpty }
    var canRedoEdit: Bool { !redoHistory.isEmpty }

    private func recordEdit() {
        undoHistory.append((originalCues, translatedCues))
        if undoHistory.count > 50 { undoHistory.removeFirst() }
        redoHistory.removeAll()
    }

    func saveProject(to url: URL, targetLanguage: String, glossary: String) throws {
        let document = projectDocument(targetLanguage: targetLanguage, glossary: glossary)
        let data = try JSONEncoder.audioProject.encode(document)
        try data.write(to: url, options: .atomic)
    }

    func loadProject(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let document = try JSONDecoder.audioProject.decode(AudioProjectDocument.self, from: data)
        let mediaURL = URL(fileURLWithPath: document.sourcePath)
        guard FileManager.default.fileExists(atPath: mediaURL.path) else {
            throw CocoaError(.fileNoSuchFile,
                             userInfo: [NSLocalizedDescriptionKey: "No se encontró el audio o vídeo original / the original audio or video could not be found."])
        }
        select(mediaURL)
        originalCues = document.originalCues
        translatedCues = document.translatedCues
        detectedLanguage = document.detectedLanguage
        translationTargetLanguage = document.targetLanguage
        translationModel = document.translationModel
        translationGlossary = document.glossary
        transcriptMode = translatedCues.isEmpty ? .original : .bilingual
        refreshVisibleCues()
        saveRecovery()
    }

    func loadRecoveryProject() throws {
        try loadProject(from: Self.recoveryURL)
    }

    private func normalizeCueIDs() {
        let translationByID = Dictionary(uniqueKeysWithValues: translatedCues.map { ($0.id, $0.text) })
        let pairs = originalCues.enumerated().map { offset, cue in
            (SubtitleCue(id: offset + 1, start: cue.start, end: cue.end, text: cue.text),
             translationByID[cue.id])
        }
        originalCues = pairs.map(\.0)
        translatedCues = pairs.compactMap { cue, translation in
            translation.map {
                SubtitleCue(id: cue.id, start: cue.start, end: cue.end, text: $0)
            }
        }
        refreshVisibleCues()
        saveRecovery()
    }

    private func exportCues(track: AudioExportTrack) -> [SubtitleCue] {
        switch track {
        case .original:
            originalCues
        case .translated:
            translatedCues.isEmpty ? originalCues : translatedCues
        case .bilingual:
            originalCues.map { cue in
                let translated = translatedCues.first { $0.id == cue.id }?.text
                let text = translated.map { "\(cue.text)\n\($0)" } ?? cue.text
                return SubtitleCue(id: cue.id, start: cue.start, end: cue.end, text: text)
            }
        }
    }

    private func refreshVisibleCues() {
        switch transcriptMode {
        case .original, .bilingual:
            cues = originalCues
        case .translated:
            cues = translatedCues.isEmpty ? originalCues : translatedCues
        }
    }

    private func projectDocument(targetLanguage: String, glossary: String) -> AudioProjectDocument {
        AudioProjectDocument(
            version: 1, savedAt: .now, sourcePath: sourceURL?.path ?? "",
            detectedLanguage: detectedLanguage, targetLanguage: targetLanguage,
            translationModel: translationModel, glossary: glossary,
            originalCues: originalCues, translatedCues: translatedCues
        )
    }

    private func saveRecovery() {
        guard sourceURL != nil, !originalCues.isEmpty else { return }
        do {
            let url = Self.recoveryURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let document = projectDocument(targetLanguage: translationTargetLanguage,
                                           glossary: translationGlossary)
            try JSONEncoder.audioProject.encode(document).write(to: url, options: .atomic)
        } catch {
            AppLog.speech.error("audio recovery save failed: \(error.localizedDescription)")
        }
    }

    private func complete() {
        runID = nil
        translationTask = nil
        stage = .completed
        progress = 1
        ticker?.cancel()
        ticker = nil
        cleanupWorkDirectory()
        restorePersistentModelIfNeeded()
    }

    private func fail(_ message: String) {
        runID = nil
        translationTask = nil
        stage = .failed(message)
        error = message
        process = nil
        ticker?.cancel()
        ticker = nil
        cleanupWorkDirectory()
        restorePersistentModelIfNeeded()
    }

    private func startTicker() {
        elapsed = 0
        ticker?.cancel()
        ticker = Task { [weak self] in
            let started = Date.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.elapsed = Date.now.timeIntervalSince(started)
            }
        }
    }

    private func restorePersistentModelIfNeeded() {
        guard shouldRestorePersistentModel, let restoreModelURL else { return }
        shouldRestorePersistentModel = false
        SpeechDictationController.shared.preload(modelURL: restoreModelURL, gpuIndex: restoreGPUIndex)
    }

    private func cleanupWorkDirectory() {
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
        workDirectory = nil
        outputBase = nil
        stderrBuffer = ""
    }

}
