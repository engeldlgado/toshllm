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
                ServerStateBadge(state: server.state, phase: server.startupPhase, since: server.startupPhaseSince)
            }
            ToshAdaptive(minWidth: 700) {
                HStack(spacing: 24) {
                    identity(name, path: path, router: settings.routerMode)
                    Spacer(minLength: 10)
                    connection(settings)
                }
            } narrow: {
                VStack(alignment: .leading, spacing: 16) {
                    identity(name, path: path, router: settings.routerMode)
                    connection(settings)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
            if let plan = server.autoPlan {
                VStack(alignment: .leading, spacing: 4) {
                    Label(AutoMemoryText.summary(plan, runtime: server.autoRuntime), systemImage: "memorychip")
                        .font(.callout)
                        .help(loc.t("Por qué este modo: %@", "Why this mode: %@", AutoMemoryText.reason(plan)))
                    if let note = server.autoPlanNote {
                        Label(note, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    // the plan was made for the memory free at launch; an app opened later can take it back
                    if server.state == .running, vram.totalMB > 0,
                       vram.freeMB < 256 || vram.memoryUsedMB > 0.95*vram.memoryTotalMB {
                        HStack(spacing: 8) {
                            Label(loc.t("Otra aplicación está usando la memoria que reservó el plan; el rendimiento puede caer.",
                                        "Another app is using the memory the plan set aside; performance may drop."),
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                            Button(loc.t("Replanificar", "Replan")) {
                                server.stop()
                                Task {
                                    for _ in 0..<40 where server.state != .stopped {
                                        try? await Task.sleep(for: .milliseconds(250))
                                    }
                                    server.start(server.effectiveSettings())
                                }
                            }
                            .controlSize(.small)
                            .help(loc.t("Reinicia el servidor y vuelve a repartir la memoria que hay libre ahora.",
                                        "Restarts the server and budgets the memory free now."))
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 22) {
                ServerTelemetryView()
                    .frame(maxWidth: 480)
                Spacer(minLength: 0)
                GlassActionGroup {
                    ServerWebUIButton(server: server)
                        .glassButton().controlSize(.large)
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
