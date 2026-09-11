// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Per-model MTP policy. The engine still chooses the embedded head or matching
/// assistant automatically; this control decides whether that acceleration is allowed.
struct MTPControl: View {
    let modelPath: String
    @EnvironmentObject private var loc: Localizer
    @State private var enabled = true

    var body: some View {
        ToshDropdown(selection: $enabled, options: [
            .init(value: true, title: loc.t("Automático", "Automatic"),
                  subtitle: ServerSettings.modelHasMTP(at: modelPath)
                    ? loc.t("Cabezal MTP integrado", "Embedded MTP head")
                    : loc.t("Borrador MTP externo", "External MTP draft"), systemImage: "hare.fill"),
            .init(value: false, title: loc.t("Desactivado", "Disabled"),
                  subtitle: loc.t("Generación de un token por paso", "One-token decoding"), systemImage: "hare")
        ], width: 220, listWidth: 300)
        .onAppear { enabled = ServerSettings.mtpEnabled(forModel: modelPath) }
        .onChange(of: enabled) { _, value in ServerSettings.setMTPEnabled(value, forModel: modelPath) }
    }
}
