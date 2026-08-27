// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Combine
import QuartzCore

@MainActor
final class SubtitleVideoExporter: ObservableObject {
    @Published private(set) var isExporting = false
    @Published private(set) var progress = 0.0
    @Published private(set) var error: String?
    @Published private(set) var completedURL: URL?

    private var session: AVAssetExportSession?
    private var progressTask: Task<Void, Never>?

    func export(sourceURL: URL, cues: [SubtitleCue], outputURL: URL) {
        guard !isExporting, !cues.isEmpty else { return }
        isExporting = true
        progress = 0
        error = nil
        completedURL = nil
        Task {
            do {
                try await performExport(sourceURL: sourceURL, cues: cues, outputURL: outputURL)
                progress = 1
                completedURL = outputURL
            } catch {
                self.error = error.localizedDescription
            }
            progressTask?.cancel()
            progressTask = nil
            session = nil
            isExporting = false
        }
    }

    func cancel() {
        session?.cancelExport()
        progressTask?.cancel()
        isExporting = false
    }

    private func performExport(sourceURL: URL, cues: [SubtitleCue], outputURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first,
              let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.fileReadUnsupportedScheme,
                             userInfo: [NSLocalizedDescriptionKey: "El archivo no contiene vídeo / the file contains no video."])
        }
        try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
        if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid) {
            try audioTrack.insertTimeRange(range, of: sourceAudio, at: .zero)
        }

        let videoComposition = AVMutableVideoComposition(propertiesOf: composition)
        let size = videoComposition.renderSize
        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: size)
        videoLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)
        cues.forEach { parentLayer.addSublayer(Self.subtitleLayer(for: $0, size: size)) }
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parentLayer
        )

        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetHighestQuality) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try? FileManager.default.removeItem(at: outputURL)
        export.outputURL = outputURL
        export.outputFileType = .mov
        export.shouldOptimizeForNetworkUse = true
        export.videoComposition = videoComposition
        session = export
        progressTask = Task { [weak self, weak export] in
            while !Task.isCancelled, let export {
                self?.progress = Double(export.progress)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        await withCheckedContinuation { continuation in
            export.exportAsynchronously { continuation.resume() }
        }
        if export.status != .completed {
            throw export.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    nonisolated private static func subtitleLayer(for cue: SubtitleCue, size: CGSize) -> CALayer {
        let layer = CATextLayer()
        layer.string = cue.text
        layer.alignmentMode = .center
        layer.isWrapped = true
        layer.contentsScale = 2
        layer.fontSize = max(22, size.height * 0.038)
        layer.foregroundColor = CGColor(gray: 1, alpha: 1)
        layer.backgroundColor = CGColor(gray: 0, alpha: 0.72)
        layer.cornerRadius = 8
        let width = size.width * 0.86
        let height = max(72, size.height * 0.16)
        layer.frame = CGRect(x: (size.width - width) / 2, y: size.height * 0.06,
                             width: width, height: height)
        layer.opacity = 0
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 1, 1, 0]
        animation.keyTimes = [0, 0.02, 0.98, 1]
        animation.beginTime = AVCoreAnimationBeginTimeAtZero + cue.start
        animation.duration = max(0.1, cue.end - cue.start)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        layer.add(animation, forKey: "visibility")
        return layer
    }
}
