// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Combine
import Foundation

@MainActor
final class SpeechDictationController: ObservableObject {
    static let shared = SpeechDictationController()

    @Published private(set) var isDictating = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var statusText: String?
    @Published private(set) var isModelKeptLoaded = false
    @Published var error: String?

    private var recorder: AVAudioRecorder?
    private var process: Process?
    private var serverProcess: Process?
    private var serverErrorPipe: Pipe?
    private var serverModelURL: URL?
    private var serverGPUIndex: Int?
    private var serverStartTask: Task<Void, Error>?
    private var inferenceTask: URLSessionDataTask?
    private var audioURL: URL?
    private var transcriptBaseURL: URL?
    private var timestampedOutput = false
    private var onText: ((String) -> Void)?
    private var onFailure: (() -> Void)?
    private var transcriptionID: UUID?
    private static let serverPort = 18_091

    static var binary: String {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin-audio/whisper-cli").path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("vendor/whisper.cpp/build-static/bin/whisper-cli").path
    }

    static var engineInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: binary)
    }

    static var serverBinary: String {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin-audio/whisper-server").path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("vendor/whisper.cpp/build-static/bin/whisper-server").path
    }

    static var persistentEngineInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: serverBinary)
    }

    nonisolated static func runtimeEnvironment(base: [String: String]) -> [String: String] {
        var environment = base
        environment["GGML_METAL_CONCURRENCY_DISABLE"] = "1"
        environment["GGML_METAL_SHARED_BUFFERS_DISABLE"] = "1"
        environment["TOSH_FA_AMD"] = "1"
        return environment
    }

    func toggle(modelURL: URL, gpuIndex: Int, loadPolicy: WhisperLoadPolicy,
                onText: @escaping (String) -> Void) {
        if isTranscribing {
            cancel()
        } else if isDictating {
            stopAndTranscribe(modelURL: modelURL, gpuIndex: gpuIndex, loadPolicy: loadPolicy)
        } else {
            Task { await start(onText: onText) }
        }
    }

    func transcribe(fileURL: URL, modelURL: URL, gpuIndex: Int,
                    loadPolicy: WhisperLoadPolicy,
                    onText: @escaping (String) -> Void,
                    onFailure: @escaping () -> Void) {
        guard !isDictating, !isTranscribing else {
            error = "Ya hay una transcripción en curso / a transcription is already running."
            onFailure()
            return
        }
        guard Self.engineInstalled else {
            error = "No se encontró el motor de Whisper.cpp. Vuelve a instalar ToshLLM / the Whisper.cpp engine is missing. Reinstall ToshLLM."
            onFailure()
            return
        }

        let converted = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToshLLM-whisper-\(UUID().uuidString).wav")
        audioURL = converted
        self.onText = onText
        self.onFailure = onFailure
        error = nil
        statusText = "Preparando audio… / Preparing audio…"
        isTranscribing = true

        let runID = UUID()
        transcriptionID = runID
        let converter = Process()
        converter.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        converter.arguments = [fileURL.path, converted.path, "-f", "WAVE", "-d", "LEI16@16000", "-c", "1"]
        converter.standardOutput = FileHandle.nullDevice
        let diagnostics = Pipe()
        converter.standardError = diagnostics
        converter.terminationHandler = { [weak self] completed in
            let data = diagnostics.fileHandleForReading.readDataToEndOfFile()
            let details = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor in
                guard let self, self.transcriptionID == runID else { return }
                self.process = nil
                guard completed.terminationStatus == 0 else {
                    self.fail(runID: runID,
                              message: details.trimmingCharacters(in: .whitespacesAndNewlines))
                    return
                }
                self.runWhisper(audioURL: converted, modelURL: modelURL, gpuIndex: gpuIndex,
                                loadPolicy: loadPolicy, withTimestamps: true)
            }
        }
        do {
            try converter.run()
            process = converter
        } catch {
            fail(runID: runID, message: error.localizedDescription)
        }
    }

    private func start(onText: @escaping (String) -> Void) async {
        guard Self.engineInstalled else {
            error = "No se encontró el motor de Whisper.cpp. Vuelve a instalar ToshLLM / the Whisper.cpp engine is missing. Reinstall ToshLLM."
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            error = "El acceso al micrófono está denegado. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Micrófono / microphone access was denied. Enable it in System Settings → Privacy & Security → Microphone."
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToshLLM-whisper-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            audioURL = url
            self.onText = onText
            error = nil
            statusText = nil
            isDictating = true
        } catch {
            self.error = error.localizedDescription
            cleanupFiles()
        }
    }

    private func stopAndTranscribe(modelURL: URL, gpuIndex: Int,
                                   loadPolicy: WhisperLoadPolicy) {
        recorder?.stop()
        recorder = nil
        isDictating = false
        guard let audioURL else { return }

        runWhisper(audioURL: audioURL, modelURL: modelURL, gpuIndex: gpuIndex,
                   loadPolicy: loadPolicy, withTimestamps: false)
    }

    private func runWhisper(audioURL: URL, modelURL: URL, gpuIndex: Int,
                            loadPolicy: WhisperLoadPolicy, withTimestamps: Bool) {
        if loadPolicy == .alwaysLoaded {
            runWithPersistentServer(audioURL: audioURL, modelURL: modelURL,
                                    gpuIndex: gpuIndex, withTimestamps: withTimestamps)
            return
        }
        let outputBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToshLLM-transcript-\(UUID().uuidString)")
        transcriptBaseURL = outputBase
        timestampedOutput = withTimestamps

        let p = Process()
        let runID = UUID()
        transcriptionID = runID
        p.executableURL = URL(fileURLWithPath: Self.binary)
        var arguments = [
            "-m", modelURL.path,
            "-f", audioURL.path,
            "-l", "auto",
            "-dev", String(max(0, gpuIndex)),
            "-t", String(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))),
            "-np", "-of", outputBase.path
        ]
        arguments += withTimestamps ? ["-oj"] : ["-nt", "-otxt"]
        p.arguments = arguments
        // AMD Flash Attention remains opt-in after Metal initializes.
        p.environment = Self.runtimeEnvironment(base: ProcessInfo.processInfo.environment)
        p.standardOutput = FileHandle.nullDevice
        let diagnostics = Pipe()
        p.standardError = diagnostics
        p.terminationHandler = { [weak self] completed in
            let data = diagnostics.fileHandleForReading.readDataToEndOfFile()
            let details = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor in
                self?.finish(runID: runID, status: completed.terminationStatus, diagnostics: details)
            }
        }

        statusText = "Transcribiendo en la GPU… / Transcribing on the GPU…"
        isTranscribing = true
        do {
            try p.run()
            process = p
        } catch {
            fail(runID: runID, message: error.localizedDescription)
        }
    }

    func preload(modelURL: URL, gpuIndex: Int) {
        guard Self.persistentEngineInstalled else {
            error = "No se encontró el servicio persistente de Whisper.cpp / the persistent Whisper.cpp service is missing."
            return
        }
        Task {
            do {
                statusText = "Cargando Whisper en la GPU… / Loading Whisper on the GPU…"
                try await ensureServer(modelURL: modelURL, gpuIndex: gpuIndex)
                statusText = nil
            } catch {
                statusText = nil
                self.error = error.localizedDescription
            }
        }
    }

    func unloadPersistentModel() {
        serverStartTask?.cancel()
        serverStartTask = nil
        if let serverProcess, serverProcess.isRunning { serverProcess.terminate() }
        serverErrorPipe?.fileHandleForReading.readabilityHandler = nil
        serverProcess = nil
        serverErrorPipe = nil
        serverModelURL = nil
        serverGPUIndex = nil
        isModelKeptLoaded = false
    }

    func shutdown() {
        // Shutdown must not advance the transcription queue.
        onText = nil
        onFailure = nil
        cancel()
        unloadPersistentModel()
    }

    private func runWithPersistentServer(audioURL: URL, modelURL: URL,
                                         gpuIndex: Int, withTimestamps: Bool) {
        guard Self.persistentEngineInstalled else {
            let runID = UUID()
            transcriptionID = runID
            fail(runID: runID,
                 message: "No se encontró el servicio persistente de Whisper.cpp / the persistent Whisper.cpp service is missing.")
            return
        }
        let runID = UUID()
        transcriptionID = runID
        timestampedOutput = withTimestamps
        statusText = isModelKeptLoaded
            ? "Transcribiendo en la GPU… / Transcribing on the GPU…"
            : "Cargando Whisper en la GPU… / Loading Whisper on the GPU…"
        isTranscribing = true
        Task {
            do {
                try await ensureServer(modelURL: modelURL, gpuIndex: gpuIndex)
                guard transcriptionID == runID else { return }
                statusText = "Transcribiendo en la GPU… / Transcribing on the GPU…"
                try submitToServer(audioURL: audioURL, runID: runID,
                                   withTimestamps: withTimestamps)
            } catch {
                fail(runID: runID, message: error.localizedDescription)
            }
        }
    }

    private func ensureServer(modelURL: URL, gpuIndex: Int) async throws {
        let normalizedGPU = max(0, gpuIndex)
        if serverProcess?.isRunning == true,
           serverModelURL == modelURL, serverGPUIndex == normalizedGPU,
           isModelKeptLoaded { return }
        if let serverStartTask { try await serverStartTask.value; return }

        unloadPersistentModel()
        let task = Task { @MainActor in
            let server = Process()
            server.executableURL = URL(fileURLWithPath: Self.serverBinary)
            server.arguments = [
                "-m", modelURL.path,
                "-l", "auto",
                "-dev", String(normalizedGPU),
                "-t", String(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))),
                "-bs", "5", "-bo", "5",
                "--host", "127.0.0.1", "--port", String(Self.serverPort)
            ]
            server.environment = Self.runtimeEnvironment(base: ProcessInfo.processInfo.environment)
            server.standardOutput = FileHandle.nullDevice
            let diagnostics = Pipe()
            server.standardError = diagnostics
            diagnostics.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
                AppLog.speech.debug("Whisper service: \(line, privacy: .public)")
            }
            server.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.serverProcess === server else { return }
                    self.serverProcess = nil
                    self.serverModelURL = nil
                    self.serverGPUIndex = nil
                    self.isModelKeptLoaded = false
                }
            }
            try server.run()
            serverProcess = server
            serverErrorPipe = diagnostics
            serverModelURL = modelURL
            serverGPUIndex = normalizedGPU

            let readyURL = URL(string: "http://127.0.0.1:\(Self.serverPort)/")!
            for _ in 0..<600 {
                try Task.checkCancellation()
                guard server.isRunning else {
                    throw CocoaError(.executableLoad,
                                     userInfo: [NSLocalizedDescriptionKey: "Whisper.cpp no pudo mantener el modelo cargado / couldn't keep the Whisper.cpp model loaded."])
                }
                var request = URLRequest(url: readyURL)
                request.timeoutInterval = 0.25
                if let (_, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    isModelKeptLoaded = true
                    return
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw URLError(.timedOut)
        }
        serverStartTask = task
        defer { serverStartTask = nil }
        try await task.value
    }

    private func submitToServer(audioURL: URL, runID: UUID,
                                withTimestamps: Bool) throws {
        let audio = try Data(contentsOf: audioURL)
        let boundary = "ToshLLM-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        field("language", "auto")
        field("response_format", withTimestamps ? "verbose_json" : "json")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        append("\r\n--\(boundary)--\r\n")

        let url = URL(string: "http://127.0.0.1:\(Self.serverPort)/inference")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3_600
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        inferenceTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                self?.finishServer(runID: runID, data: data, response: response, error: error)
            }
        }
        inferenceTask?.resume()
    }

    private func finishServer(runID: UUID, data: Data?, response: URLResponse?, error: Error?) {
        guard transcriptionID == runID else { return }
        inferenceTask = nil
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard error == nil, (200..<300).contains(status), let data else {
            let message = error?.localizedDescription
                ?? data.flatMap { String(data: $0, encoding: .utf8) }
                ?? "Whisper.cpp no pudo transcribir con la GPU / Whisper.cpp could not transcribe with the GPU."
            fail(runID: runID, message: message)
            return
        }
        let raw: String
        if timestampedOutput {
            raw = WhisperTranscript.timestamped(jsonData: data) ?? ""
        } else if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            raw = root["text"] as? String ?? ""
        } else {
            raw = ""
        }
        finishText(runID: runID, raw: raw)
    }

    private func finish(runID: UUID, status: Int32, diagnostics: String) {
        guard transcriptionID == runID else { return }

        guard status == 0, let transcriptBaseURL else {
            transcriptionID = nil
            process = nil
            isTranscribing = false
            statusText = nil
            let lastLine = diagnostics.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            error = lastLine.isEmpty
                ? "Whisper.cpp no pudo transcribir con la GPU / Whisper.cpp could not transcribe with the GPU."
                : lastLine
            AppLog.speech.error("Whisper failed: \(diagnostics, privacy: .public)")
            let failure = onFailure
            cleanupFiles()
            failure?()
            return
        }
        let outputURL = transcriptBaseURL.appendingPathExtension(timestampedOutput ? "json" : "txt")
        let raw: String
        if timestampedOutput, let data = try? Data(contentsOf: outputURL) {
            raw = WhisperTranscript.timestamped(jsonData: data) ?? ""
        } else {
            raw = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        }
        finishText(runID: runID, raw: raw)
    }

    private func finishText(runID: UUID, raw: String) {
        guard transcriptionID == runID else { return }
        transcriptionID = nil
        process = nil
        isTranscribing = false
        statusText = nil
        let text = WhisperTranscript.normalized(raw)
        guard !text.isEmpty else {
            error = "No se detectó voz / no speech was detected."
            let failure = onFailure
            cleanupFiles()
            failure?()
            return
        }
        let completion = onText
        cleanupFiles()
        completion?(text)
    }

    private func fail(runID: UUID, message: String) {
        guard transcriptionID == runID else { return }
        transcriptionID = nil
        process = nil
        isTranscribing = false
        statusText = nil
        error = message.isEmpty
            ? "No se pudo preparar el audio / the audio could not be prepared."
            : message
        let failure = onFailure
        cleanupFiles()
        failure?()
    }

    func cancel() {
        transcriptionID = nil
        recorder?.stop()
        recorder = nil
        process?.terminate()
        process = nil
        inferenceTask?.cancel()
        inferenceTask = nil
        isDictating = false
        isTranscribing = false
        statusText = nil
        let failure = onFailure
        cleanupFiles()
        failure?()
    }

    private func cleanupFiles() {
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        if let transcriptBaseURL {
            try? FileManager.default.removeItem(at: transcriptBaseURL.appendingPathExtension("txt"))
            try? FileManager.default.removeItem(at: transcriptBaseURL.appendingPathExtension("json"))
        }
        audioURL = nil
        transcriptBaseURL = nil
        timestampedOutput = false
        onText = nil
        onFailure = nil
    }
}
