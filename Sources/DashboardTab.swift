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

    @EnvironmentObject var updates: UpdateChecker

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                updateBanner
                // Cards flow into as many columns as the window fits, so extra servers
                // fill the width instead of stacking in one tall column.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)],
                          spacing: 16) {
                    hardwareCard
                    serverCard
                    ForEach(manager.servers.dropFirst(), id: \.id) { c in
                        AddedServerCard(c: c).environmentObject(manager)
                    }
                }
                recommendationCard
            }
            .padding()
        }
        .overlay(alignment: .bottomTrailing) {
            floatingAddButton.padding(20)
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
    private var floatingAddButton: some View {
        Button {
            let n = manager.servers.count + 1
            manager.addServer(name: loc.t("Servidor \(n)", "Server \(n)"), from: nil)
        } label: {
            Label(loc.t("Agregar servidor", "Add server"), systemImage: "plus")
                .font(.body.weight(.medium))
                .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .glassSurface(in: Capsule(), tint: .pink, interactive: true)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .help(loc.t("Crea otro servidor independiente, con su propia GPU, modelo y puerto.",
                    "Creates another independent server with its own GPU, model and port."))
    }

    private var serverCard: some View {
        Card(title: loc.t("Servidor", "Server"), icon: "server.rack", fill: true,
             trailing: profileStore.profiles.isEmpty ? nil : AnyView(profileMenu)) {
            let active = models.models.first { $0.url.path == modelPath }
            row("shippingbox", active?.name ?? loc.t("Sin modelo seleccionado", "No model selected"))
            if ncmoe > 0 {
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
                Toggle("", isOn: $localNetworkDiscovery)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(serverBusy)
            }
            .help(loc.t("Hace que el servidor escuche en la red local y lo anuncia con Bonjour.",
                        "Makes the server listen on the local network and advertises it via Bonjour.") + restartNote)
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
                    .disabled(modelPath.isEmpty)
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
        Card(title: c.name, icon: "server.rack", fill: true, trailing: AnyView(accessory)) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox").frame(width: 18).foregroundStyle(.secondary)
                Picker("", selection: bind(\.modelPath, "")) {
                    Text(loc.t("Sin modelo", "No model")).tag("")
                    ForEach(models.models) { Text($0.name).tag($0.url.path) }
                }
                .labelsHidden().disabled(busy)
            }
            HStack(spacing: 8) {
                Image(systemName: "cpu").frame(width: 18).foregroundStyle(.secondary)
                Picker("", selection: bind(\.gpuIndex, -1)) {
                    Text(loc.t("GPU por defecto", "Default GPU")).tag(-1)
                    ForEach(hardware.gpus) { Text($0.name).tag($0.index) }
                }
                .labelsHidden().disabled(busy)
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
