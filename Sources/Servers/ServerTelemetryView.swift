// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct ServerTelemetryView: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var vram: VRAMMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let activity = vram.activityPercent {
                HStack {
                    Text(loc.t("Actividad GPU", "GPU activity"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f%%", activity))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                }
                ProgressView(value: min(max(activity / 100, 0), 1)).tint(.green)
                    .help(loc.t("Actividad total de la GPU seleccionada; incluye otras aplicaciones.",
                                "Total activity on the selected GPU, including other apps."))
            }
            HStack {
                Text("VRAM").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text(vram.gpus.isEmpty ? "—" : String(format: "%.1f / %.0f GB", vram.usedMB / 1024, vram.totalMB / 1024))
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }
            ProgressView(value: vram.fraction).tint(Color.appAccent)
        }
    }
}
