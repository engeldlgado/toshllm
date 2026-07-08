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
    @AppStorage(SettingsKeys.loadVision) private var loadVision = true
    @AppStorage(SettingsKeys.gpuIndex) private var gpuIndex = -1
    @AppStorage(SettingsKeys.gpuList) private var gpuListCSV = ""
    @AppStorage(SettingsKeys.embeddings) private var embeddings = false
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
                        hardwareCard
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
                        if let url = updates.releaseURL { NSWorkspace.shared.open(url) }
                    }
                    .help(loc.t("Abre las notas de la versión en GitHub.",
                                "Opens the release notes on GitHub."))
                    Button(loc.t("Descargar e instalar", "Download and install")) {
                        Task { await updates.downloadAndInstall() }
                    }
                    .buttonStyle(.borderedProminent)
                    .help(loc.t("Descarga el DMG, verifica su checksum, instala la nueva versión en Aplicaciones y reinicia la app.",
                                "Downloads the DMG, verifies its checksum, installs the new version into Applications and relaunches the app."))
                }
            }
            .padding(12)
            .background(.pink.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var hardwareCard: some View {
        Card(title: loc.t("Tu equipo", "Your machine"), icon: "desktopcomputer", fill: true) {
            row("cpu", hardware.cpuBrand
                .replacingOccurrences(of: "(R)", with: "")
                .replacingOccurrences(of: "(TM)", with: ""))
            row("square.grid.3x3",
                loc.t("\(hardware.physicalCores) núcleos / \(hardware.logicalCores) hilos",
                      "\(hardware.physicalCores) cores / \(hardware.logicalCores) threads"))
            row("memorychip", String(format: "%.0f GB RAM", hardware.ramGB))
            if let gpu = hardware.bestGPU {
                row("rectangle.on.rectangle", "\(gpu.name) · \(gpu.vramMB / 1024) GB VRAM")
            }
            if !hardware.model.isEmpty { row("desktopcomputer", hardware.model) }
            if !hardware.osVersion.isEmpty { row("apple.logo", hardware.osVersion) }
            row("bolt.fill", ServerSettings.isAppleSilicon
                ? loc.t("Backend: Metal (Apple Silicon)", "Backend: Metal (Apple Silicon)")
                : loc.t("Backend: Metal (build AMD parcheado)", "Backend: Metal (patched AMD build)"))
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
            .background(.pink.opacity(0.15), in: Capsule())
            .foregroundStyle(.pink)
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
                .glassSurface(in: Capsule(), tint: .pink)
                .contentShape(Capsule())
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        }
        .buttonStyle(PressableButtonStyle())
        .help(loc.t("Crea otro servidor independiente, con su propia GPU, modelo y puerto.",
                    "Creates another independent server with its own GPU, model and port."))
    }

    private var serverCard: some View {
        Card(title: loc.t("Servidor", "Server"), icon: "server.rack", fill: true,
             trailing: profileStore.profiles.isEmpty ? nil : AnyView(profileMenu)) {
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
                        ForEach(models.models) { Text($0.name).tag($0.url.path) }
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
            if ncmoe > 0 && ServerSettings.modelIsMoE(at: modelPath) {
                row("cpu", loc.t("Expertos MoE en CPU: \(ncmoe) capas",
                                 "MoE experts on CPU: \(ncmoe) layers"))
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
            // Only for vision-capable models: let the user run text-only to save VRAM.
            // The eye is colored when vision loads, dimmed when the model runs text-only.
            if ServerSettings.mmprojPath(forModel: modelPath) != nil {
                HStack(spacing: 8) {
                    Image(systemName: "photo").frame(width: 18).foregroundStyle(.secondary)
                    Text(loc.t("Visión", "Vision")).font(.callout)
                    Spacer(minLength: 8)
                    Button { loadVision.toggle() } label: {
                        Image(systemName: loadVision ? "eye.fill" : "eye.slash")
                            .imageScale(.large)
                            .foregroundStyle(loadVision ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(serverBusy)
                }
                .help(loc.t("Ojo encendido: carga el proyector para leer imágenes. Apagado: solo texto, libera la VRAM del codificador de imágenes.",
                            "Eye on: loads the projector so the model can read images. Off: text-only, frees the image encoder's VRAM.") + restartNote)
            }
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
                    .help(loc.t("Abrir en el navegador", "Open in browser"))
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
                    Text(rec.model.name).font(.subheadline.weight(.semibold)).lineLimit(1)
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

    @ViewBuilder private func gpuRow(_ g: GPUStat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(g.name).font(.callout).lineLimit(1)
                Spacer(minLength: 8)
                Text(String(format: "%.1f / %.0f GB", g.usedMB / 1024, g.totalMB / 1024))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            ProgressView(value: g.fraction)
                .tint(g.fraction > 0.9 ? .red : g.fraction > 0.75 ? .orange : .accentColor)
        }
        .help(loc.t("VRAM en uso de \(g.name).", "VRAM in use on \(g.name)."))
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
        case .failed:
            Label(loc.t("Error", "Error"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.caption)
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

    var body: some View {
        let busy = c.state == .running || c.state == .starting
        let modelPath = c.profile?.modelPath ?? ""
        let routerMode = c.profile?.routerMode ?? false
        Card(title: c.name, icon: "server.rack", fill: true, trailing: AnyView(accessory)) {
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
                    Picker("", selection: Binding(get: { c.profile?.modelPath ?? "" }, set: { p in
                        c.profile?.modelPath = p
                        c.profile?.ncmoe = Estimator.ncmoeForSelection(path: p, models: models.models)
                        manager.persist()
                    })) {
                        Text(loc.t("Sin modelo", "No model")).tag("")
                        ForEach(models.models) { Text($0.name).tag($0.url.path) }
                    }
                    .labelsHidden().disabled(busy)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "cpu").frame(width: 18).foregroundStyle(.secondary)
                GPUSelectionMenu(gpuIndex: bind(\.gpuIndex, -1), gpuList: Binding(
                    get: { c.profile?.gpuList ?? [] },
                    set: { c.profile?.gpuList = $0; manager.persist() }))
                    .disabled(busy)
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
                Image(systemName: "wifi").frame(width: 18).foregroundStyle(.secondary)
                Text(loc.t("Descubrible en red local", "Discoverable on local network")).font(.callout)
                Spacer(minLength: 8)
                Toggle("", isOn: boolBind(\.localNetworkDiscovery, false))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(busy)
            }
            if ServerSettings.mmprojPath(forModel: modelPath) != nil {
                HStack(spacing: 8) {
                    Image(systemName: "photo").frame(width: 18).foregroundStyle(.secondary)
                    Text(loc.t("Visión", "Vision")).font(.callout)
                    Spacer(minLength: 8)
                    let on = c.profile?.loadVision ?? true
                    Button { boolBind(\.loadVision, true).wrappedValue.toggle() } label: {
                        Image(systemName: on ? "eye.fill" : "eye.slash")
                            .imageScale(.large).foregroundStyle(on ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain).disabled(busy)
                }
            }
            DisclosureGroup {
                HStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .frame(width: 18).foregroundStyle(.secondary)
                    Text(loc.t("Servidor de embeddings", "Embeddings server")).font(.callout)
                    Spacer(minLength: 8)
                    Toggle("", isOn: boolBind(\.embeddings, false))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(busy)
                }
                .help(loc.t("Sirve /v1/embeddings con --embeddings para clientes RAG (p. ej. Obsidian Copilot). El servidor queda dedicado a embeddings: úsalo con un modelo de embeddings, no para chatear.",
                            "Serves /v1/embeddings via --embeddings for RAG clients (e.g. Obsidian Copilot). The server becomes embeddings-only: use it with an embedding model, not for chat."))
                .padding(.top, 4)
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath").frame(width: 18).foregroundStyle(.secondary)
                    Text(loc.t("Router (multi-modelo)", "Router (multi-model)")).font(.callout)
                    Spacer(minLength: 8)
                    Toggle("", isOn: boolBind(\.routerMode, false))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(busy)
                }
                .help(loc.t("Un solo servidor sirve todos los modelos descargados: el modelo se elige por petición y se carga solo, sin reiniciar.",
                            "One server serves every downloaded model: the model is picked per request and loads on demand, no restart."))
                .padding(.top, 4)
                if routerMode {
                    HStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up").frame(width: 18).foregroundStyle(.secondary)
                        Text(loc.t("Modelos simultáneos", "Models loaded at once")).font(.callout)
                        Spacer(minLength: 8)
                        Stepper("\(c.profile?.routerModelsMax ?? 1)", value: intBind(\.routerModelsMax, 1), in: 1...4)
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
            Button { manager.removeServer(c.id) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(loc.t("Eliminar este servidor.", "Remove this server."))
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

    private func boolBind(_ kp: WritableKeyPath<Profile, Bool?>, _ fallback: Bool) -> Binding<Bool> {
        Binding(get: { c.profile?[keyPath: kp] ?? fallback },
                set: { c.profile?[keyPath: kp] = $0; manager.persist() })
    }

    private func intBind(_ kp: WritableKeyPath<Profile, Int?>, _ fallback: Int) -> Binding<Int> {
        Binding(get: { c.profile?[keyPath: kp] ?? fallback },
                set: { c.profile?[keyPath: kp] = $0; manager.persist() })
    }
}

struct Card<Content: View>: View {
    let title: String
    let icon: String
    /// When true the card stretches to fill the tallest sibling in its row, so
    /// side-by-side cards line up even with different amounts of content.
    var fill: Bool = false
    /// Optional accessory pinned to the top-right of the title row (e.g. a
    /// profile picker or a "clear" action).
    var trailing: AnyView? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let trailing {
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
