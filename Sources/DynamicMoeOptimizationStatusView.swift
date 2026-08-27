// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct DynamicMoeOptimizationStatusView: View {
    @EnvironmentObject private var loc: Localizer

    let running: Bool
    let status: DynamicMoeOptimizationState
    let profile: DynamicMoeOptimizationProfile?
    let samples: [DynamicMoeOptimizationSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(status.localized(using: loc))
            } icon: {
                Image(systemName: running ? "gearshape.2.fill" : "checkmark.circle.fill")
            }
            .font(.callout)
            .foregroundStyle(running ? Color.appAccent : .green)

            if let profile {
                LabeledContent(loc.t("Ruta seleccionada", "Selected route")) {
                    Text(profile.route == .direct
                         ? loc.t("Directa · K\(profile.slots)", "Direct · K\(profile.slots)")
                         : loc.t("Dividida · K\(profile.slots) + ring\(profile.ringSlots)",
                                 "Split · K\(profile.slots) + ring\(profile.ringSlots)"))
                        .monospacedDigit()
                }
                LabeledContent(loc.t("Rendimiento", "Performance")) {
                    Text("PP \(profile.promptTokensPerSecond, format: .number.precision(.fractionLength(1))) · TG \(profile.generationTokensPerSecond, format: .number.precision(.fractionLength(2))) t/s")
                        .monospacedDigit()
                }
                Label(loc.t("El perfil quedó activado para el chat.", "The profile is now active for chat."),
                      systemImage: "text.bubble.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !samples.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(samples) { sample in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(routeName(sample.route)) K\(sample.slots) · P\(sample.prefetch)")
                                    .bold()
                                Text("PP \(sample.pp, format: .number.precision(.fractionLength(1)))")
                                Text("TG \(sample.tg, format: .number.precision(.fractionLength(2)))")
                                if let vram = sample.estimatedVRAMFraction {
                                    Text(vram, format: .percent.precision(.fractionLength(0)))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption.monospacedDigit())
                            .padding(8)
                            .background(.quaternary, in: .rect(cornerRadius: 8))
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func routeName(_ route: DynamicMoeExecutionRoute) -> String {
        route == .direct ? loc.t("directa", "direct") : loc.t("dividida", "split")
    }
}
