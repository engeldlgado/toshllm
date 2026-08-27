// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct SubtitleCueEditorRow: View {
    @ObservedObject var studio: AudioStudioController
    let original: SubtitleCue
    let translated: SubtitleCue?
    let mode: AudioTranscriptMode
    let editing: Bool
    let isCurrent: Bool
    @EnvironmentObject private var loc: Localizer
    @State private var originalDraft: String
    @State private var translatedDraft: String

    init(studio: AudioStudioController, original: SubtitleCue, translated: SubtitleCue?,
         mode: AudioTranscriptMode, editing: Bool, isCurrent: Bool) {
        self.studio = studio
        self.original = original
        self.translated = translated
        self.mode = mode
        self.editing = editing
        self.isCurrent = isCurrent
        _originalDraft = State(initialValue: original.text)
        _translatedDraft = State(initialValue: translated?.text ?? "")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(MediaTime.compact(original.start)) {
                studio.seek(to: original.start)
            }
            .buttonStyle(.borderless)
            .font(.caption.monospacedDigit())
            .help(loc.t("Reproducir desde este subtítulo.", "Play from this subtitle."))

            VStack(alignment: .leading, spacing: 6) {
                if mode != .translated {
                    cueText(originalDraft, translated: false, label: loc.t("Original", "Original"))
                }
                if mode != .original, translated != nil {
                    cueText(translatedDraft, translated: true, label: loc.t("Traducción", "Translation"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if editing {
                Menu(loc.t("Editar segmento", "Edit segment"), systemImage: "ellipsis.circle") {
                    Button(loc.t("Dividir", "Split"), systemImage: "rectangle.split.2x1",
                           action: { studio.splitCue(id: original.id) })
                    Button(loc.t("Unir con el siguiente", "Merge with next"),
                           systemImage: "rectangle.2.swap",
                           action: { studio.mergeCueWithNext(id: original.id) })
                    Divider()
                    Button(loc.t("Eliminar", "Delete"), systemImage: "trash", role: .destructive,
                           action: { studio.deleteCue(id: original.id) })
                }
                .menuStyle(.borderlessButton)
                .help(loc.t("Divide, une o elimina este segmento.",
                            "Splits, merges, or deletes this segment."))
            } else {
                Text("#\(original.id)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(isCurrent ? Color.appAccent.opacity(0.14) : Color.clear)
        .overlay(alignment: .leading) {
            if isCurrent {
                Capsule()
                    .fill(Color.appAccent)
                    .frame(width: 3)
                    .padding(.vertical, 5)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .onChange(of: original.text) { _, value in originalDraft = value }
        .onChange(of: translated?.text) { _, value in translatedDraft = value ?? "" }
    }

    @ViewBuilder
    private func cueText(_ text: String, translated: Bool, label: String) -> some View {
        if editing {
            TextField(label, text: translated ? $translatedDraft : $originalDraft, axis: .vertical)
                .lineLimit(1...5)
                .onSubmit {
                    studio.updateCue(id: original.id,
                                     text: translated ? translatedDraft : originalDraft,
                                     translated: translated)
                }
                .help(loc.t("Edita el texto y pulsa Retorno para guardarlo.",
                            "Edit the text and press Return to save it."))
        } else {
            if mode == .bilingual {
                Text(label.uppercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .textSelection(.enabled)
        }
    }
}
