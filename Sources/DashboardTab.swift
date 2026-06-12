import SwiftUI
import Charts

// MARK: - Home

struct DashboardView: View {
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var profileStore: ProfileStore
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""
    @AppStorage(SettingsKeys.ncmoe) private var ncmoe = 0

    @EnvironmentObject var updates: UpdateChecker

    var body: some View {
        VStack(spacing: 0) {
            StatsBar()
            ScrollView {
                VStack(spacing: 16) {
                    updateBanner
                    HStack(alignment: .top, spacing: 16) {
                        hardwareCard
                        serverCard
                    }
                    recommendationCard
                }
                .padding()
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
        Card(title: loc.t("Tu equipo", "Your machine"), icon: "desktopcomputer") {
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
            row("bolt.fill", ServerSettings.isAppleSilicon
                ? loc.t("Backend: Metal (Apple Silicon)", "Backend: Metal (Apple Silicon)")
                : loc.t("Backend: Metal (build AMD parcheado)", "Backend: Metal (patched AMD build)"))
        }
    }

    private var serverCard: some View {
        Card(title: loc.t("Servidor", "Server"), icon: "server.rack") {
            let active = models.models.first { $0.url.path == modelPath }
            row("shippingbox", active?.name ?? loc.t("Sin modelo seleccionado", "No model selected"))
            if ncmoe > 0 {
                row("cpu", loc.t("Expertos MoE en CPU: \(ncmoe) capas",
                                 "MoE experts on CPU: \(ncmoe) layers"))
            }
            row("number", loc.t("Peticiones: \(server.requestCount)", "Requests: \(server.requestCount)"))

            if !profileStore.profiles.isEmpty {
                Menu {
                    ForEach(profileStore.profiles) { p in
                        Button(p.name) {
                            profileStore.apply(p)
                            if server.state == .running { server.stop() }
                        }
                    }
                } label: {
                    Label(loc.t("Aplicar perfil…", "Apply profile…"), systemImage: "person.2")
                        .font(.callout)
                }
                .menuStyle(.borderlessButton)
                .help(loc.t("Carga un perfil guardado. Si el servidor está activo, se detiene para aplicar.",
                            "Loads a saved profile. If the server is running, it stops so the profile applies."))
            }

            HStack {
                switch server.state {
                case .running, .starting:
                    Button(role: .destructive) { server.stop() } label: {
                        Label(loc.t("Detener", "Stop"), systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                default:
                    Button { server.start(.fromDefaults()) } label: {
                        Label(loc.t("Iniciar servidor", "Start server"), systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(modelPath.isEmpty)
                }
                if server.state == .running {
                    Button { NSWorkspace.shared.open(server.serverURL) } label: {
                        Image(systemName: "safari")
                    }
                    .controlSize(.large)
                    .help(loc.t("Abrir en el navegador", "Open in browser"))
                }
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var recommendationCard: some View {
        if let (model, est) = Catalog.recommended(for: hardware) {
            Card(title: loc.t("Recomendado para tu equipo", "Recommended for your machine"),
                 icon: "star.fill") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.name).font(.headline)
                        Text(model.detail(loc.isSpanish)).font(.caption).foregroundStyle(.secondary)
                        EstimateLine(est: est)
                    }
                    Spacer()
                    CatalogActionButton(model: model, est: est)
                }
            }
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

struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
