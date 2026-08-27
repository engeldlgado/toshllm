// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct SubtitleEditorToolbar: View {
    @ObservedObject var studio: AudioStudioController
    @Binding var searchText: String
    @Binding var replacement: String
    @EnvironmentObject private var loc: Localizer

    var body: some View {
        HStack(spacing: 8) {
            TextField(loc.t("Buscar", "Find"), text: $searchText)
                .help(loc.t("Filtra los segmentos por texto.", "Filters segments by text."))
            TextField(loc.t("Reemplazar con", "Replace with"), text: $replacement)
                .help(loc.t("Texto que sustituirá todas las coincidencias.",
                            "Text that will replace all matches."))
            Button(loc.t("Reemplazar todo", "Replace all"), systemImage: "text.badge.checkmark") {
                studio.replaceAll(searchText, with: replacement)
            }
            .disabled(searchText.isEmpty)
            .help(loc.t("Reemplaza coincidencias en original y traducción.",
                        "Replaces matches in both the original and translation."))
            Button(loc.t("Deshacer", "Undo"), systemImage: "arrow.uturn.backward",
                   action: studio.undoEdit)
                .labelStyle(.iconOnly)
                .disabled(!studio.canUndoEdit)
                .help(loc.t("Deshace la última edición de subtítulos.",
                            "Undoes the last subtitle edit."))
            Button(loc.t("Rehacer", "Redo"), systemImage: "arrow.uturn.forward",
                   action: studio.redoEdit)
                .labelStyle(.iconOnly)
                .disabled(!studio.canRedoEdit)
                .help(loc.t("Rehace la última edición deshecha.",
                            "Redoes the last undone edit."))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
