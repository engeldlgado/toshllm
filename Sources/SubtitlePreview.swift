// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct SubtitlePreview: View {
    @ObservedObject var studio: AudioStudioController
    @Binding var followPlayback: Bool
    let editing: Bool
    @EnvironmentObject private var loc: Localizer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var replacement = ""

    var body: some View {
        Group {
            if studio.cues.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: emptyIcon)
                } description: {
                    Text(emptyDescription)
                }
            } else {
                VStack(spacing: 0) {
                    if editing {
                        SubtitleEditorToolbar(studio: studio, searchText: $searchText,
                                              replacement: $replacement)
                        Divider()
                    }
                    transcriptList
                }
            }
        }
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleCues) { cue in
                        let pair = studio.cuePair(id: cue.id)
                        SubtitleCueEditorRow(
                            studio: studio, original: pair.original ?? cue,
                            translated: pair.translated, mode: studio.transcriptMode,
                            editing: editing, isCurrent: cue.id == studio.currentCueID
                        )
                        .id(cue.id)
                        Divider()
                    }
                }
            }
            .onChange(of: studio.currentCueID) { _, cueID in
                guard studio.isPlaying, followPlayback, let cueID else { return }
                if reduceMotion {
                    proxy.scrollTo(cueID, anchor: .center)
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(cueID, anchor: .center)
                    }
                }
            }
        }
    }

    private var visibleCues: [SubtitleCue] {
        guard !searchText.isEmpty else { return studio.cues }
        return studio.cues.filter { cue in
            let pair = studio.cuePair(id: cue.id)
            return pair.original?.text.localizedStandardContains(searchText) == true
                || pair.translated?.text.localizedStandardContains(searchText) == true
        }
    }

    private var emptyTitle: String {
        studio.isBusy ? loc.t("Procesando", "Processing") : loc.t("Sin subtítulos todavía", "No subtitles yet")
    }

    private var emptyIcon: String {
        studio.isBusy ? "waveform.badge.magnifyingglass" : "captions.bubble"
    }

    private var emptyDescription: String {
        studio.isBusy
            ? loc.t("Los segmentos aparecerán cuando Whisper termine.",
                    "Segments will appear when Whisper finishes.")
            : loc.t("Configura el resultado y pulsa Crear subtítulos.",
                    "Configure the result and press Create subtitles.")
    }
}
