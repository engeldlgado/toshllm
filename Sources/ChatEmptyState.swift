// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

enum ChatStarterAction: Hashable {
    case ask, code, files, summarize, explore
}

/// Native empty state for a conversation with quick actions that preserve the
/// existing chat workflows without building a second card-based navigation UI.
struct ChatEmptyState: View {
    @EnvironmentObject private var loc: Localizer
    let onAction: (ChatStarterAction) -> Void

    var body: some View {
        ContentUnavailableView {
            Label(loc.t("¿En qué puedo ayudarte?", "What can I help with?"),
                  systemImage: "bubble.left.and.text.bubble.right")
        } description: {
            Text(loc.t("Todo se ejecuta en tu GPU, sin salir de tu equipo. Adjunta código, texto o PDF para preguntar sobre ellos.",
                       "Everything runs on your GPU, never leaving your machine. Attach code, text or PDF files to ask about them."))
        } actions: {
            HStack {
                Button(loc.t("Preguntar", "Ask"), systemImage: "bubble.left",
                       action: { onAction(.ask) })
                    .buttonStyle(.borderedProminent)
                Button(loc.t("Adjuntar archivo", "Attach file"), systemImage: "paperclip",
                       action: { onAction(.files) })
                Menu(loc.t("Sugerencias", "Suggestions"), systemImage: "sparkles") {
                    Button(loc.t("Escribir código", "Write code"),
                           systemImage: "chevron.left.forwardslash.chevron.right",
                           action: { onAction(.code) })
                    Button(loc.t("Resumir", "Summarize"), systemImage: "text.alignleft",
                           action: { onAction(.summarize) })
                    Divider()
                    Button(loc.t("Más opciones", "More options"), systemImage: "ellipsis.circle",
                           action: { onAction(.explore) })
                }
            }
        }
        .frame(maxWidth: 760)
    }
}
