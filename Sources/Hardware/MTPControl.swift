// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Per-model MTP policy. The engine still chooses the embedded head or matching
/// assistant automatically; this control decides whether that acceleration is allowed.
/// `inline` is one compact row; `settings` is a form section.
struct MTPControl: View {
    enum Layout { case inline, settings, detail }

    let modelPath: String
    var layout: Layout = .detail
    @EnvironmentObject private var loc: Localizer
    @State private var enabled = true

    private var sourceText: String {
        ServerSettings.modelHasMTP(at: modelPath)
            ? loc.t("Cabezal MTP integrado", "Embedded MTP head")
            : loc.t("Borrador MTP externo", "External MTP draft")
    }

    private var helpText: String {
        loc.t("Automático predice varios tokens por paso con el cabezal del modelo. Con textos que acepta poco puede generar más lento que sin él; Desactivado genera un token por paso. Se aplica al reiniciar el servidor.",
              "Automatic predicts several tokens per step with the model's head. On text it accepts rarely it can generate slower than without it; Disabled generates one token per step. Applies when the server restarts.")
    }

    @ViewBuilder
    var body: some View {
        Group {
            switch layout {
            case .detail: detailRow
            case .settings: settingsRow
            case .inline: inlineRow
            }
        }
        .onAppear { enabled = ServerSettings.mtpEnabled(forModel: modelPath) }
        .onChange(of: enabled) { _, value in ServerSettings.setMTPEnabled(value, forModel: modelPath) }
    }

    private var detailRow: some View {
        ToshDropdown(selection: $enabled, options: [
            .init(value: true, title: loc.t("Automático", "Automatic"),
                  subtitle: sourceText, systemImage: "hare.fill"),
            .init(value: false, title: loc.t("Desactivado", "Disabled"),
                  subtitle: loc.t("Generación de un token por paso", "One-token decoding"), systemImage: "hare")
        ], width: 220, listWidth: 300)
        .help(helpText)
    }

    private var settingsRow: some View {
        LabeledContent(loc.t("Predicción", "Prediction")) {
            Picker(loc.t("Predicción", "Prediction"), selection: $enabled) {
                Text(loc.t("Desactivado", "Disabled")).tag(false)
                Text(loc.t("Automático", "Automatic")).tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        .help(helpText)
    }

    private var inlineRow: some View {
        Picker("MTP", selection: $enabled) {
            Text(loc.t("Off", "Off")).tag(false)
            Text(loc.t("Auto", "Auto")).tag(true)
        }
        .labelsHidden()
        .fixedSize()
        .font(.caption)
        .help(helpText)
    }
}
