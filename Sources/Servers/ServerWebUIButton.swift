// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

struct ServerWebUIButton: View {
    enum Presentation {
        case labeled
        case icon
    }

    @ObservedObject var server: ServerController
    var presentation: Presentation = .labeled
    @EnvironmentObject private var loc: Localizer

    var body: some View {
        Button {
            NSWorkspace.shared.open(server.webChatURL)
        } label: {
            if presentation == .icon {
                Image(systemName: "safari")
            } else {
                Label("WebUI", systemImage: "safari")
            }
        }
        .disabled(server.state != .running)
        .opacity(server.state == .running ? 1 : 0.48)
        .help(server.state == .running
              ? loc.t("Abrir la WebUI de este servidor", "Open this server's WebUI")
              : loc.t("Inicia este servidor para abrir su WebUI", "Start this server to open its WebUI"))
        .accessibilityLabel(loc.t("Abrir WebUI", "Open WebUI"))
    }
}
