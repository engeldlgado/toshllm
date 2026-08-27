// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct AudioVADCustomControls: View {
    @EnvironmentObject private var loc: Localizer

    @Binding var threshold: Double
    @Binding var minSpeechMS: Double
    @Binding var minSilenceMS: Double
    @Binding var maxSpeechSeconds: Double
    @Binding var speechPadMS: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(loc.t("Confianza de voz", "Speech confidence")) {
                HStack {
                    Slider(value: $threshold, in: 0.1...0.95, step: 0.05)
                    Text(threshold, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
            }
            .help(loc.t("Un valor alto descarta más voces débiles; también puede perder una voz principal suave.",
                        "A high value rejects more weak voices; it can also miss a quiet main voice."))

            LabeledContent(loc.t("Voz mínima", "Minimum speech")) {
                HStack {
                    Slider(value: $minSpeechMS, in: 100...2_000, step: 50)
                    Text(minSpeechMS / 1_000,
                         format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
            }
            .help(loc.t("Descarta intervenciones más breves que esta duración, expresada en segundos.",
                        "Rejects speech shorter than this duration, shown in seconds."))

            LabeledContent(loc.t("Silencio para cortar", "Silence to split")) {
                HStack {
                    Slider(value: $minSilenceMS, in: 50...2_000, step: 50)
                    Text(minSilenceMS / 1_000,
                         format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
            }
            .help(loc.t("Divide un tramo cuando el silencio alcanza esta duración, expresada en segundos.",
                        "Splits a segment when silence reaches this duration, shown in seconds."))

            LabeledContent(loc.t("Tramo máximo", "Maximum segment")) {
                HStack {
                    Slider(value: $maxSpeechSeconds, in: 10...120, step: 5)
                    Text(maxSpeechSeconds, format: .number)
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
            }
            .help(loc.t("Fuerza cortes periódicos para impedir que una frase alimente segmentos demasiado largos.",
                        "Forces periodic splits so one phrase cannot feed excessively long segments."))

            LabeledContent(loc.t("Margen de palabra", "Word padding")) {
                HStack {
                    Slider(value: $speechPadMS, in: 0...500, step: 20)
                    Text(speechPadMS / 1_000,
                         format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
            }
            .help(loc.t("Conserva un pequeño margen alrededor de cada voz para no cortar palabras.",
                        "Keeps a small margin around speech so words are not clipped."))

            Button(loc.t("Restablecer ajustes", "Reset settings"),
                   systemImage: "arrow.counterclockwise", action: resetValues)
                .controlSize(.small)
                .help(loc.t("Restaura los valores personalizados al perfil Equilibrado.",
                            "Restores custom values to the Balanced profile."))
        }
    }

    private func resetValues() {
        let defaults = AudioVADProfile.balanced.calibration
        threshold = defaults.threshold
        minSpeechMS = Double(defaults.minSpeechDurationMS)
        minSilenceMS = Double(defaults.minSilenceDurationMS)
        maxSpeechSeconds = defaults.maxSpeechDurationSeconds
        speechPadMS = Double(defaults.speechPadMS)
    }
}
