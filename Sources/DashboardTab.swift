// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Charts

// MARK: - Home

struct DashboardView: View {
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var manager: ServerManager
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var profileStore: ProfileStore
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""
    @AppStorage(SettingsKeys.ncmoe) private var ncmoe = 0
    @AppStorage(SettingsKeys.port) private var port = 8080
    @AppStorage(SettingsKeys.localNetworkDiscovery) private var localNetworkDiscovery = false
    @AppStorage(SettingsKeys.apiKeyEnabled) private var apiKeyEnabled = false
    @AppStorage(SettingsKeys.gpuIndex) private var gpuIndex = -1
    @AppStorage(SettingsKeys.gpuList) private var gpuListCSV = ""
    @AppStorage(SettingsKeys.embeddings) private var embeddings = false
    @AppStorage(SettingsKeys.uiMcpProxy) private var uiMcpProxy = false
    @State private var showNotes = false
    @AppStorage(SettingsKeys.routerMode) private var routerMode = false
    @AppStorage(SettingsKeys.routerModelsMax) private var routerModelsMax = 1

    @EnvironmentObject var updates: UpdateChecker

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    updateBanner
                    // Cards flow into as many columns as the window fits, so extra servers
                    // fill the width instead of stacking in one tall column.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)],
                              spacing: 16) {
                        MachineCard()
                        GPUsCard()
                        serverCard
                        // Array(...) not the ArraySlice from dropFirst(): a slice keeps its
                        // parent's 1-based indices, which ForEach mishandles (the first added
                        // server would never refresh its state).
                        ForEach(Array(manager.servers.dropFirst()), id: \.id) { c in
                            AddedServerCard(c: c).environmentObject(manager).id(c.id)
                        }
                    }
                    recommendationCard
                }
                .padding()
            }
            .overlay(alignment: .bottomTrailing) {
                floatingAddButton(proxy).padding(20)
            }
        }
    }

    @ViewBuilder
    private var updateBanner: some View {
        if let version = updates.latestVersion {
            HStack {
                Label(loc.t("ToshLLM \(version) está disponible", "ToshLLM \(version) is available"),
                      systemImage: "arrow.down.app")
                    .fontWeight(.medium)
                Spacer()
                if let error = updates.installError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if updates.installing {
                    ProgressView().controlSize(.small)
                    Text(loc.t("Actualizando…", "Updating…")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(loc.t("Notas", "Notes")) {
                        showNotes = true
                    }
                    .popover(isPresented: $showNotes, arrowEdge: .bottom) { ReleaseNotesPopover() }
                    .help(loc.t("Muestra las novedades desde tu versión hasta la más reciente.",
                                "Shows what changed from your version up to the latest one."))
                    Button(loc.t("Descargar e instalar", "Download and install")) {
                        Task { await updates.downloadAndInstall() }
                    }
                    .buttonStyle(.borderedProminent)
                    .help(loc.t("Descarga el DMG, verifica su checksum, instala la nueva versión en Aplicaciones y reinicia la app.",
                                "Downloads the DMG, verifies its checksum, installs the new version into Applications and relaunches the app."))
                }
            }
            .padding(12)
            .background(Color.appAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }


    // Networking is a launch flag, so restart the running primary to apply it now.
    private func setDiscoverable(_ on: Bool) {
        localNetworkDiscovery = on
        if server.state == .running || server.state == .starting {
            server.restart(.fromDefaults())
        }
    }

    private var profileMenu: some View {
        Menu {
            if profileStore.activeProfileName != nil {
                Button {
                    profileStore.clearActive()
                    if server.state == .running { server.stop() }
                } label: {
                    Label(loc.t("Predeterminado (sin perfil)", "Default (no profile)"),
                          systemImage: "arrow.uturn.backward")
                }
                Divider()
            }
            ForEach(profileStore.profiles) { p in
                Button {
                    profileStore.apply(p)
                    if server.state == .running { server.stop() }
                } label: {
                    Label(p.name, systemImage: profileStore.activeProfileName == p.name ? "checkmark" : "person.2")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.2").font(.system(size: 10, weight: .semibold))
                Text(profileStore.activeProfileName ?? loc.t("Perfil", "Profile"))
                    .font(.caption.weight(.medium)).lineLimit(1)
                    .frame(maxWidth: 150)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color.appAccent.opacity(0.15), in: Capsule())
            .foregroundStyle(Color.appAccent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(loc.t("Carga un perfil guardado. Si el servidor está activo, se detiene para aplicar.",
                    "Loads a saved profile. If the server is running, it stops so the profile applies."))
    }

    // Floating action button with the macOS 26 glass look (material fallback below).
    private func floatingAddButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            let n = manager.servers.count + 1
            let new = withAnimation(.snappy) {
                manager.addServer(name: loc.t("Servidor \(n)", "Server \(n)"), from: nil)
            }
            // The card is appended at the end of the grid, often below the fold;
            // scroll to it so the click visibly produces something.
            withAnimation(.snappy) { proxy.scrollTo(new.id, anchor: .center) }
        } label: {
            Label(loc.t("Agregar servidor", "Add server"), systemImage: "plus")
                .font(.body.weight(.medium))
                .padding(.horizontal, 18).padding(.vertical, 12)
                // Interactive glass installs its own press gesture that competes
                // with the Button and sometimes eats the click; feedback comes from
                // PressableButtonStyle instead.
                .glassSurface(in: Capsule(), tint: Color.appAccent)
                .contentShape(Capsule())
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        }
        .buttonStyle(PressableButtonStyle())
        .help(loc.t("Crea otro servidor independiente, con su propia GPU, modelo y puerto.",
                    "Creates another independent server with its own GPU, model and port."))
    }

    private var serverCard: some View {
        Card(title: loc.t("Servidor", "Server"), icon: "server.rack", fill: true,
             trailing: { if !profileStore.profiles.isEmpty { profileMenu } }) {
            if routerMode {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox.and.arrow.backward").frame(width: 18).foregroundStyle(.secondary)
                    Text(loc.t("Router: sirve los \(models.models.count) modelos descargados",
                               "Router: serves all \(models.models.count) downloaded models"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox").frame(width: 18).foregroundStyle(.secondary)
                    // Selecting a model also seeds ncmoe (remembered value, or the
                    // recommendation; 0 for dense) so it never carries over stale.
                    Picker("", selection: Binding(get: { modelPath }, set: { p in
                        modelPath = p
                        ncmoe = Estimator.ncmoeForSelection(path: p, models: models.models)
                    })) {
                        Text(loc.t("Sin modelo", "No model")).tag("")
                        ForEach(models.models) {
                            Text(ModelName.forPath($0.url.path).display
                                 + (ModelTraitsCache.cached(for: $0.url.path)?
                                        .pickerSuffix(spanish: loc.isSpanish) ?? ""))
                                .tag($0.url.path)
                        }
                    }
                    .labelsHidden()
                    .disabled(server.state == .running || server.state == .starting)
                }
            }
            if hardware.gpus.count > 1 {
                HStack(spacing: 8) {
                    Image(systemName: "cpu").frame(width: 18).foregroundStyle(.secondary)
                    GPUSelectionMenu(gpuIndex: $gpuIndex, gpuList: Binding(
                        get: { ServerSettings.gpuList(fromCSV: gpuListCSV) },
                        set: { gpuListCSV = $0.map(String.init).joined(separator: ",") }))
                        .disabled(server.state == .running || server.state == .starting)
                }
            }
            if ServerSettings.modelIsMoE(at: modelPath) {
                HStack(spacing: 8) {
                    Image(systemName: "cpu").frame(width: 18).foregroundStyle(.secondary)
                    Text(loc.t("Expertos MoE en CPU: \(ncmoe)", "MoE experts on CPU: \(ncmoe)")).font(.callout)
                    Spacer(minLength: 8)
                    Stepper("", value: Binding(get: { ncmoe }, set: { v in
                        ncmoe = v
                        ServerSettings.rememberNcmoe(v, forModel: modelPath)
                    }), in: 0...99)
                        .labelsHidden()
                        .disabled(server.state == .running || server.state == .starting)
                }
                .help(loc.t("Capas MoE cuyos expertos corren en CPU (RAM). Súbelo si la VRAM se satura, bájalo si te sobra. Se aplica al reiniciar el servidor.",
                            "MoE layers whose experts run on the CPU (RAM). Raise it if VRAM saturates, lower it if you have headroom. Applies when the server restarts."))
            }
            if !modelPath.isEmpty && !routerMode {
                if ncmoe > 0 && ServerSettings.modelIsMoE(at: modelPath) {
                    row("gauge.with.needle", loc.t("Límite: ancho de banda de RAM",
                                                   "Limit: RAM bandwidth"))
                        .help(loc.t("Los expertos en CPU se leen desde la RAM en cada token, y eso marca la velocidad de generación: una GPU más potente no la mejora, RAM más rápida (DDR5) sí. La aceleración MTP y bajar ncmoe reducen esas lecturas.",
                                    "CPU experts are read from RAM on every token, and that sets generation speed: a stronger GPU won't raise it, faster RAM (DDR5) will. MTP acceleration and a lower ncmoe reduce those reads."))
                } else {
                    row("gauge.with.needle", loc.t("Límite: ancho de banda de VRAM",
                                                   "Limit: VRAM bandwidth"))
                        .help(loc.t("Con el modelo completo en la GPU, cada token relee los pesos desde la VRAM: la velocidad de generación depende del ancho de banda de la tarjeta y del tamaño del archivo (una cuantización menor genera más rápido).",
                                    "With the whole model on the GPU, every token re-reads the weights from VRAM: generation speed depends on the card's bandwidth and the file size (a smaller quantization generates faster)."))
                }
            }
            row("number", loc.t("Peticiones: \(server.requestCount)", "Requests: \(server.requestCount)"))

            // Quick access to the two settings most often changed when sharing the
            // server. Locked while running — they apply on the next start. Same row
            // layout as above (18-pt icon column) so everything lines up.
            let serverBusy = server.state == .running || server.state == .starting
            // Shown on hover only while running, so the section never grows/shrinks
            // (no layout jump) when the server starts or stops.
            let restartNote = serverBusy
                ? loc.t(" Se aplica al reiniciar el servidor.", " Applies when the server restarts.")
                : ""
            Divider().padding(.vertical, 3)
            HStack(spacing: 8) {
                Image(systemName: "number.square").frame(width: 18).foregroundStyle(.secondary)
                Text(loc.t("Puerto", "Port")).font(.callout)
                Spacer(minLength: 8)
                TextField("", value: $port, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing).frame(width: 72)
                    .textFieldStyle(.roundedBorder)
                    .disabled(serverBusy)
            }
            .help(loc.t("Puerto local del servidor (API y chat web).",
                        "Local server port (API and web chat).") + restartNote)
            HStack(spacing: 8) {
                Image(systemName: "wifi").frame(width: 18).foregroundStyle(.secondary)
                Text(loc.t("Descubrible en red local", "Discoverable on local network")).font(.callout)
                // Inline ⓘ (no extra row → no vertical jump). Styled, reliable popover.
                if localNetworkDiscovery && !apiKeyEnabled {
                    InfoTip(text: loc.t("Recomendado: protege la API con clave antes de exponerla en la red local.",
                                        "Recommended: protect the API with a key before exposing it on the local network."))
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { localNetworkDiscovery }, set: setDiscoverable))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            .help(loc.t("Hace que el servidor escuche en la red local y lo anuncia con Bonjour. Reinicia el servidor si está activo.",
                        "Makes the server listen on the local network and advertises it via Bonjour. Restarts the server if it's running."))
            // Vision-capable models: the mmproj menu is the single control —
            // pick a projector, auto-pair, or "No vision" to run text-only.
            if ServerSettings.mightSupportVision(modelPath: modelPath) {
                HStack(spacing: 8) {
                    Image(systemName: "photo").frame(width: 18).foregroundStyle(.secondary)
                    Text(loc.t("Visión", "Vision")).font(.callout)
                    Spacer(minLength: 8)
                    VisionProjectorControl(modelPath: modelPath)
                }
                .help(loc.t("Proyector de visión: elige un archivo, deja que se empareje solo, o 'Sin visión' para correr solo texto y liberar la VRAM del codificador.",
                            "Vision projector: choose a file, let it auto-pair, or 'No vision' to run text-only and free the encoder's VRAM.") + restartNote)
            }
            if ServerSettings.dflashDraftPath(forModel: modelPath) != nil {
                HStack(spacing: 8) {
                    Image(systemName: "bolt").frame(width: 18).foregroundStyle(.secondary)
                    Text(loc.t("Aceleración DFlash", "DFlash acceleration")).font(.callout)
                    Spacer(minLength: 8)
                    DflashControl(modelPath: modelPath)
                }
            }
            SpecMetricsView(port: port)
            DisclosureGroup {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .frame(width: 18).foregroundStyle(.secondary)
                    Text(loc.t("Servidor de embeddings", "Embeddings server")).font(.callout)
                    Spacer(minLength: 8)
                    Toggle("", isOn: $embeddings)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(serverBusy)
                }
                .help(loc.t("Sirve /v1/embeddings con --embeddings para clientes RAG (p. ej. Obsidian Copilot). El servidor queda dedicado a embeddings: úsalo con un modelo de embeddings, no para chatear.",
                            "Serves /v1/embeddings via --embeddings for RAG clients (e.g. Obsidian Copilot). The server becomes embeddings-only: use it with an embedding model, not for chat."))
                .padding(.top, 4)
                HStack(spacing: 8) {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .frame(width: 18).foregroundStyle(.secondary)
                    Text(loc.t("Proxy MCP de la interfaz web", "MCP proxy for the web interface")).font(.callout)
                    Spacer(minLength: 8)
                    Toggle("", isOn: $uiMcpProxy)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(serverBusy)
                }
                .help(loc.t("Deja que la interfaz web del motor hable con servidores MCP de otro origen, haciendo de puente para saltar la restricción del navegador. Experimental y solo en redes de confianza: quien alcance este servidor puede usar el puente. No afecta al chat de la app, que habla con MCP por su cuenta.",
                            "Lets the engine's web interface talk to MCP servers on another origin, bridging the browser's cross-origin restriction. Experimental and for trusted networks only: anyone who can reach this server can use the bridge. It does not affect the app's own chat, which talks to MCP by itself."))
                .padding(.top, 4)
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath").frame(width: 18).foregroundStyle(.secondary)
                    Text(loc.t("Router (multi-modelo)", "Router (multi-model)")).font(.callout)
                    Spacer(minLength: 8)
                    Toggle("", isOn: $routerMode)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(serverBusy)
                }
                .help(loc.t("Un solo servidor sirve todos los modelos descargados: un cliente externo (VS Code, Continue…) o el chat interno eligen el modelo por petición y el servidor lo carga solo, sin reiniciar.",
                            "One server serves every downloaded model: an external client (VS Code, Continue…) or the built-in chat picks the model per request and the server loads it on demand, no restart."))
                .padding(.top, 4)
                if routerMode {
                    HStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up").frame(width: 18).foregroundStyle(.secondary)
                        Text(loc.t("Modelos simultáneos", "Models loaded at once")).font(.callout)
                        Spacer(minLength: 8)
                        Stepper("\(routerModelsMax)", value: $routerModelsMax, in: 1...4)
                            .fixedSize()
                            .disabled(serverBusy)
                    }
                    .help(loc.t("Cuántos modelos mantiene cargados el router a la vez; el resto se descarga solo (LRU). 1 es lo más seguro con una sola GPU.",
                                "How many models the router keeps loaded at once; the rest unload automatically (LRU). 1 is safest on a single GPU."))
                    .padding(.top, 4)
                }
            } label: {
                Text(loc.t("Opciones avanzadas", "Advanced options"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                ServerStateBadge(state: server.state)
                Spacer()
                if server.state == .running {
                    Button { NSWorkspace.shared.open(server.webChatURL) } label: {
                        Image(systemName: "safari")
                    }
                    .iconHelp(loc.t("Abrir en el navegador", "Open in browser"))
                }
                if server.state == .running || server.state == .starting {
                    Button(role: .destructive) { server.stop() } label: {
                        Label(loc.t("Detener", "Stop"), systemImage: "stop.fill")
                    }
                } else {
                    Button { server.start(.fromDefaults()) } label: {
                        Label(loc.t("Iniciar servidor", "Start server"), systemImage: "play.fill")
                    }
                    .disabled(routerMode ? models.models.isEmpty : modelPath.isEmpty)
                }
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var recommendationCard: some View {
        let recs = Catalog.recommendations(for: hardware)
        if !recs.isEmpty {
            Card(title: loc.t("Recomendado para tu equipo", "Recommended for your machine"),
                 icon: "star.fill") {
                Text(loc.t("Tu equipo corre bien varios modelos; elige según lo que necesites.",
                           "Your machine runs several models well — pick by what you need."))
                    .font(.caption).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(recs.enumerated()), id: \.element.id) { idx, rec in
                        if idx > 0 { Divider().padding(.vertical, 9) }
                        recommendationRow(rec)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func recommendationRow(_ rec: Catalog.Recommendation) -> some View {
        let style = roleStyle(rec.role)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Label(style.text, systemImage: style.icon)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(style.color.opacity(0.18), in: Capsule())
                        .foregroundStyle(style.color)
                        .fixedSize()
                    Text(ModelName(rec.model.name).title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(String(format: "%.1f GB", rec.model.spec.fileGB))
                        .font(.caption2).foregroundStyle(.secondary)
                    if rec.model.spec.isMoE { MoEBadge() }
                }
                Text(rec.model.detail(loc.isSpanish))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                EstimateLine(est: rec.est)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CatalogActionButton(model: rec.model, est: rec.est)
                .fixedSize()
        }
    }

    private func roleStyle(_ role: Catalog.Recommendation.Role) -> (text: String, icon: String, color: Color) {
        switch role {
        case .fast:     return (loc.t("Más rápido", "Fastest"), "hare.fill", .green)
        case .balanced: return (loc.t("Equilibrado", "Balanced"), "scalemass.fill", .blue)
        case .quality:  return (loc.t("Máxima calidad", "Top quality"), "sparkles", .purple)
        case .coding:   return (loc.t("Programación", "Coding"), "chevron.left.forwardslash.chevron.right", .orange)
        }
    }

    private func row(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
            Text(text).font(.callout).lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

/// Its own view so the 3s device poll it watches re-renders only this card. The GPU
/// list can grow after launch: macOS wakes the cards one by one.
struct MachineCard: View {
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var vram: VRAMMonitor
    @State private var machine = hardware
    @State private var showGPUDetail = false

    var body: some View {
        Card(title: loc.t("Tu equipo", "Your machine"), icon: "desktopcomputer", fill: true) {
            row("cpu", machine.cpuBrand
                .replacingOccurrences(of: "(R)", with: "")
                .replacingOccurrences(of: "(TM)", with: ""))
            row("square.grid.3x3",
                loc.t("\(machine.physicalCores) núcleos / \(machine.logicalCores) hilos",
                      "\(machine.physicalCores) cores / \(machine.logicalCores) threads"))
            row("memorychip", String(format: "%.0f GB RAM", machine.ramGB))
            if machine.splitEligibleGPUs.count > 1 {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.on.rectangle")
                        .frame(width: 18).foregroundStyle(.secondary)
                    Text(gpuCountSummary).font(.callout).lineLimit(1)
                    Spacer(minLength: 8)
                    Button(loc.t("Detalle", "Details")) { showGPUDetail.toggle() }
                        .buttonStyle(.plain).font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .popover(isPresented: $showGPUDetail, arrowEdge: .bottom) { gpuDetailPopover }
                }
                .help(gpuListTooltip)
                row("link", peerLinkSummary)
                    .help(loc.t("Las GPUs unidas por un enlace Infinity Fabric comparten un grupo de pares en Metal, y solo así pueden copiarse activaciones directamente en vez de pasar por la RAM. La memoria del grupo es la que un modelo repartido recorre sin pasar por el sistema. macOS no lo muestra en ningún sitio: si el puente no está o no funciona, cada tarjeta aparece en su propio grupo.",
                            "GPUs joined by an Infinity Fabric link share a Metal peer group, which is what lets them copy activations directly instead of going through system RAM. The memory of a group is what a split model reaches without going through the system. macOS shows this nowhere: if the bridge is missing or not working, each card ends up in its own group."))
            } else if let gpu = machine.bestGPU {
                row("rectangle.on.rectangle", "\(gpu.name) · \(gpu.vramGB) GB VRAM")
            }
            if !machine.model.isEmpty { row("desktopcomputer", machine.model) }
            if !machine.osVersion.isEmpty { row("apple.logo", machine.osVersion) }
            row("bolt.fill", ServerSettings.isAppleSilicon
                ? loc.t("Backend: Metal (Apple Silicon)", "Backend: Metal (Apple Silicon)")
                : loc.t("Backend: Metal (build AMD parcheado)", "Backend: Metal (patched AMD build)"))
        }
        .onChange(of: vram.gpus.count) { _, _ in
            machine.gpus = ServerController.availableGPUs()
        }
    }

    private var gpuModelRows: [String] {
        HardwareInfo.modelGroups(of: machine.splitEligibleGPUs).map { g in
            let head = g.cards == 1 ? g.name : "\(g.cards) × \(g.name)"
            // A Duo is one card with two GPUs, so the card count alone hides half of them.
            let dies = g.gpus == g.cards ? "" : " · \(g.gpus) GPUs"
            if g.cards == 1 && g.gpus == 1 { return "\(head) · \(g.vramGB) GB" }
            return loc.t("\(head)\(dies) · \(g.vramGB) GB c/u",
                         "\(head)\(dies) · \(g.vramGB) GB each")
        }
    }

    /// Summed from the rounded per-card figures so the panel adds up on screen.
    private var gpuCountSummary: String {
        let gpus = machine.splitEligibleGPUs
        let total = gpus.reduce(0) { $0 + $1.vramGB }
        return loc.t("\(gpus.count) GPUs · \(total) GB de VRAM", "\(gpus.count) GPUs · \(total) GB VRAM")
    }

    private var gpuDetailPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc.t("GPUs detectadas", "Detected GPUs")).font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(gpuModelRows, id: \.self) { Text($0).font(.callout) }
            }
            if !machine.peerGroups.isEmpty {
                Divider()
                Text(loc.t("Enlaces Infinity Fabric", "Infinity Fabric links")).font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(peerLinkRows, id: \.self) { Text($0).font(.callout) }
                }
            }
            Divider()
            Text(loc.t("Memoria según la reporta Metal, que no tiene por qué ser la nominal de la caja. Solo se suma cuando repartes un modelo entre varias GPUs; uno que no reparta debe caber en una sola.",
                       "Memory as Metal reports it, which need not match the number on the box. It only adds up when you split a model across several GPUs; one that is not split has to fit in a single card."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
    }

    private var gpuListTooltip: String {
        let list = machine.gpus
            .map { "\($0.name) · \($0.vramGB) GB\($0.isExternal ? " · eGPU" : "")" }
            .joined(separator: "\n")
        return loc.t("VRAM que reporta Metal, no la nominal de la caja. Solo se suma cuando repartes un modelo entre varias GPUs; un modelo que no reparta debe caber en una sola.\n\n\(list)",
                     "VRAM as Metal reports it, not the number on the box. It only adds up when you split a model across several GPUs; a model that is not split has to fit in one.\n\n\(list)")
    }

    /// The memory behind a link is what a split model moves without touching RAM.
    private var peerLinkSummary: String {
        let groups = machine.peerGroups
        guard !groups.isEmpty else {
            return loc.t("Infinity Fabric: sin enlace entre tarjetas",
                         "Infinity Fabric: no link between cards")
        }
        if let only = groups.first, groups.count == 1 {
            let total = only.reduce(0) { $0 + $1.vramGB }
            return loc.t("Infinity Fabric: \(only.count) GPUs enlazadas · \(total) GB",
                         "Infinity Fabric: \(only.count) GPUs linked · \(total) GB")
        }
        let totals = groups.map { String($0.reduce(0) { $0 + $1.vramGB }) }.joined(separator: " + ")
        return loc.t("Infinity Fabric: \(groups.count) enlaces · \(totals) GB",
                     "Infinity Fabric: \(groups.count) links · \(totals) GB")
    }

    private var peerLinkRows: [String] {
        let groups = machine.peerGroups
        guard !groups.isEmpty else {
            return [loc.t("Infinity Fabric: sin enlace entre tarjetas",
                          "Infinity Fabric: no link between cards")]
        }
        let labels = GPUPeerTopology.labels(machine.gpus.map { ($0.index, $0.peerGroupID) })
        return groups.map { members in
            let total = members.reduce(0) { $0 + $1.vramGB }
            let prefix = groups.count == 1
                ? "Infinity Fabric"
                : "Fabric " + (labels[members[0].peerGroupID] ?? "?")
            let names = Set(members.map(\.name))
            let what = names.count == 1
                ? "\(members.count) × \(members[0].name)"
                : loc.t("\(members.count) GPUs", "\(members.count) GPUs")
            return "\(prefix): \(what) · \(total) GB"
        }
    }


    private func row(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
            Text(text).font(.callout).lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

/// Per-GPU VRAM bars. Owns the 3s-polling monitor so its ticks re-render only this card.
struct GPUsCard: View {
    @EnvironmentObject var vram: VRAMMonitor
    @EnvironmentObject var loc: Localizer

    var body: some View {
        Card(title: loc.t("GPUs", "GPUs"), icon: "rectangle.on.rectangle", fill: true) {
            if vram.gpus.isEmpty {
                Label(loc.t("Sin datos de uso de GPU", "No GPU usage data"),
                      systemImage: "rectangle.on.rectangle")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(vram.gpus) { gpuRow($0) }
            }
        }
    }

    private var peerLabels: [UInt64: String] {
        GPUPeerTopology.labels(vram.gpus.map { ($0.id, $0.peerGroupID) })
    }

    @ViewBuilder private func gpuRow(_ g: GPUStat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if vram.gpus.count > 1 {
                    Text("#\(g.id)")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
                Text(g.name).font(.callout).lineLimit(1)
                peerBadge(for: g)
                Spacer(minLength: 8)
                Text(String(format: "%.1f / %.0f GB", g.usedMB / 1024, g.totalMB / 1024))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            ProgressView(value: g.fraction)
                .tint(g.fraction > 0.9 ? .red : g.fraction > 0.75 ? .orange : .accentColor)
        }
        .padding(.leading, peerColors.isEmpty ? 0 : 11)
        // As an overlay the bar takes the height of the row; a Shape in the row
        // itself has no height of its own and stretches it instead.
        .overlay(alignment: .leading) {
            if let color = peerColors[g.peerGroupID] {
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3)
            }
        }
        .help(rowTooltip(g))
    }

    private var peerColors: [UInt64: Color] {
        let palette: [Color] = [.accentColor, .teal, .orange, .purple, .pink]
        let ids = GPUPeerTopology.groupIDs(vram.gpus.map { ($0.id, $0.peerGroupID) })
        return ids.enumerated().reduce(into: [:]) { out, pair in
            out[pair.element] = palette[pair.offset % palette.count]
        }
    }

    @ViewBuilder private func peerBadge(for g: GPUStat) -> some View {
        let labels = peerLabels
        // Nothing on unlinked cards: the row tooltip spells that out.
        if let label = labels[g.peerGroupID] {
            capsule(labels.count > 1 ? "Fabric \(label)" : "Fabric",
                    icon: "link", tint: peerColors[g.peerGroupID] ?? .accentColor)
        }
    }

    private func capsule(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8, weight: .semibold))
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(tint.opacity(0.14), in: Capsule())
    }

    private func rowTooltip(_ g: GPUStat) -> String {
        let vramUse = loc.t("VRAM en uso de \(g.name).", "VRAM in use on \(g.name).")
        let labels = peerLabels
        guard !labels.isEmpty else { return vramUse }
        guard let label = labels[g.peerGroupID] else {
            return vramUse + loc.t(" Sin enlace Infinity Fabric: sus copias pasan por la RAM del sistema.",
                                   " No Infinity Fabric link: its copies go through system RAM.")
        }
        let peers = vram.gpus.filter { $0.peerGroupID == g.peerGroupID }.count
        return vramUse + loc.t(" Enlazada por Infinity Fabric con otras \(peers - 1) GPUs (grupo \(label)), así que se copian activaciones entre ellas sin pasar por la RAM.",
                               " Linked by Infinity Fabric to \(peers - 1) other GPUs (group \(label)), so they copy activations between themselves without going through RAM.")
    }
}

/// Aggregate-VRAM badge for window toolbars, so it's visible outside the dashboard.
struct GPUUsageBadge: View {
    @EnvironmentObject var vram: VRAMMonitor
    @EnvironmentObject var loc: Localizer

    var body: some View {
        if vram.totalMB > 0 {
            HStack(spacing: 5) {
                Image(systemName: "memorychip").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: min(vram.fraction, 1)).frame(width: 52)
                    .tint(vram.fraction > 0.9 ? .red : vram.fraction > 0.75 ? .orange : .accentColor)
                Text(String(format: "%.1f/%.0f", vram.usedMB / 1024, vram.totalMB / 1024))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            .help(loc.t("VRAM en uso (todas las GPUs).", "VRAM in use (all GPUs)."))
        }
    }
}

/// Compact server state indicator, shared by the main and the added server cards.
struct ServerStateBadge: View {
    let state: ServerController.State
    @EnvironmentObject var loc: Localizer
    var body: some View {
        switch state {
        case .running:
            Label(loc.t("Activo", "Running"), systemImage: "circle.fill")
                .foregroundStyle(.green).font(.caption)
        case .starting:
            Label(loc.t("Iniciando…", "Starting…"), systemImage: "circle.fill")
                .foregroundStyle(.orange).font(.caption)
        case .failed(let msg):
            Label(loc.t("Error", "Error"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.caption)
                .help(loc.half(msg))
        case .stopped:
            Label(loc.t("Detenido", "Stopped"), systemImage: "circle")
                .foregroundStyle(.secondary).font(.caption)
        }
    }
}

/// One extra independent server: its own model, GPU, port, profile and toggles.
/// Observes the controller directly so its state (running/stopped) drives the card.
struct AddedServerCard: View {
    @ObservedObject var c: ServerController
    @EnvironmentObject var manager: ServerManager
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var profileStore: ProfileStore
    // Live global values, shown (and launched with) wherever this server has not
    // pinned its own; observing them keeps the card in sync with Settings edits.
    @AppStorage(SettingsKeys.modelPath) private var gModelPath = ""
    @AppStorage(SettingsKeys.ncmoe) private var gNcmoe = 0
    @AppStorage(SettingsKeys.ctx) private var gCtx = 16384
    @AppStorage(SettingsKeys.gpuIndex) private var gGpuIndex = -1
    @AppStorage(SettingsKeys.gpuList) private var gGpuListCSV = ""
    @AppStorage(SettingsKeys.localNetworkDiscovery) private var gDiscovery = false
    @AppStorage(SettingsKeys.loadVision) private var gLoadVision = true
    @AppStorage(SettingsKeys.embeddings) private var gEmbeddings = false
    @AppStorage(SettingsKeys.uiMcpProxy) private var gUiMcpProxy = false
    @AppStorage(SettingsKeys.routerMode) private var gRouterMode = false
    @AppStorage(SettingsKeys.routerModelsMax) private var gRouterModelsMax = 1

    var body: some View {
        let busy = c.state == .running || c.state == .starting
        let modelPath = isPinned(Profile.Pin.model) ? (c.profile?.modelPath ?? "") : gModelPath
        let routerMode = isPinned(Profile.Pin.router) ? (c.profile?.routerMode ?? false) : gRouterMode
        Card(title: c.name, icon: "server.rack", fill: true, trailing: { accessory }) {
            if routerMode {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox.and.arrow.backward").frame(width: 18).foregroundStyle(.secondary)
                    Text(loc.t("Router: sirve los \(models.models.count) modelos descargados",
                               "Router: serves all \(models.models.count) downloaded models"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox").frame(width: 18).foregroundStyle(.secondary)
                    // Same ncmoe seeding as the primary server's picker.
                    Picker("", selection: Binding(get: { modelPath }, set: { p in
                        c.profile?.modelPath = p
                        c.profile?.ncmoe = Estimator.ncmoeForSelection(path: p, models: models.models)
                        pin(Profile.Pin.model)
                        manager.persist()
                    })) {
                        Text(loc.t("Sin modelo", "No model")).tag("")
                        ForEach(models.models) {
                            Text(ModelName.forPath($0.url.path).display
                                 + (ModelTraitsCache.cached(for: $0.url.path)?
                                        .pickerSuffix(spanish: loc.isSpanish) ?? ""))
                                .tag($0.url.path)
                        }
                    }
                    .labelsHidden().disabled(busy)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "cpu").frame(width: 18).foregroundStyle(.secondary)
                // Pinning one GPU field seeds the sibling from the shown (global)
                // value, so the pin captures exactly what the user was looking at.
                GPUSelectionMenu(gpuIndex: Binding(
                    get: { isPinned(Profile.Pin.gpu) ? (c.profile?.gpuIndex ?? -1) : gGpuIndex },
                    set: {
                        if !isPinned(Profile.Pin.gpu) { c.profile?.gpuList = ServerSettings.gpuList(fromCSV: gGpuListCSV) }
                        c.profile?.gpuIndex = $0; pin(Profile.Pin.gpu); manager.persist()
                    }), gpuList: Binding(
                    get: { isPinned(Profile.Pin.gpu) ? (c.profile?.gpuList ?? []) : ServerSettings.gpuList(fromCSV: gGpuListCSV) },
                    set: {
                        if !isPinned(Profile.Pin.gpu) { c.profile?.gpuIndex = gGpuIndex }
                        c.profile?.gpuList = $0; pin(Profile.Pin.gpu); manager.persist()
                    }))
                    .disabled(busy)
            }
            if ServerSettings.modelIsMoE(at: modelPath) {
                let moePinned = isPinned(Profile.Pin.moe) || isPinned(Profile.Pin.model)
                let moeValue = moePinned ? (c.profile?.ncmoe ?? gNcmoe) : gNcmoe
                HStack(spacing: 8) {
                    Image(systemName: "cpu").frame(width: 18).foregroundStyle(.secondary)
                    Text(loc.t("Expertos MoE en CPU: \(moeValue)", "MoE experts on CPU: \(moeValue)")).font(.callout)
                    Spacer(minLength: 8)
                    Stepper("", value: Binding(
                        get: { moeValue },
                        set: { c.profile?.ncmoe = $0; pin(Profile.Pin.moe); manager.persist() }),
                        in: 0...99)
                        .labelsHidden().disabled(busy)
                }
                .help(loc.t("Capas MoE cuyos expertos corren en CPU (RAM). Hereda el de Ajustes hasta que lo cambies aquí.",
                            "MoE layers whose experts run on the CPU (RAM). Follows Settings until you change it here."))
            }
            HStack(spacing: 8) {
                Image(systemName: "number.square").frame(width: 18).foregroundStyle(.secondary)
                Text(loc.t("Puerto", "Port")).font(.callout)
                Spacer(minLength: 8)
                TextField("", value: bind(\.port, 8080), format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing).frame(width: 72)
                    .textFieldStyle(.roundedBorder).disabled(busy)
            }
            HStack(spacing: 8) {
                Image(systemName: "doc.plaintext").frame(width: 18).foregroundStyle(.secondary)
                Text(loc.t("Contexto", "Context")).font(.callout)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { isPinned(Profile.Pin.ctx) ? (c.profile?.ctx ?? gCtx) : gCtx },
                    set: { c.profile?.ctx = $0; pin(Profile.Pin.ctx); manager.persist() })) {
                    ForEach([4096, 8192, 16384, 32768, 65536, 131072, 262144], id: \.self) { n in
                        Text("\(n / 1024)k").tag(n)
                    }
                }
                .labelsHidden().fixedSize().disabled(busy)
            }
            .help(loc.t("Contexto máximo de este servidor. Hereda el de Ajustes hasta que lo cambies aquí.",
                        "This server's maximum context. Follows Settings until you change it here."))
            HStack(spacing: 8) {
                Image(systemName: "wifi").frame(width: 18).foregroundStyle(.secondary)
                Text(loc.t("Descubrible en red local", "Discoverable on local network")).font(.callout)
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { isPinned(Profile.Pin.discovery) ? (c.profile?.localNetworkDiscovery ?? false) : gDiscovery },
                    set: { c.profile?.localNetworkDiscovery = $0; pin(Profile.Pin.discovery); manager.persist() }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(busy)
            }
            if ServerSettings.mmprojPath(forModel: modelPath) != nil {
                HStack(spacing: 8) {
                    Image(systemName: "photo").frame(width: 18).foregroundStyle(.secondary)
                    Text(loc.t("Visión", "Vision")).font(.callout)
                    Spacer(minLength: 8)
                    let on = isPinned(Profile.Pin.vision) ? (c.profile?.loadVision ?? true) : gLoadVision
                    Button {
                        c.profile?.loadVision = !on
                        pin(Profile.Pin.vision)
                        manager.persist()
                    } label: {
                        Image(systemName: on ? "eye.fill" : "eye.slash")
                            .imageScale(.large).foregroundStyle(on ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain).disabled(busy)
                    .iconHelp(on ? loc.t("Desactivar la visión", "Turn vision off")
                                 : loc.t("Activar la visión", "Turn vision on"))
                }
            }
            DisclosureGroup {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .frame(width: 18).foregroundStyle(.secondary)
                    Text(loc.t("Servidor de embeddings", "Embeddings server")).font(.callout)
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(
                        get: { isPinned(Profile.Pin.embeddings) ? (c.profile?.embeddings ?? false) : gEmbeddings },
                        set: { c.profile?.embeddings = $0; pin(Profile.Pin.embeddings); manager.persist() }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(busy)
                }
                .help(loc.t("Sirve /v1/embeddings con --embeddings para clientes RAG (p. ej. Obsidian Copilot). El servidor queda dedicado a embeddings: úsalo con un modelo de embeddings, no para chatear.",
                            "Serves /v1/embeddings via --embeddings for RAG clients (e.g. Obsidian Copilot). The server becomes embeddings-only: use it with an embedding model, not for chat."))
                .padding(.top, 4)
                HStack(spacing: 8) {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .frame(width: 18).foregroundStyle(.secondary)
                    Text(loc.t("Proxy MCP de la interfaz web", "MCP proxy for the web interface")).font(.callout)
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(
                        get: { isPinned(Profile.Pin.uiMcpProxy) ? (c.profile?.uiMcpProxy ?? false) : gUiMcpProxy },
                        set: { c.profile?.uiMcpProxy = $0; pin(Profile.Pin.uiMcpProxy); manager.persist() }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(busy)
                }
                .help(loc.t("Deja que la interfaz web del motor hable con servidores MCP de otro origen, haciendo de puente para saltar la restricción del navegador. Experimental y solo en redes de confianza: quien alcance este servidor puede usar el puente. No afecta al chat de la app, que habla con MCP por su cuenta.",
                            "Lets the engine's web interface talk to MCP servers on another origin, bridging the browser's cross-origin restriction. Experimental and for trusted networks only: anyone who can reach this server can use the bridge. It does not affect the app's own chat, which talks to MCP by itself."))
                .padding(.top, 4)
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath").frame(width: 18).foregroundStyle(.secondary)
                    Text(loc.t("Router (multi-modelo)", "Router (multi-model)")).font(.callout)
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(
                        get: { routerMode },
                        set: {
                            if !isPinned(Profile.Pin.router) { c.profile?.routerModelsMax = gRouterModelsMax }
                            c.profile?.routerMode = $0; pin(Profile.Pin.router); manager.persist()
                        }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(busy)
                }
                .help(loc.t("Un solo servidor sirve todos los modelos descargados: el modelo se elige por petición y se carga solo, sin reiniciar.",
                            "One server serves every downloaded model: the model is picked per request and loads on demand, no restart."))
                .padding(.top, 4)
                if routerMode {
                    let routerMax = isPinned(Profile.Pin.router) ? (c.profile?.routerModelsMax ?? 1) : gRouterModelsMax
                    HStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up").frame(width: 18).foregroundStyle(.secondary)
                        Text(loc.t("Modelos simultáneos", "Models loaded at once")).font(.callout)
                        Spacer(minLength: 8)
                        Stepper("\(routerMax)", value: Binding(
                            get: { routerMax },
                            set: {
                                if !isPinned(Profile.Pin.router) { c.profile?.routerMode = gRouterMode }
                                c.profile?.routerModelsMax = $0; pin(Profile.Pin.router); manager.persist()
                            }), in: 1...4)
                            .fixedSize().disabled(busy)
                    }
                    .padding(.top, 4)
                }
            } label: {
                Text(loc.t("Opciones avanzadas", "Advanced options"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                ServerStateBadge(state: c.state)
                Spacer()
                if busy {
                    Button(role: .destructive) { c.stop() } label: {
                        Label(loc.t("Detener", "Stop"), systemImage: "stop.fill")
                    }
                } else {
                    Button { c.start(c.effectiveSettings()) } label: {
                        Label(loc.t("Iniciar", "Start"), systemImage: "play.fill")
                    }
                    .disabled(modelPath.isEmpty)
                }
            }
        }
    }

    private var accessory: some View {
        HStack(spacing: 10) {
            if !profileStore.profiles.isEmpty {
                Menu {
                    ForEach(profileStore.profiles) { p in
                        Button(p.name) { applyProfile(p) }
                    }
                } label: {
                    Label(loc.t("Perfil", "Profile"), systemImage: "person.2.fill").font(.caption)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help(loc.t("Carga un perfil guardado en este servidor.",
                            "Loads a saved profile into this server."))
            }
            if c.profile?.pinned?.isEmpty != true {
                Button { c.profile?.pinned = []; manager.persist() } label: {
                    Image(systemName: "pin.slash").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(loc.t("Vuelve a heredar todos los ajustes globales (conserva nombre y puerto).",
                            "Inherits every global setting again (keeps name and port)."))
            }
            Button { manager.removeServer(c.id) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .iconHelp(loc.t("Eliminar este servidor.", "Remove this server."))
        }
    }

    /// Loads a saved profile into this server, keeping its own name and port.
    private func applyProfile(_ p: Profile) {
        var np = p
        np.name = c.name
        np.port = c.profile?.port ?? p.port
        c.profile = np
        manager.persist()
    }

    private func bind<T>(_ kp: WritableKeyPath<Profile, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { c.profile?[keyPath: kp] ?? fallback },
                set: { c.profile?[keyPath: kp] = $0; manager.persist() })
    }

    /// nil pinned = pre-0.83 server: full snapshot, every field its own.
    private func isPinned(_ key: String) -> Bool {
        guard let pinned = c.profile?.pinned else { return true }
        return pinned.contains(key)
    }

    private func pin(_ key: String) {
        guard var pinned = c.profile?.pinned, !pinned.contains(key) else { return }
        pinned.append(key)
        c.profile?.pinned = pinned
    }
}

struct Card<Content: View, Trailing: View>: View {
    let title: String
    let icon: String
    /// When true the card stretches to fill the tallest sibling in its row, so
    /// side-by-side cards line up even with different amounts of content.
    var fill: Bool = false
    /// Accessory pinned to the top-right of the title row (e.g. a profile picker
    /// or a "clear" action). Generic rather than AnyView so the accessory keeps
    /// its identity across updates.
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    init(title: String, icon: String, fill: Bool = false,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.fill = fill
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                if Trailing.self != EmptyView.self {
                    Spacer(minLength: 8)
                    trailing
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Tactile press feedback for plain/glass buttons that otherwise show none.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
