// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Keep telemetry observation out of the server configuration and model catalog.
struct DashboardMetricsView: View {
    @EnvironmentObject private var server: ServerController
    @EnvironmentObject private var vram: VRAMMonitor
    @EnvironmentObject private var loc: Localizer
    @State private var gpuHistory: [Double] = []

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                metricCards
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                metricCards
            }
        }
        .onAppear { record(vram.sample) }
        .onChange(of: vram.sample) { _, sample in record(sample) }
    }

    @ViewBuilder private var metricCards: some View {
        let activity = vram.activityPercent
        DashboardMetric(title: "GPU", icon: "cpu",
                        value: activity.map { String(format: "%.0f%%", $0) } ?? "—",
                        detail: activity == nil
                            ? loc.t("El controlador no reporta actividad", "Activity unavailable from driver")
                            : (vram.gpus.first?.name ?? "GPU"),
                        history: gpuHistory)
            .frame(minWidth: 150)
        DashboardMetric(title: "VRAM", icon: "memorychip",
                        value: vram.gpus.isEmpty ? "—" : String(format: "%.1f / %.0f GB", vram.usedMB / 1024, vram.totalMB / 1024),
                        detail: loc.t("Uso real · capacidad de GPU", "Live usage · GPU capacity"),
                        progress: vram.fraction)
            .frame(minWidth: 150)
        DashboardMetric(title: loc.t("Memoria", "Memory"), icon: "internaldrive",
                        value: String(format: "%.1f / %.0f GB", vram.memoryUsedMB / 1024,
                                      vram.memoryTotalMB / 1024),
                        detail: loc.t("RAM activa · instalada", "Active RAM · installed"),
                        progress: vram.memoryFraction, tint: .chartSecondary)
            .frame(minWidth: 150)
        DashboardMetric(title: loc.t("Rendimiento", "Throughput"), icon: "waveform.path.ecg",
                        value: server.genSpeed.map { String(format: "%.1f tok/s", $0) } ?? "—",
                        detail: loc.t("Generación de la última petición", "Latest request generation speed"),
                        history: Array(server.genHistory.suffix(28)), tint: .chartSecondary)
            .frame(minWidth: 150)
        DashboardMetric(title: "Mac", icon: "desktopcomputer",
                        value: hardware.model.components(separatedBy: " (").first ?? hardware.model,
                        detail: "\(hardware.osVersion)\n" + (ServerSettings.isAppleSilicon
                            ? "Metal · Apple Silicon"
                            : loc.t("Metal · build AMD parcheado", "Metal · patched AMD build")))
            .frame(minWidth: 150)
    }

    private func record(_ sample: SystemTelemetrySample) {
        guard let value = sample.gpus.compactMap(\.activityPercent).max() else { return }
        gpuHistory.append(value)
        if gpuHistory.count > 28 { gpuHistory.removeFirst(gpuHistory.count - 28) }
    }
}
