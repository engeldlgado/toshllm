import AVFoundation
import Foundation
import Speech

/// On-device speech-to-text streamed into a callback. A pause ends a segment, so
/// finished segments are committed and a fresh one starts to keep the text growing.
@MainActor
final class SpeechDictationController: ObservableObject {
    @Published private(set) var isDictating = false
    @Published var error: String?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var onText: ((String) -> Void)?
    private var committed = ""
    private var stoppingByUser = false
    // The realtime audio tap appends here; swapped when a segment restarts.
    private nonisolated(unsafe) var liveRequest: SFSpeechAudioBufferRecognitionRequest?

    func toggle(onText: @escaping (String) -> Void) {
        if isDictating { stop() } else { Task { await start(onText: onText) } }
    }

    private func start(onText: @escaping (String) -> Void) async {
        guard await Self.requestAuthorization() else {
            error = "El dictado está desactivado. Actívalo en Ajustes del Sistema → Teclado → Dictado, y concede el permiso de reconocimiento de voz / dictation is off. Enable it in System Settings → Keyboard → Dictation and grant speech recognition permission."
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            error = "El acceso al micrófono está denegado. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Micrófono / microphone access was denied. Enable it in System Settings → Privacy & Security → Microphone."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            error = "El dictado no está disponible para este idioma / dictation isn't available for this language."
            return
        }

        self.recognizer = recognizer
        self.onText = onText
        committed = ""
        stoppingByUser = false

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.liveRequest?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.error = error.localizedDescription
            return
        }
        isDictating = true
        error = nil
        beginSegment()
    }

    private func beginSegment() {
        guard let recognizer, isDictating else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        liveRequest = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, err in
            let partial = result?.bestTranscription.formattedString
            let failure = err as NSError?
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self, self.isDictating else { return }
                if let partial { self.onText?(self.compose(partial)) }
                if let failure, !self.stoppingByUser, !Self.isBenign(failure) {
                    self.error = failure.localizedDescription
                    self.stop()
                    return
                }
                if final {
                    if let partial, !partial.isEmpty {
                        self.committed = self.compose(partial)
                    }
                    self.task = nil
                    self.beginSegment()
                }
            }
        }
    }

    private func compose(_ partial: String) -> String {
        guard !partial.isEmpty else { return committed }
        return committed.isEmpty ? partial : committed + " " + partial
    }

    func stop() {
        guard isDictating else { return }
        stoppingByUser = true
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        liveRequest?.endAudio()
        task?.cancel()
        task = nil
        liveRequest = nil
        onText = nil
        recognizer = nil
        committed = ""
        isDictating = false
    }

    // Cancellation (our own stop) and "no speech detected" are not real failures.
    private static func isBenign(_ error: NSError) -> Bool {
        error.domain == "kAFAssistantErrorDomain" && [203, 216, 1110].contains(error.code)
    }

    private static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }
}
