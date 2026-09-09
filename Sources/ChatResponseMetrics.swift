// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Compact readout beside the most recent response. It reads only immutable
/// message data, so completed transcripts do not subscribe to streaming state.
struct ChatResponseMetrics: View, Equatable {
    let message: ChatMessage

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.message == rhs.message }

    private var speed: Double? {
        message.genSpeed ?? message.timings?.generationTokensPerSecond
    }

    private var duration: String? {
        guard let milliseconds = message.timings?.generationMilliseconds else { return nil }
        return String(format: "%.1f s", milliseconds / 1_000)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let speed {
                metric(String(format: "%.1f tokens/s", speed), icon: "bolt.fill")
            }
            if let accept = message.mtpAccept {
                metric("MTP \(Int((accept * 100).rounded()))%", icon: "arrow.triangle.2.circlepath")
            }
            if let tokens = message.timings?.generatedTokens {
                metric(tokens.formatted() + " tokens", icon: "text.word.spacing")
            }
            if let duration {
                metric(duration, icon: "timer")
            }
            if let model = message.model, !model.isEmpty {
                Divider()
                Text(model)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(14)
        .frame(width: 154, alignment: .leading)
        .background(WorkspaceStyle.surface,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(WorkspaceStyle.border))
    }

    private func metric(_ value: String, icon: String) -> some View {
        Label(value, systemImage: icon)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
    }
}
