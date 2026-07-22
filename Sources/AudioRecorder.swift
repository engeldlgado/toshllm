import AVFoundation
import Foundation

@MainActor
final class AudioRecorderController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var duration: TimeInterval = 0
    @Published var error: String?

    private var recorder: AVAudioRecorder?
    private var ticker: Task<Void, Never>?
    private var outputURL: URL?

    func toggle(onComplete: @escaping (ChatAttachment) -> Void) {
        if isRecording {
            if let attachment = stop() { onComplete(attachment) }
        } else {
            Task { await start() }
        }
    }

    private func start() async {
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else {
            error = "Microphone access was denied. Enable it in System Settings → Privacy & Security → Microphone."
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToshLLM-recording-\(UUID().uuidString).wav")
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
            outputURL = url
            duration = 0
            error = nil
            isRecording = true
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(0.2))
                    guard let self else { return }
                    duration = recorder.currentTime
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func stop() -> ChatAttachment? {
        recorder?.stop()
        ticker?.cancel()
        ticker = nil
        isRecording = false
        recorder = nil
        guard let url = outputURL, let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        outputURL = nil
        return ChatAttachment(name: "Recording \(Date.now.formatted(date: .omitted, time: .shortened)).wav",
                              content: "", mimeType: "audio/wav",
                              dataURI: "data:audio/wav;base64," + data.base64EncodedString(),
                              byteCount: data.count)
    }
}
