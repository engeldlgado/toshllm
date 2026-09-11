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

    func export(sourceURL: URL, cues: [SubtitleCue], outputURL: URL,
                style: SubtitleStyle = .load()) {
        guard !isExporting, !cues.isEmpty else { return }
        isExporting = true
        progress = 0
        error = nil
        completedURL = nil
        Task {
            do {
                try await performExport(sourceURL: sourceURL, cues: cues, outputURL: outputURL, style: style)
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

    private func performExport(sourceURL: URL, cues: [SubtitleCue], outputURL: URL,
                               style: SubtitleStyle) async throws {
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
        cues.forEach { parentLayer.addSublayer(Self.subtitleLayer(for: $0, size: size, style: style)) }
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parentLayer
        )

        try await Self.preserveColour(from: sourceVideo, on: videoComposition)

        let preset = await Self.preset(for: composition, source: sourceVideo)
        guard let export = AVAssetExportSession(asset: composition, presetName: preset) else {
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

    /// Burning text in means re-encoding, but not necessarily down a generation:
    /// an HEVC source re-encoded as H.264 pays for nothing.
    nonisolated private static func preset(for composition: AVAsset,
                                           source: AVAssetTrack) async -> String {
        let available = AVAssetExportSession.exportPresets(compatibleWith: composition)
        guard let formats = try? await source.load(.formatDescriptions),
              formats.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC }),
              available.contains(AVAssetExportPresetHEVCHighestQuality) else {
            return AVAssetExportPresetHighestQuality
        }
        return AVAssetExportPresetHEVCHighestQuality
    }

    /// Without carrying the source's colour tags across, a wide-gamut or HDR clip
    /// comes back flattened.
    nonisolated private static func preserveColour(from source: AVAssetTrack,
                                                   on composition: AVMutableVideoComposition) async throws {
        guard let format = try await source.load(.formatDescriptions).first else { return }
        let ext = CMFormatDescriptionGetExtensions(format) as? [CFString: Any]
        guard let primaries = ext?[kCMFormatDescriptionExtension_ColorPrimaries] as? String,
              let transfer = ext?[kCMFormatDescriptionExtension_TransferFunction] as? String,
              let matrix = ext?[kCMFormatDescriptionExtension_YCbCrMatrix] as? String else { return }
        composition.colorPrimaries = primaries
        composition.colorTransferFunction = transfer
        composition.colorYCbCrMatrix = matrix
    }

    nonisolated private static func subtitleLayer(for cue: SubtitleCue, size: CGSize,
                                                  style: SubtitleStyle) -> CALayer {
        let l = SubtitleLayout.layout(text: cue.text, style: style, frame: size)
        let text = CATextLayer()
        text.string = l.attributed
        text.alignmentMode = .center
        text.isWrapped = true
        text.contentsScale = 2

        guard style.background == .box else {
            text.frame = l.box.insetBy(dx: l.textInset, dy: l.textInset)
            animate(text, cue: cue)
            return text
        }
        let plate = CALayer()
        plate.frame = l.box
        plate.backgroundColor = CGColor(gray: 0, alpha: style.backgroundOpacity)
        plate.cornerRadius = 8
        text.frame = CGRect(x: l.textInset, y: l.textInset,
                            width: l.box.width - l.textInset * 2,
                            height: l.box.height - l.textInset * 2)
        plate.addSublayer(text)
        animate(plate, cue: cue)
        return plate
    }

    nonisolated private static func animate(_ layer: CALayer, cue: SubtitleCue) {
        layer.opacity = 0
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 1, 1, 0]
        animation.keyTimes = [0, 0.02, 0.98, 1]
        animation.beginTime = AVCoreAnimationBeginTimeAtZero + cue.start
        animation.duration = max(0.1, cue.end - cue.start)
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        layer.add(animation, forKey: "visibility")
    }
}
