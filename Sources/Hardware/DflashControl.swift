// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Per-model DFlash policy, shown only when a compatible downloaded draft exists.
/// `inline` is one compact row; `settings` is a form section.
struct DflashControl: View {
    enum Layout { case inline, settings, detail }

    let modelPath: String
    var switchLeading: Bool = false
    var layout: Layout = .inline
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var server: ServerController
    @State private var mode: DflashMode = .auto
    @State private var glow = false

    private var active: Bool { server.activeDflashModelPath == modelPath }

    @ViewBuilder
    var body: some View {
        if layout == .settings { settingsRows }
        else if layout == .detail { detailRow }
        else { inlineRow }
    }

    private var detailRow: some View {
        ToshDropdown(selection: $mode, options: [
            .init(value: .off, title: loc.t("Apagado", "Off"), systemImage: "bolt.slash"),
            .init(value: .auto, title: "Auto", subtitle: loc.t("Respeta la reserva de VRAM", "Respects the VRAM reserve"), systemImage: "wand.and.stars"),
            .init(value: .forced, title: loc.t("Forzado", "Forced"), subtitle: loc.t("Ignora la reserva de seguridad", "Ignores the safety reserve"), systemImage: "bolt.fill")
        ], width: 220, listWidth: 300)
        .onAppear { mode = ServerSettings.dflashMode(forModel: modelPath) }
        .onChange(of: mode) { _, value in ServerSettings.setDflashMode(value, forModel: modelPath) }
    }

    private var settingsRows: some View {
        Group {
            LabeledContent(loc.t("Borrador", "Draft")) {
                Picker(loc.t("Borrador", "Draft"), selection: $mode) {
                    Text(loc.t("Apagado", "Off")).tag(DflashMode.off)
                    Text("Auto").tag(DflashMode.auto)
                    Text(loc.t("Forzado", "Forced")).tag(DflashMode.forced)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if active, let acc = server.dflashAcceptance {
                LabeledContent(loc.t("Aceptación", "Acceptance")) {
                    Text(acc.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                }
            }
        }
        .onAppear { mode = ServerSettings.dflashMode(forModel: modelPath) }
        .onChange(of: mode) { _, value in ServerSettings.setDflashMode(value, forModel: modelPath) }
        .help(loc.t("Auto usa DFlash cuando hay un draft compatible y el planificador deja memoria suficiente. Forzado ignora la reserva de seguridad y avisa si la VRAM supera 95 %.",
                    "Auto uses DFlash when a compatible draft is installed and the memory planner leaves enough headroom. Forced ignores the safety reserve and warns if VRAM exceeds 95%."))
    }

    private var inlineRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(active ? .orange : (mode == .off ? Color.secondary : Color.orange.opacity(0.6)))
                .shadow(color: active ? .orange.opacity(glow ? 0.9 : 0.25) : .clear, radius: active ? (glow ? 6 : 2) : 0)
            Text("DFlash")
                .foregroundStyle(active ? .orange : (mode == .off ? Color.secondary : .primary))
                .fixedSize()
            if active, let acc = server.dflashAcceptance {
                Text(acc.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit().foregroundStyle(.secondary)
                    .help(loc.t("Aceptación del borrador en la última respuesta",
                                "Draft acceptance on the last response"))
            }
            Picker("DFlash", selection: $mode) {
                Text(loc.t("Off", "Off")).tag(DflashMode.off)
                Text(loc.t("Auto", "Auto")).tag(DflashMode.auto)
                Text(loc.t("Forzado", "Forced")).tag(DflashMode.forced)
            }
            .labelsHidden()
            .fixedSize()
        }
        .font(.caption)
        .onAppear {
            mode = ServerSettings.dflashMode(forModel: modelPath)
            glow = active
        }
        .onChange(of: mode) { _, value in ServerSettings.setDflashMode(value, forModel: modelPath) }
        .onChange(of: active) { _, on in
            withAnimation(on ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default) { glow = on }
        }
        .help(loc.t("Auto usa DFlash cuando hay un draft compatible y el planificador deja memoria suficiente. Forzado ignora la reserva de seguridad y avisa si la VRAM supera 95 %.",
                    "Auto uses DFlash when a compatible draft is installed and the memory planner leaves enough headroom. Forced ignores the safety reserve and warns if VRAM exceeds 95%."))
    }
}
