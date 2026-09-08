// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The single-server workspace. It deliberately owns only presentation state;
/// every control writes through the same defaults/profile objects used by Home,
/// Settings and the compact server cards.
struct ServerDetailView: View {
    enum Tab: String, CaseIterable, Hashable {
        case configuration, performance, logs, api, integrations
    }

    @ObservedObject var server: ServerController
    @EnvironmentObject private var manager: ServerManager
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var vram: VRAMMonitor
    @EnvironmentObject private var control: ControlPanelState
    @State private var tab: Tab = .configuration

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ServerDetailHero(server: server)
            metricStrip
            ServerDetailTabs(selection: $tab)
            tabContent
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var metricStrip: some View {
        let settings = server.effectiveSettings()
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
            DashboardMetric(title: loc.t("Última generación", "Last generation"), icon: "bolt.fill",
                            value: server.genSpeed.map { String(format: "%.1f t/s", $0) } ?? "—",
                            detail: loc.t("Velocidad de la petición más reciente", "Most recent request speed"),
                            history: Array(server.genHistory.suffix(28)))
            DashboardMetric(title: loc.t("Peticiones", "Requests"), icon: "bubble.left.and.text.bubble.right",
                            value: "\(server.requestCount)",
                            detail: loc.t("Completadas en esta sesión", "Completed this session"), tint: .chartSecondary)
            DashboardMetric(title: loc.t("Uso de VRAM", "VRAM usage"), icon: "memorychip",
                            value: vram.gpus.isEmpty ? "—" : String(format: "%.1f / %.0f GB", vram.usedMB / 1024, vram.totalMB / 1024),
                            detail: String(format: "%.0f%%", vram.fraction * 100), progress: vram.fraction)
            DashboardMetric(title: loc.t("Longitud de contexto", "Context length"), icon: "doc.plaintext",
                            value: "\(settings.ctx / 1024)k",
                            detail: loc.t("Máximo configurado", "Configured maximum"),
                            progress: min(Double(settings.ctx) / 262_144, 1), tint: .chartSecondary)
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .configuration:
            ServerConfigurationWorkspace(server: server)
        case .performance:
            ServerPerformanceWorkspace(server: server)
        case .logs:
            ServerLogView(server: server)
                .frame(minHeight: 560)
                .cardSurface()
        case .api:
            ServerAPIWorkspace(server: server)
        case .integrations:
            ServerIntegrationsWorkspace(server: server)
        }
    }
}

private struct ServerDetailHero: View {
    @ObservedObject var server: ServerController
    @EnvironmentObject private var manager: ServerManager
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var control: ControlPanelState
    @AppStorage(SettingsKeys.modelPath) private var globalModelPath = ""
    @AppStorage(SettingsKeys.ncmoe) private var globalNcmoe = 0

    var body: some View {
        let settings = server.effectiveSettings()
        let model = ModelName.forPath(settings.modelPath)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 22) {
                identity(model, settings: settings)
                Divider().frame(height: 116)
                statusAndActions(settings)
            }
            VStack(alignment: .leading, spacing: 18) {
                identity(model, settings: settings)
                Divider()
                statusAndActions(settings)
            }
        }
        .padding(20)
        .cardSurface()
    }

    private func identity(_ model: ModelName, settings: ServerSettings) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ModelBrandIcon(name: settings.modelPath, size: 54)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text(settings.modelPath.isEmpty ? loc.t("Sin modelo", "No model") : model.title)
                        .font(.system(size: 23, weight: .bold))
                    modelMenu
                }
                Text(model.quant.isEmpty ? loc.t("Configura un modelo para esta instancia", "Configure a model for this instance") : model.quant)
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    if let params = model.paramsB { chip(String(format: "%.1fB params", params), "atom") }
                    chip(model.badges.contains("Vision") ? "Vision" : "Text & Chat", "bubble.left")
                    chip(model.family, "cpu")
                    chip("GGUF", "shippingbox")
                }
                Text(description(for: model))
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                Button(loc.t("Ver detalles del modelo", "View model details") + "  →") {
                    control.section = .models
                    control.serverAnchor = nil
                }
                .buttonStyle(.plain).foregroundStyle(Color.appAccent).font(.system(size: 13, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(WorkspaceStyle.inset, in: Capsule())
            .overlay(Capsule().strokeBorder(WorkspaceStyle.border))
    }

    private func description(for model: ModelName) -> String {
        if model.badges.contains("Coder") {
            return loc.t("Modelo local especializado en programación y tareas con herramientas.", "Local model specialized in coding and tool-driven work.")
        }
        if model.badges.contains("Vision") {
            return loc.t("Modelo multimodal local para texto, imágenes y conversación.", "Local multimodal model for text, images and conversation.")
        }
        return loc.t("Modelo local para conversación, escritura y tareas cotidianas.", "Local model for chat, writing and everyday tasks.")
    }

    private func statusAndActions(_ settings: ServerSettings) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                statusSummary
                Spacer(minLength: 12)
                serverActions(settings)
            }
            VStack(alignment: .leading, spacing: 14) {
                statusSummary
                serverActions(settings)
            }
        }
        .frame(minWidth: 410, maxWidth: 520, alignment: .leading)
    }

    private var statusSummary: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 3) {
                ServerStateBadge(state: server.state)
                    .font(.system(size: 15, weight: .semibold))
                if let started = server.startedAt {
                    Text(loc.t("Activo durante %@", "Uptime %@", duration(from: started, to: context.date)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func serverActions(_ settings: ServerSettings) -> some View {
        GlassActionGroup {
            Button { server.restart(server.effectiveSettings()) } label: {
                Label(loc.t("Reiniciar", "Restart"), systemImage: "arrow.clockwise")
            }
            .glassButton()
            .disabled(server.state != .running)
            .opacity(server.state == .running ? 1 : 0.48)
            .help(server.state == .running
                  ? loc.t("Reiniciar este servidor", "Restart this server")
                  : loc.t("Disponible cuando el servidor está activo", "Available while the server is running"))
            if server.state == .running || server.state == .starting {
                Button { server.stop() } label: {
                    Label(loc.t("Detener servidor", "Stop server"), systemImage: "stop.fill")
                }.glassButton(prominent: true)
            } else {
                Button { server.start(settings) } label: {
                    Label(loc.t("Iniciar servidor", "Start server"), systemImage: "play.fill")
                }.glassButton(prominent: true)
                    .disabled(settings.routerMode ? models.models.isEmpty : settings.modelPath.isEmpty)
            }
            if server.state == .running || server.profile != nil {
                Menu {
                    if server.state == .running {
                        Button(loc.t("Abrir interfaz web", "Open web interface"), systemImage: "safari") {
                            NSWorkspace.shared.open(server.webChatURL)
                        }
                    }
                    if server.profile != nil {
                        if server.state == .running { Divider() }
                        Button(loc.t("Eliminar servidor", "Delete server"), systemImage: "trash", role: .destructive) {
                            manager.removeServer(server.id)
                            control.serverAnchor = nil
                        }
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).glassButton()
            }
        }
    }

    private var modelMenu: some View {
        Menu {
            if models.models.isEmpty {
                Text(loc.t("No hay modelos descargados", "No downloaded models"))
            } else {
                ForEach(ModelFamilyGroup.grouped(models.models)) { group in
                    Section(group.isOther ? loc.t("Otros", "Others") : group.family) {
                        ForEach(group.models) { local in
                            Button {
                                selectModel(local.url.path)
                            } label: {
                                Label(ModelName.forPath(local.url.path).display,
                                      systemImage: server.effectiveSettings().modelPath == local.url.path ? "checkmark" : "cube")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(server.state == .running || server.state == .starting)
        .help(loc.t("Cambiar el modelo de este servidor", "Change this server's model"))
    }

    private func selectModel(_ path: String) {
        let suggested = Estimator.ncmoeForSelection(path: path, models: models.models)
        if server.profile == nil {
            globalModelPath = path
            globalNcmoe = suggested
        } else {
            server.profile?.selectInstanceModel(path: path, ncmoe: suggested)
            manager.persist()
        }
    }

    private func duration(from start: Date, to end: Date) -> String {
        let minutes = max(Int(end.timeIntervalSince(start)) / 60, 0)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

private struct ServerDetailTabs: View {
    @Binding var selection: ServerDetailView.Tab
    @EnvironmentObject private var loc: Localizer

    var body: some View {
        GlassSegmentedControl(selection: $selection, segments: [
            .init(value: .configuration, title: loc.t("Configuración", "Configuration"), systemImage: "slider.horizontal.3"),
            .init(value: .performance, title: loc.t("Rendimiento", "Performance"), systemImage: "chart.xyaxis.line"),
            .init(value: .logs, title: "Logs", systemImage: "doc.text"),
            .init(value: .api, title: "API", systemImage: "chevron.left.forwardslash.chevron.right"),
            .init(value: .integrations, title: loc.t("Integraciones", "Integrations"), systemImage: "point.3.connected.trianglepath.dotted")
        ])
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ServerConfigurationWorkspace: View {
    @ObservedObject var server: ServerController
    @EnvironmentObject private var manager: ServerManager
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var profileStore: ProfileStore

    @AppStorage(SettingsKeys.modelPath) private var globalModelPath = ""
    @AppStorage(SettingsKeys.port) private var globalPort = 8080
    @AppStorage(SettingsKeys.ctx) private var globalContext = 16384
    @AppStorage(SettingsKeys.gpuIndex) private var globalGPU = -1
    @AppStorage(SettingsKeys.gpuList) private var globalGPUList = ""
    @AppStorage(SettingsKeys.localNetworkDiscovery) private var globalDiscovery = false
    @AppStorage(SettingsKeys.parallelSlots) private var globalParallel = 1
    @AppStorage(SettingsKeys.embeddings) private var globalEmbeddings = false
    @AppStorage(SettingsKeys.uiMcpProxy) private var globalMCP = false
    @AppStorage(SettingsKeys.routerMode) private var globalRouter = false
    @AppStorage(SettingsKeys.routerModelsMax) private var globalRouterMax = 1
    @AppStorage(SettingsKeys.extraArgs) private var globalExtraArgs = ""
    @AppStorage(SettingsKeys.ubatch) private var globalUbatch = 0
    @AppStorage(SettingsKeys.ncmoe) private var globalNcmoe = 0
    @AppStorage(SettingsKeys.loadVision) private var globalVision = true
    @State private var profileSelection = "current"

    private var busy: Bool { server.state == .running || server.state == .starting }
    private var settings: ServerSettings { server.effectiveSettings() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) { serverSettingsCard; engineCard }
                VStack(spacing: 14) { serverSettingsCard; engineCard }
            }
            modelConfigurationCard
            HStack {
                if server.profile != nil {
                    ServerDeleteButton(presentation: .labeled) {
                        manager.removeServer(server.id)
                    }
                }
                Spacer()
                Button { resetOverrides() } label: {
                    Label(loc.t("Restablecer valores", "Reset to defaults"), systemImage: "arrow.counterclockwise")
                }.glassButton()
                Button { manager.persist() } label: {
                    Label(loc.t("Guardar cambios", "Save changes"), systemImage: "checkmark")
                }.glassButton(prominent: true)
            }
        }
    }

    private var serverSettingsCard: some View {
        DetailPanel(title: loc.t("Ajustes del servidor", "Server settings"),
                    subtitle: loc.t("Opciones principales de esta instancia.", "Core settings for this server instance."), icon: "server.rack", fill: true) {
            ServerSettingRow(icon: "shippingbox", title: loc.t("Modelo", "Model")) {
                ToshDropdown(selection: modelSelection, options: modelOptions,
                             placeholder: loc.t("Elige un modelo", "Choose a model"), listWidth: 390)
            }
            ServerSettingRow(icon: "number.square", title: loc.t("Puerto", "Port")) {
                TextField("", value: port, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing).workspaceTextField(width: 126)
            }
            ServerSettingRow(icon: "doc.plaintext", title: loc.t("Longitud de contexto", "Context length")) {
                ToshDropdown(selection: context, options: contextOptions, width: 126)
            }
            ServerSettingRow(icon: "wifi", title: loc.t("Descubrible en red local", "Discoverable on local network")) {
                Toggle("", isOn: discovery).labelsHidden().toggleStyle(.switch)
            }
            ServerSettingRow(icon: "number", title: loc.t("Límite de peticiones", "Request limit"),
                             detail: loc.t("Solicitudes procesadas en paralelo", "Requests processed in parallel")) {
                requestLimitMenu
            }
        }
        .disabled(busy)
    }

    private var engineCard: some View {
        DetailPanel(title: loc.t("Motor y hardware", "Engine and hardware"),
                    subtitle: loc.t("Perfil de ejecución y aceleración.", "Execution profile and acceleration."), icon: "gearshape", fill: true) {
            ServerSettingRow(icon: "slider.horizontal.3", title: loc.t("Perfil del motor", "Engine profile")) {
                profileMenu
            }
            ServerSettingRow(icon: "cpu", title: "GPU") {
                ToshDropdown(selection: gpuChoice, options: gpuOptions)
            }
            HStack(spacing: 10) {
                hardwareTile("display", hardware.gpus.first?.name ?? loc.t("GPU predeterminada", "Default GPU"),
                             hardware.gpus.first.map { "\($0.vramGB) GB VRAM · Metal" } ?? "Metal")
                hardwareTile("apple.logo", hardware.osVersion, ServerSettings.isAppleSilicon ? "Apple Silicon" : "AMD Metal")
            }
            Divider().padding(.vertical, 3)
            Label(loc.t("Servicios y opciones avanzadas", "Services and advanced options"), systemImage: "slider.horizontal.3")
                .font(.system(size: 14, weight: .semibold))
            ServerSettingRow(icon: "point.3.connected.trianglepath.dotted", title: loc.t("Servidor de embeddings", "Embeddings server"),
                             detail: loc.t("Expone un endpoint compatible con OpenAI", "Exposes an OpenAI-compatible endpoint")) {
                Toggle("", isOn: embeddings).labelsHidden().toggleStyle(.switch)
            }
            ServerSettingRow(icon: "network", title: loc.t("Proxy MCP para la interfaz web", "MCP proxy for the web interface"),
                             detail: loc.t("Permite usar MCP mediante la interfaz web", "Allows MCP through the web interface")) {
                Toggle("", isOn: mcpProxy).labelsHidden().toggleStyle(.switch)
            }
            ServerSettingRow(icon: "arrow.triangle.2.circlepath", title: loc.t("Router (multi-modelo)", "Router (multi-model)"),
                             detail: loc.t("Enruta peticiones entre modelos locales", "Routes requests across local models")) {
                Toggle("", isOn: router).labelsHidden().toggleStyle(.switch)
            }
            if router.wrappedValue {
                ServerSettingRow(icon: "square.stack.3d.up", title: loc.t("Modelos simultáneos", "Models loaded at once")) {
                    Stepper("\(routerMax.wrappedValue)", value: routerMax, in: 1...4).fixedSize()
                }
            }
            ServerSettingRow(icon: "terminal", title: loc.t("Argumentos extra", "Extra arguments")) {
                TextField("--no-warmup -np 2", text: extraArgs)
                    .font(.system(.callout, design: .monospaced))
                    .workspaceTextField(width: 330)
            }
        }
        .disabled(busy)
    }

    private var modelConfigurationCard: some View {
        DetailPanel(title: loc.t("Configuración del modelo", "Model configuration"),
                    subtitle: loc.t("Parámetros específicos del modelo seleccionado.", "Model-specific parameters for the selected model."), icon: "cube") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    modelRuntimeGroup
                    modelAccelerationGroup
                }
                VStack(spacing: 12) {
                    modelRuntimeGroup
                    modelAccelerationGroup
                }
            }
            if !settings.modelPath.isEmpty {
                HStack(spacing: 10) {
                    Label(loc.t("Detectado", "Detected"), systemImage: "checkmark.seal")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            TagBadge(text: ModelName.forPath(settings.modelPath).quant.isEmpty ? "GGUF" : ModelName.forPath(settings.modelPath).quant,
                                     icon: "shippingbox", color: .secondary)
                            if ServerSettings.modelIsMoE(at: settings.modelPath) { TagBadge(text: "MoE", icon: "square.stack.3d.up", color: .purple) }
                            if ServerSettings.mightSupportVision(modelPath: settings.modelPath) { TagBadge(text: "Vision", icon: "eye", color: .purple) }
                            if ServerSettings.modelUsesMTP(at: settings.modelPath) { TagBadge(text: "MTP", icon: "hare.fill", color: .green) }
                            if ServerSettings.dflashDraftPath(forModel: settings.modelPath) != nil { TagBadge(text: "DFlash", icon: "bolt.fill", color: .orange) }
                        }
                    }
                    Spacer(minLength: 8)
                    Label(settings.ncmoe > 0 && ServerSettings.modelIsMoE(at: settings.modelPath)
                          ? loc.t("Limitado por RAM", "RAM limited")
                          : loc.t("Limitado por VRAM", "VRAM limited"),
                          systemImage: "gauge.with.needle")
                        .font(.caption).foregroundStyle(.secondary).fixedSize()
                }
                .padding(.horizontal, 12).frame(minHeight: 42)
                .background(WorkspaceStyle.inset, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                SpecMetricsView(port: settings.port)
            }
        }
        .disabled(busy)
    }

    private var modelRuntimeGroup: some View {
        ModelConfigurationGroup(title: loc.t("Ejecución", "Runtime"), icon: "memorychip") {
            ServerSettingRow(icon: "square.stack.3d.down.right", title: loc.t("Micro-lote", "Micro-batch"),
                             detail: loc.t("Equilibra velocidad y memoria", "Balances throughput and memory")) {
                ToshDropdown(selection: ubatch, options: ubatchOptions, width: 184, listWidth: 250)
            }
            if ServerSettings.modelIsMoE(at: settings.modelPath) {
                Divider()
                ServerSettingRow(icon: "cpu", title: loc.t("Expertos MoE en CPU", "MoE experts on CPU"),
                                 detail: loc.t("Reduce VRAM usando memoria del sistema", "Trades system memory for lower VRAM use")) {
                    CompactIntegerStepper(value: ncmoe, range: 0...99)
                }
            }
        }
    }

    private var modelAccelerationGroup: some View {
        ModelConfigurationGroup(title: loc.t("Capacidades y aceleración", "Capabilities and acceleration"), icon: "bolt.horizontal") {
            if ServerSettings.mightSupportVision(modelPath: settings.modelPath) {
                ServerSettingRow(icon: "photo", title: loc.t("Modelo de visión", "Vision model"),
                                 detail: loc.t("Proyector visual para imágenes", "Visual projector used for images")) {
                    VisionProjectorControl(modelPath: settings.modelPath, layout: .detail, loadEnabled: vision)
                }
            }
            if ServerSettings.modelUsesMTP(at: settings.modelPath) {
                if ServerSettings.mightSupportVision(modelPath: settings.modelPath) { Divider() }
                ServerSettingRow(icon: "hare.fill", title: "MTP",
                                 detail: loc.t("Predicción de múltiples tokens", "Multi-token prediction")) {
                    MTPControl(modelPath: settings.modelPath)
                }
            }
            if ServerSettings.dflashDraftPath(forModel: settings.modelPath) != nil {
                if ServerSettings.mightSupportVision(modelPath: settings.modelPath) || ServerSettings.modelUsesMTP(at: settings.modelPath) { Divider() }
                ServerSettingRow(icon: "bolt.fill", title: "DFlash",
                                 detail: loc.t("Decodificación con borrador especulativo", "Speculative draft decoding")) {
                    DflashControl(modelPath: settings.modelPath, layout: .detail)
                        .environmentObject(server)
                }
            }
            if !ServerSettings.mightSupportVision(modelPath: settings.modelPath) &&
                !ServerSettings.modelUsesMTP(at: settings.modelPath) &&
                ServerSettings.dflashDraftPath(forModel: settings.modelPath) == nil {
                Label(loc.t("Este modelo no declara aceleradores opcionales.", "This model does not declare optional accelerators."),
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 9)
            }
        }
    }

    private var profileMenu: some View {
        ToshDropdown(selection: $profileSelection, options: profileOptions)
        .onChange(of: profileSelection) { _, value in
            guard value != "current",
                  let profile = profileStore.profiles.first(where: { $0.id.uuidString == value }) else { return }
            applyProfile(profile)
        }
    }

    private var requestLimitMenu: some View {
        ToshDropdown(selection: parallel, options: requestLimitOptions)
    }

    private var modelOptions: [ToshDropdown<String>.Option] {
        [.init(value: "", title: loc.t("Sin modelo", "No model"), systemImage: "nosign")] +
        models.models.map { local in
            let parsed = ModelName.forPath(local.url.path)
            return .init(value: local.url.path, title: parsed.display,
                         subtitle: URL(fileURLWithPath: local.url.path).lastPathComponent,
                         systemImage: "cube")
        }
    }

    private var profileOptions: [ToshDropdown<String>.Option] {
        [.init(value: "current", title: loc.t("Ajustes actuales", "Current settings"), systemImage: "slider.horizontal.3")] +
        profileStore.profiles.map { .init(value: $0.id.uuidString, title: $0.name, systemImage: "person.crop.circle") }
    }

    private var contextOptions: [ToshDropdown<Int>.Option] {
        [4096, 8192, 16384, 32768, 65536, 131072, 262144].map {
            .init(value: $0, title: "\($0 / 1024)k")
        }
    }

    private var requestLimitOptions: [ToshDropdown<Int>.Option] {
        [.init(value: 0, title: loc.t("Sin límite", "Unlimited"))] + (1...8).map { value in
            .init(value: value, title: value == 1 ? loc.t("1 petición", "1 request") : loc.t("%@ peticiones", "%@ requests", "\(value)"))
        }
    }

    private var ubatchOptions: [ToshDropdown<Int>.Option] {
        ServerSettings.ubatchOptions.map { .init(value: $0, title: ServerSettings.ubatchLabel($0, loc: loc)) }
    }

    private var gpuOptions: [ToshDropdown<Int>.Option] {
        var result: [ToshDropdown<Int>.Option] = [
            .init(value: -1, title: loc.t("GPU predeterminada", "Default GPU"),
                  subtitle: hardware.gpus.first.map { "\($0.name) · \($0.vramGB) GB" }, systemImage: "cpu")
        ]
        if gpuList.wrappedValue.count >= 2 {
            result.append(.init(value: -2,
                                title: loc.t("Reparto · %@ GPUs", "Split · %@ GPUs", "\(gpuList.wrappedValue.count)"),
                                subtitle: gpuList.wrappedValue.compactMap { index in hardware.gpus.first { $0.index == index }?.name }.joined(separator: " + "),
                                systemImage: "square.split.2x1"))
        }
        result += hardware.gpus.map { .init(value: $0.index, title: $0.name, subtitle: "\($0.vramGB) GB VRAM · Metal", systemImage: "display") }
        return result
    }

    private func hardwareTile(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkspaceStyle.inset, in: RoundedRectangle(cornerRadius: 8))
    }

    private func applyProfile(_ profile: Profile) {
        if server.profile == nil {
            profileStore.apply(profile)
        } else {
            var copy = profile
            copy.name = server.name
            copy.port = server.profile?.port ?? profile.port
            server.profile = copy
            manager.persist()
        }
    }

    private func resetOverrides() {
        guard var profile = server.profile else {
            globalContext = 16384; globalGPU = -1; globalGPUList = ""; globalDiscovery = false
            globalParallel = 1; globalEmbeddings = false; globalMCP = false; globalRouter = false
            globalRouterMax = 1; globalExtraArgs = ""; globalUbatch = 0
            return
        }
        profile.pinned = [Profile.Pin.model]
        server.profile = profile
        manager.persist()
    }

    private func addedBinding<T>(_ keyPath: WritableKeyPath<Profile, T>, fallback: T,
                                 pin key: String? = nil) -> Binding<T> {
        Binding(get: { server.profile?[keyPath: keyPath] ?? fallback }, set: { value in
            server.profile?[keyPath: keyPath] = value
            if let key { pin(key) }
            manager.persist()
        })
    }

    private func pin(_ key: String) {
        guard var pins = server.profile?.pinned else { return }
        if !pins.contains(key) { pins.append(key); server.profile?.pinned = pins }
    }

    private var port: Binding<Int> { server.profile == nil ? $globalPort : addedBinding(\.port, fallback: settings.port) }
    private var modelSelection: Binding<String> {
        Binding(get: { settings.modelPath }, set: { path in
            server.selectModel(path: path, ncmoe: Estimator.ncmoeForSelection(path: path, models: models.models))
            manager.persist()
        })
    }
    private var context: Binding<Int> { server.profile == nil ? $globalContext : addedBinding(\.ctx, fallback: settings.ctx, pin: Profile.Pin.ctx) }
    private var discovery: Binding<Bool> { server.profile == nil ? $globalDiscovery : addedBinding(\.localNetworkDiscovery, fallback: settings.localNetworkDiscovery, pin: Profile.Pin.discovery).optionalValue(default: false) }
    private var parallel: Binding<Int> { server.profile == nil ? $globalParallel : addedBinding(\.parallelSlots, fallback: settings.parallelSlots, pin: Profile.Pin.parallelSlots).optionalValue(default: 1) }
    private var embeddings: Binding<Bool> { server.profile == nil ? $globalEmbeddings : addedBinding(\.embeddings, fallback: settings.embeddings, pin: Profile.Pin.embeddings).optionalValue(default: false) }
    private var mcpProxy: Binding<Bool> { server.profile == nil ? $globalMCP : addedBinding(\.uiMcpProxy, fallback: settings.uiMcpProxy, pin: Profile.Pin.uiMcpProxy).optionalValue(default: false) }
    private var router: Binding<Bool> { server.profile == nil ? $globalRouter : addedBinding(\.routerMode, fallback: settings.routerMode, pin: Profile.Pin.router).optionalValue(default: false) }
    private var routerMax: Binding<Int> { server.profile == nil ? $globalRouterMax : addedBinding(\.routerModelsMax, fallback: settings.routerModelsMax, pin: Profile.Pin.router).optionalValue(default: 1) }
    private var extraArgs: Binding<String> { server.profile == nil ? $globalExtraArgs : addedBinding(\.extraArgs, fallback: settings.extraArgs, pin: Profile.Pin.extraArgs) }
    private var ubatch: Binding<Int> { server.profile == nil ? $globalUbatch : addedBinding(\.ubatch, fallback: settings.ubatch, pin: Profile.Pin.ubatch).optionalValue(default: 0) }
    private var ncmoe: Binding<Int> { server.profile == nil ? $globalNcmoe : addedBinding(\.ncmoe, fallback: settings.ncmoe, pin: Profile.Pin.moe) }
    private var vision: Binding<Bool> { server.profile == nil ? $globalVision : addedBinding(\.loadVision, fallback: settings.loadVision, pin: Profile.Pin.vision).optionalValue(default: true) }
    private var gpu: Binding<Int> { server.profile == nil ? $globalGPU : addedBinding(\.gpuIndex, fallback: settings.gpuIndex, pin: Profile.Pin.gpu) }
    private var gpuChoice: Binding<Int> {
        Binding(get: { gpuList.wrappedValue.count >= 2 ? -2 : gpu.wrappedValue }, set: { value in
            guard value != -2 else { return }
            gpuList.wrappedValue = []
            gpu.wrappedValue = value
        })
    }
    private var gpuList: Binding<[Int]> {
        if server.profile == nil {
            return Binding(get: { ServerSettings.gpuList(fromCSV: globalGPUList) },
                           set: { globalGPUList = $0.map(String.init).joined(separator: ",") })
        }
        return addedBinding(\.gpuList, fallback: settings.gpuList, pin: Profile.Pin.gpu).optionalValue(default: [])
    }
}

private extension Binding {
    func optionalValue<Wrapped>(default defaultValue: Wrapped) -> Binding<Wrapped> where Value == Wrapped? {
        Binding<Wrapped>(get: { wrappedValue ?? defaultValue }, set: { wrappedValue = $0 })
    }
}

private struct ServerSettingRow<Control: View>: View {
    let icon: String
    let title: String
    var detail: String? = nil
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon).frame(width: 19).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }.frame(minHeight: detail == nil ? 36 : 44)
    }
}

private struct DetailPanel<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    var fill = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.system(size: 16, weight: .semibold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            Divider()
            content
        }.padding(16).frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading).cardSurface()
    }
}

private struct ModelConfigurationGroup<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(WorkspaceStyle.inset, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(WorkspaceStyle.border.opacity(0.7)))
    }
}

private struct CompactIntegerStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", enabled: value > range.lowerBound) { value -= 1 }
            Text("\(value)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 42)
            stepButton("plus", enabled: value < range.upperBound) { value += 1 }
        }
        .frame(height: 32)
        .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(WorkspaceStyle.border))
    }

    private func stepButton(_ image: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image).font(.system(size: 10, weight: .bold)).frame(width: 30, height: 30)
        }
        .buttonStyle(.plain).foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.35))
        .disabled(!enabled)
    }
}

private struct ServerPerformanceWorkspace: View {
    @ObservedObject var server: ServerController
    @EnvironmentObject private var vram: VRAMMonitor
    @EnvironmentObject private var loc: Localizer

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) { throughput; resources }
            VStack(spacing: 14) { throughput; resources }
        }
    }

    private var throughput: some View {
        DetailPanel(title: loc.t("Rendimiento de inferencia", "Inference performance"),
                    subtitle: loc.t("Mediciones de la sesión actual.", "Measurements from the current session."), icon: "chart.xyaxis.line") {
            ServerSettingRow(icon: "text.alignleft", title: loc.t("Procesamiento de prompt", "Prompt processing")) {
                Text(server.promptSpeed.map { String(format: "%.1f t/s", $0) } ?? "—").monospacedDigit()
            }
            ServerSettingRow(icon: "bolt.fill", title: loc.t("Generación", "Generation")) {
                Text(server.genSpeed.map { String(format: "%.1f t/s", $0) } ?? "—").monospacedDigit()
            }
            ServerSettingRow(icon: "checkmark.circle", title: loc.t("Peticiones completadas", "Completed requests")) {
                Text("\(server.requestCount)").monospacedDigit()
            }
            if server.genHistory.count > 1 {
                DashboardMetric(title: loc.t("Historial de generación", "Generation history"), icon: "waveform.path.ecg",
                                value: server.genSpeed.map { String(format: "%.1f t/s", $0) } ?? "—",
                                detail: loc.t("Últimas mediciones", "Latest measurements"),
                                history: Array(server.genHistory.suffix(28)))
            }
        }
    }

    private var resources: some View {
        DetailPanel(title: loc.t("Recursos", "Resources"),
                    subtitle: loc.t("Datos ligeros obtenidos del sistema.", "Lightweight telemetry reported by the system."), icon: "gauge.with.needle") {
            ServerSettingRow(icon: "memorychip", title: "VRAM") {
                Text(String(format: "%.1f / %.0f GB", vram.usedMB / 1024, vram.totalMB / 1024)).monospacedDigit()
            }
            ProgressView(value: vram.fraction).tint(Color.appAccent)
            ServerSettingRow(icon: "cpu", title: loc.t("Actividad GPU", "GPU activity")) {
                Text(vram.activityPercent.map { String(format: "%.0f%%", $0) } ?? loc.t("No disponible", "Unavailable"))
                    .monospacedDigit()
            }
            ServerSettingRow(icon: "internaldrive", title: loc.t("Memoria del sistema", "System memory")) {
                Text(String(format: "%.1f / %.0f GB", vram.memoryUsedMB / 1024, vram.memoryTotalMB / 1024)).monospacedDigit()
            }
            ProgressView(value: vram.memoryFraction).tint(Color.chartSecondary)
        }
    }
}

private struct ServerAPIWorkspace: View {
    @ObservedObject var server: ServerController
    @EnvironmentObject private var loc: Localizer

    var body: some View {
        let settings = server.effectiveSettings()
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) { endpointCard(settings); routesCard }
            VStack(spacing: 14) { endpointCard(settings); routesCard }
        }
    }

    private func endpointCard(_ settings: ServerSettings) -> some View {
        DetailPanel(title: loc.t("Conexión API", "API connection"),
                    subtitle: loc.t("Compatible con clientes OpenAI.", "Compatible with OpenAI clients."), icon: "network") {
            ServerSettingRow(icon: "link", title: loc.t("URL base", "Base URL")) {
                Text("http://127.0.0.1:\(settings.port)/v1").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            }
            ServerSettingRow(icon: "wifi", title: loc.t("Acceso", "Access")) {
                Text(settings.localNetworkDiscovery ? loc.t("Red local", "Local network") : loc.t("Solo este Mac", "This Mac only"))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("http://127.0.0.1:\(settings.port)/v1", forType: .string) } label: {
                    Label(loc.t("Copiar URL", "Copy URL"), systemImage: "doc.on.doc")
                }.glassButton()
                if server.state == .running {
                    Button { NSWorkspace.shared.open(server.webChatURL) } label: {
                        Label(loc.t("Abrir interfaz web", "Open web interface"), systemImage: "safari")
                    }.glassButton(prominent: true)
                }
            }
        }
    }

    private var routesCard: some View {
        DetailPanel(title: loc.t("Rutas disponibles", "Available routes"),
                    subtitle: loc.t("Endpoints expuestos por llama.cpp.", "Endpoints exposed by llama.cpp."), icon: "chevron.left.forwardslash.chevron.right") {
            apiRoute("POST", "/v1/chat/completions", loc.t("Chat y generación", "Chat and generation"))
            apiRoute("GET", "/v1/models", loc.t("Modelos disponibles", "Available models"))
            apiRoute("POST", "/v1/embeddings", loc.t("Vectores de embeddings", "Embedding vectors"))
            apiRoute("GET", "/health", loc.t("Estado del servidor", "Server health"))
        }
    }

    private func apiRoute(_ method: String, _ path: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Text(method).font(.caption2.bold()).foregroundStyle(Color.appAccent).frame(width: 34)
            Text(path).font(.system(.caption, design: .monospaced))
            Spacer()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 5)
    }
}

private struct ServerIntegrationsWorkspace: View {
    @ObservedObject var server: ServerController
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var models: ModelStore

    var body: some View {
        let settings = server.effectiveSettings()
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 310), spacing: 14)], spacing: 14) {
            integration("point.3.connected.trianglepath.dotted", loc.t("Embeddings", "Embeddings"),
                        loc.t("Búsqueda semántica y aplicaciones RAG.", "Semantic search and RAG applications."), settings.embeddings,
                        rows: [(loc.t("Endpoint", "Endpoint"), "POST /v1/embeddings"),
                               (loc.t("Modelo", "Model"), ModelName.forPath(settings.modelPath).title),
                               (loc.t("Formato", "Format"), "OpenAI compatible")])
            integration("network", "MCP", loc.t("Puente de herramientas para la interfaz web.", "Tool bridge for the engine web interface."), settings.uiMcpProxy,
                        rows: [(loc.t("Transporte", "Transport"), "HTTP / SSE"),
                               (loc.t("Alcance", "Scope"), settings.localNetworkDiscovery ? loc.t("Red local", "Local network") : loc.t("Solo este Mac", "This Mac only")),
                               (loc.t("Cliente", "Client"), loc.t("Interfaz web del motor", "Engine web interface"))])
            integration("arrow.triangle.2.circlepath", loc.t("Router de modelos", "Model router"),
                        loc.t("Selección del modelo en cada petición.", "Model selection on each request."), settings.routerMode,
                        rows: [(loc.t("Modelos locales", "Local models"), "\(models.models.count)"),
                               (loc.t("Cargados a la vez", "Loaded at once"), "\(settings.routerModelsMax)"),
                               (loc.t("Descubrimiento", "Discovery"), "GET /v1/models")])
            integration("safari", loc.t("Interfaz web", "Web interface"),
                        loc.t("Chat web incluido con el motor.", "Web chat bundled with the engine."), server.state == .running,
                        rows: [("URL", "http://127.0.0.1:\(settings.port)"),
                               (loc.t("Estado", "Status"), server.state == .running ? loc.t("Disponible", "Available") : loc.t("Requiere iniciar el servidor", "Start the server to use")),
                               (loc.t("Acceso", "Access"), settings.localNetworkDiscovery ? loc.t("Red local", "Local network") : loc.t("Solo este Mac", "This Mac only"))],
                        openWeb: true)
        }
    }

    private func integration(_ icon: String, _ title: String, _ description: String, _ enabled: Bool,
                             rows: [(String, String)], openWeb: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon).font(.title2).foregroundStyle(Color.appAccent)
                Spacer()
                Label(enabled ? loc.t("Activo", "Enabled") : loc.t("Inactivo", "Disabled"),
                      systemImage: enabled ? "checkmark.circle.fill" : "circle")
                    .font(.caption.weight(.medium)).foregroundStyle(enabled ? .green : .secondary)
            }
            Text(title).font(.headline)
            Text(description).font(.callout).foregroundStyle(.secondary)
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.0).foregroundStyle(.secondary)
                    Spacer(minLength: 10)
                    Text(row.1).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }.font(.system(size: 12))
            }
            if openWeb, server.state == .running {
                Button { NSWorkspace.shared.open(server.webChatURL) } label: {
                    Label(loc.t("Abrir interfaz web", "Open web interface"), systemImage: "arrow.up.right.square")
                }.glassButton(prominent: true).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }.padding(16).frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading).cardSurface()
    }
}
