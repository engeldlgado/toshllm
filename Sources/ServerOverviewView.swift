// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct ServerOverviewView: View {
    @ObservedObject var server: ServerController
    let configure: () -> Void
    var onDelete: (() -> Void)?
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var vram: VRAMMonitor
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""
    @AppStorage(SettingsKeys.ctx) private var context = 16384
    @AppStorage(SettingsKeys.port) private var port = 8080
    @AppStorage(SettingsKeys.localNetworkDiscovery) private var discovery = false

    var body: some View {
        let settings = server.effectiveSettings()
        let path = server.profile == nil ? modelPath : settings.modelPath
        let name = ModelName.forPath(path)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(server.state == .running
                     ? loc.t("SERVIDOR ACTIVO", "ACTIVE SERVER")
                     : (server.profile == nil ? loc.t("SERVIDOR PRINCIPAL", "PRIMARY SERVER") : loc.t("SERVIDOR", "SERVER")))
                    .font(.system(size: 10, weight: .semibold)).tracking(1.7)
                    .foregroundStyle(server.state == .running ? .green : .secondary)
                Spacer()
                ServerStateBadge(state: server.state)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) {
                    identity(name, path: path, router: settings.routerMode)
                    Spacer(minLength: 10)
                    connection(settings)
                }
                VStack(alignment: .leading, spacing: 16) {
                    identity(name, path: path, router: settings.routerMode)
                    connection(settings)
                }
            }
            Divider()
            HStack(spacing: 30) {
                metric("bolt.fill", value: server.genSpeed.map { String(format: "%.1f tok/s", $0) } ?? "—", label: loc.t("Última generación", "Last generation"))
                Spacer(minLength: 0)
                metric("text.bubble", value: "\(server.requestCount)", label: loc.t("Peticiones", "Requests"))
                Spacer(minLength: 0)
                metric("square.stack.3d.up", value: name.quant.isEmpty ? "—" : name.quant, label: loc.t("Cuantización", "Quantization"))
                Spacer(minLength: 0)
                metric("cpu", value: ServerSettings.engineKind == "bundled" ? "llama.cpp" : loc.t("Personalizado", "Custom"), label: loc.t("Motor configurado", "Configured engine"))
            }
            Divider()
            HStack(spacing: 22) {
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
                .frame(maxWidth: 480)
                Spacer(minLength: 0)
                GlassActionGroup {
                    if let onDelete {
                        ServerDeleteButton(presentation: .labeled, action: onDelete)
                    }
                    Button(action: configure) {
                        Label(loc.t("Configurar", "Configure"), systemImage: "slider.horizontal.3")
                    }
                    .glassButton().controlSize(.large)
                    if server.state == .running || server.state == .starting {
                        Button { server.stop() } label: {
                            Label(loc.t("Detener servidor", "Stop server"), systemImage: "stop.circle")
                        }
                        .glassButton(prominent: true).controlSize(.large)
                    } else {
                        Button { server.start(server.effectiveSettings()) } label: {
                            Label(loc.t("Iniciar servidor", "Start server"), systemImage: "play.fill")
                        }
                        .glassButton(prominent: true).controlSize(.large)
                        .disabled(settings.routerMode ? models.models.isEmpty : path.isEmpty)
                    }
                }
            }
        }
        .padding(18)
        .cardSurface()
    }

    private func identity(_ name: ModelName, path: String, router: Bool) -> some View {
        HStack(spacing: 14) {
            ModelBrandIcon(name: path, size: 46)
            VStack(alignment: .leading, spacing: 6) {
                if router {
                    Text(loc.t("Router de modelos", "Model router"))
                        .font(.system(size: 19, weight: .semibold))
                } else {
                    ServerModelPicker(server: server, prominent: true)
                        .frame(maxWidth: 360, alignment: .leading)
                }
                Text(path.isEmpty ? loc.t("Configura el servidor para empezar", "Configure your server to get started") : ([name.quant] + name.badges).filter { !$0.isEmpty }.joined(separator: "  ·  "))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    private func connection(_ settings: ServerSettings) -> some View {
        HStack(spacing: 18) {
            Label(String(server.profile == nil ? port : settings.port), systemImage: "network")
            Divider().frame(height: 24)
            Text("\((server.profile == nil ? context : settings.ctx) / 1024)k " + loc.t("contexto", "context"))
            Divider().frame(height: 24)
            Label((server.profile == nil ? discovery : settings.localNetworkDiscovery) ? loc.t("Red local", "Local network") : loc.t("Solo este Mac", "This Mac only"), systemImage: "wifi")
        }
        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
    }

    private func metric(_ icon: String, value: String, label: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}
