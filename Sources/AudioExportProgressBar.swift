// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct AudioExportProgressBar: View {
    @ObservedObject var exporter: SubtitleVideoExporter
    @EnvironmentObject private var loc: Localizer

    var body: some View {
        HStack(spacing: 10) {
            Label(loc.t("Creando vídeo subtitulado…", "Creating captioned video…"),
                  systemImage: "film.stack")
                .font(.caption)
            ProgressView(value: exporter.progress)
            Text(exporter.progress, format: .percent.precision(.fractionLength(0)))
                .font(.caption.monospacedDigit())
                .frame(minWidth: 38, alignment: .trailing)
            Button(loc.t("Cancelar exportación", "Cancel export"),
                   systemImage: "xmark", action: exporter.cancel)
                .labelStyle(.iconOnly)
                .help(loc.t("Cancela la creación del vídeo subtitulado.",
                            "Cancels captioned video creation."))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
