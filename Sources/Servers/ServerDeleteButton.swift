// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// One deletion flow for server cards and sidebar rows.
struct ServerDeleteButton: View {
    enum Presentation { case icon, labeled }

    let presentation: Presentation
    let action: () -> Void
    @EnvironmentObject private var loc: Localizer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirming = false
    @State private var hovering = false

    var body: some View {
        Group {
            if presentation == .icon {
                deleteButton.buttonStyle(.plain)
            } else {
                deleteButton.glassButton()
            }
        }
        .foregroundStyle(presentation == .icon
                         ? (hovering ? Color.red : Color.secondary.opacity(0.65))
                         : Color.secondary)
        .fixedSize()
        .iconHelp(loc.t("Eliminar este servidor", "Delete this server"))
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .confirmationDialog(
            loc.t("¿Eliminar este servidor?", "Delete this server?"),
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button(loc.t("Eliminar servidor", "Delete server"), role: .destructive, action: action)
            Button(loc.t("Cancelar", "Cancel"), role: .cancel) {}
        } message: {
            Text(loc.t("El servidor se detendrá y se eliminará su configuración. Los modelos descargados se conservarán.",
                       "The server will stop and its configuration will be removed. Downloaded models will be kept."))
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) { confirming = true } label: {
            if presentation == .labeled {
                Label(loc.t("Eliminar servidor", "Delete server"), systemImage: "trash")
            } else {
                Image(systemName: "trash")
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 24, height: 24)
                    .background(hovering ? Color.red.opacity(0.10) : .clear, in: Circle())
            }
        }
    }
}
