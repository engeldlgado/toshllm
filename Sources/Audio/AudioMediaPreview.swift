// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import AVKit
import AVFoundation
import SwiftUI

struct AudioMediaPreview: View {
    @ObservedObject var studio: AudioStudioController
    @ObservedObject private var playback: AudioPlaybackState
    @EnvironmentObject private var loc: Localizer
    @State private var position = 0.0
    @State private var scrubbing = false
    @State private var waveform: [CGFloat] = []

    init(studio: AudioStudioController) {
        self.studio = studio
        _playback = ObservedObject(wrappedValue: studio.playback)
    }

    var body: some View {
        VStack(spacing: 12) {
            if studio.isVideo, let player = studio.player {
                VideoPlayer(player: player)
                    .frame(minHeight: 180, idealHeight: 240, maxHeight: 320)
                    .clipShape(.rect(cornerRadius: 10))
            } else {
                ZStack(alignment: .topTrailing) {
                    AudioWaveformView(samples: waveform,
                                      progress: studio.duration > 0 ? position / studio.duration : 0)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 28)
                    Text("\(MediaTime.compact(position)) / \(MediaTime.compact(studio.duration))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(WorkspaceStyle.inset, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorkspaceStyle.border))
            }

            HStack(spacing: 10) {
                Button(loc.t("Retroceder 15 segundos", "Back 15 seconds"),
                       systemImage: "gobackward.15") {
                    studio.seek(to: max(0, position - 15))
                }
                .labelStyle(.iconOnly)
                .buttonStyle(GlassIconButtonStyle())
                .iconHelp(loc.t("Retroceder 15 segundos", "Back 15 seconds"))

                Button(action: studio.togglePlayback) {
                    Label(studio.isPlaying ? loc.t("Pausar", "Pause") : loc.t("Reproducir", "Play"),
                          systemImage: studio.isPlaying ? "pause.fill" : "play.fill")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(GlassIconButtonStyle(active: true))
                .iconHelp(studio.isPlaying ? loc.t("Pausar", "Pause") : loc.t("Reproducir", "Play"))

                Button(loc.t("Avanzar 15 segundos", "Forward 15 seconds"),
                       systemImage: "goforward.15") {
                    studio.seek(to: min(studio.duration, position + 15))
                }
                .labelStyle(.iconOnly)
                .buttonStyle(GlassIconButtonStyle())
                .iconHelp(loc.t("Avanzar 15 segundos", "Forward 15 seconds"))

                Text(MediaTime.compact(position))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 42, alignment: .trailing)

                Slider(value: $position, in: 0...max(1, studio.duration)) { editing in
                    scrubbing = editing
                    if !editing { studio.seek(to: position) }
                }
                .help(loc.t("Busca una posición dentro del archivo.",
                            "Seek to a position in the file."))

                Text(MediaTime.compact(studio.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 42, alignment: .leading)
            }
        }
        .onChange(of: playback.currentTime) { _, value in
            if !scrubbing { position = value }
        }
        .onChange(of: studio.sourceURL) { _, _ in position = 0 }
        .task(id: studio.sourceURL) {
            waveform = []
            guard let url = studio.sourceURL, !studio.isVideo else { return }
            waveform = await AudioWaveformLoader.samples(from: url)
        }
    }
}

private struct AudioWaveformView: View {
    let samples: [CGFloat]
    let progress: Double

    var body: some View {
        Canvas { context, size in
            let values = samples.isEmpty ? Self.placeholder : samples
            let spacing: CGFloat = 2
            let width = max(1, (size.width - spacing * CGFloat(values.count - 1)) / CGFloat(values.count))
            let played = min(max(progress, 0), 1) * size.width
            var playedPath = Path()
            var remainingPath = Path()
            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * (width + spacing)
                let height = max(3, value * size.height)
                let centerX = x + width / 2
                let top = (size.height - height) / 2
                let bottom = top + height
                if x <= played {
                    playedPath.move(to: CGPoint(x: centerX, y: top))
                    playedPath.addLine(to: CGPoint(x: centerX, y: bottom))
                } else {
                    remainingPath.move(to: CGPoint(x: centerX, y: top))
                    remainingPath.addLine(to: CGPoint(x: centerX, y: bottom))
                }
            }
            let stroke = StrokeStyle(lineWidth: width, lineCap: .round)
            context.stroke(remainingPath, with: .color(Color.secondary.opacity(0.55)), style: stroke)
            context.stroke(playedPath, with: .color(Color.appAccent), style: stroke)
        }
        .accessibilityHidden(true)
    }

    private static let placeholder: [CGFloat] = {
        (0..<96).map { index in
            let wave = abs(sin(Double(index) * 0.41))
            return CGFloat(0.16 + wave * 0.34)
        }
    }()
}

private enum AudioWaveformLoader {
    static func samples(from url: URL, count: Int = 180) async -> [CGFloat] {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let reader = try? AVAssetReader(asset: asset) else { return [] }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            guard reader.canAdd(output) else { return [] }
            reader.add(output)
            guard reader.startReading() else { return [] }

            let duration = max(0.001, (try? await asset.load(.duration).seconds) ?? 0)
            var peaks = Array(repeating: CGFloat.zero, count: count)
            while reader.status == .reading, let sample = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                guard length >= 2 else { continue }
                var bytes = Data(count: length)
                let copied = bytes.withUnsafeMutableBytes { raw -> OSStatus in
                    guard let base = raw.baseAddress else { return -1 }
                    return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                                      destination: base)
                }
                guard copied == kCMBlockBufferNoErr else { continue }

                let sampleFrames = max(1, CMSampleBufferGetNumSamples(sample))
                let format = CMSampleBufferGetFormatDescription(sample)
                    .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
                let channels = max(1, Int(format?.mChannelsPerFrame ?? 1))
                let sampleRate = max(1, format?.mSampleRate ?? 44_100)
                let startTime = max(0, CMSampleBufferGetPresentationTimeStamp(sample).seconds)

                bytes.withUnsafeBytes { raw in
                    let values = raw.bindMemory(to: Int16.self)
                    let availableFrames = min(sampleFrames, values.count / channels)
                    let groupFrames = max(1, availableFrames / 512)
                    var frame = 0
                    while frame < availableFrames {
                        var maximum: Int16 = 0
                        let endFrame = min(availableFrames, frame + groupFrames)
                        for currentFrame in frame..<endFrame {
                            let firstValue = currentFrame * channels
                            for channel in 0..<channels {
                                let sampleValue = values[firstValue + channel]
                                let magnitude = sampleValue == .min ? Int16.max : abs(sampleValue)
                                maximum = max(maximum, magnitude)
                            }
                        }
                        let time = startTime + Double(frame) / sampleRate
                        let bucket = min(count - 1, max(0, Int(time / duration * Double(count))))
                        peaks[bucket] = max(peaks[bucket], CGFloat(maximum) / CGFloat(Int16.max))
                        frame = endFrame
                    }
                }
            }
            let maximum = peaks.max() ?? 0
            guard maximum > 0 else { return [] }
            return peaks.map { max(0.05, $0 / maximum) }
        }.value
    }
}
