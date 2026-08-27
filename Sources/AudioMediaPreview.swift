// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import AVKit
import SwiftUI

struct AudioMediaPreview: View {
    @ObservedObject var studio: AudioStudioController
    @EnvironmentObject private var loc: Localizer
    @State private var position = 0.0
    @State private var scrubbing = false

    var body: some View {
        VStack(spacing: 12) {
            if studio.isVideo, let player = studio.player {
                VideoPlayer(player: player)
                    .frame(minHeight: 180, idealHeight: 240, maxHeight: 320)
                    .clipShape(.rect(cornerRadius: 10))
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 56))
                        .foregroundStyle(Color.appAccent)
                        .accessibilityHidden(true)
                    Text(studio.sourceURL?.lastPathComponent ?? "")
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
            }

            HStack(spacing: 10) {
                Button(studio.isPlaying ? loc.t("Pausar", "Pause") : loc.t("Reproducir", "Play"),
                       systemImage: studio.isPlaying ? "pause.fill" : "play.fill",
                       action: studio.togglePlayback)
                    .labelStyle(.iconOnly)
                    .help(studio.isPlaying ? loc.t("Pausar la previsualización", "Pause preview")
                                           : loc.t("Reproducir el archivo", "Play the file"))

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
        .onChange(of: studio.currentTime) { _, value in
            if !scrubbing { position = value }
        }
        .onChange(of: studio.sourceURL) { _, _ in position = 0 }
    }
}
