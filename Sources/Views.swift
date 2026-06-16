import SwiftUI

enum Section_: String, CaseIterable, Identifiable {
    case dashboard, chat, models, benchmarks, docs, logs, settings, about
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.50percent"
        case .chat: return "bubble.left.and.bubble.right"
        case .models: return "shippingbox"
        case .benchmarks: return "speedometer"
        case .docs: return "book"
        case .logs: return "list.bullet.rectangle"
        case .settings: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }
    func title(_ loc: Localizer) -> String {
        switch self {
        case .dashboard: return loc.t("Inicio", "Home")
        case .chat: return "Chat"
        case .models: return loc.t("Modelos", "Models")
        case .benchmarks: return "Benchmarks"
        case .docs: return loc.t("Documentación", "Docs")
        case .logs: return loc.t("Registro", "Logs")
        case .settings: return loc.t("Ajustes", "Settings")
        case .about: return loc.t("Acerca de", "About")
        }
    }
}

let hardware = HardwareInfo.detect()

/// The management window: hardware dashboard, models, benchmarks, docs and
/// settings. The chat lives in its own (main) window.
struct ControlPanelView: View {
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var control: ControlPanelState

    var body: some View {
        NavigationSplitView {
            List(Section_.allCases.filter { $0 != .chat }, selection: $control.section) { s in
                Label(s.title(loc), systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 220)
        } detail: {
            switch control.section {
            case .dashboard, .chat: DashboardView()
            case .models: ModelsView()
            case .benchmarks: BenchmarksView()
            case .docs: DocsView()
            case .logs: LogsView()
            case .settings: SettingsView()
            case .about: AboutView()
            }
        }
        .tint(.pink)
        .navigationTitle(loc.t("Configuración", "Configuration"))
        // Telemetry rides in the glass title bar (macOS 26), shared across all
        // sections, instead of a flat strip beneath the large title.
        .toolbar {
            ToolbarItem(placement: .automatic) { ServerStatsToolbar() }
        }
    }
}

/// First-run guidance shown when no models are installed yet.
struct OnboardingSheet: View {
    @EnvironmentObject var loc: Localizer
    let onGoToModels: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 40)).foregroundStyle(.pink)
            Text(loc.t("Bienvenido a ToshLLM", "Welcome to ToshLLM"))
                .font(.title.bold())
            Text(loc.t("Modelos de lenguaje corriendo en tu GPU, sin nube y sin cuentas.",
                       "Language models running on your GPU — no cloud, no accounts."))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                step("1", loc.t("Descarga un modelo del catálogo — la app te marca cuáles caben en tu equipo.",
                                "Download a model from the catalog — the app marks which ones fit your machine."))
                step("2", loc.t("Pulsa 'Usar' y los parámetros se configuran solos.",
                                "Press 'Use' and the parameters configure themselves."))
                step("3", loc.t("Vuelve al Chat, pulsa 'Iniciar servidor' y escribe.",
                                "Go back to Chat, press 'Start server' and type."))
            }
            .frame(maxWidth: 380)

            HStack {
                Button(loc.t("Explorar por mi cuenta", "Explore on my own"), action: onDismiss)
                Button {
                    onGoToModels()
                } label: {
                    Label(loc.t("Elegir mi primer modelo", "Pick my first model"),
                          systemImage: "shippingbox")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(30)
        .frame(width: 480)
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number)
                .font(.system(.callout, design: .rounded).bold())
                .frame(width: 24, height: 24)
                .background(.pink.opacity(0.18), in: Circle())
                .foregroundStyle(.pink)
            Text(text)
        }
    }
}

// MARK: - Stats bar

/// Compact server telemetry for the configuration window's toolbar, so the
/// stats share the system's glass title bar (macOS 26) instead of sitting in a
/// flat strip under the large title.
struct ServerStatsToolbar: View {
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var vram: VRAMMonitor
    @EnvironmentObject var loc: Localizer

    var body: some View {
        HStack(spacing: 14) {
            stat("Prompt", server.promptSpeed)
            stat(loc.t("Generación", "Generation"), server.genSpeed)
            HStack(spacing: 5) {
                Image(systemName: "memorychip").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: min(vram.fraction, 1)).frame(width: 56)
                    .tint(vram.fraction > 0.9 ? .red : vram.fraction > 0.75 ? .orange : .accentColor)
                Text(String(format: "%.1f/%.0f", vram.usedMB / 1024, vram.totalMB / 1024))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            statusBadge
        }
    }

    private func stat(_ label: String, _ value: Double?) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.0f", $0) } ?? "—")
                .font(.system(size: 12, design: .monospaced).weight(.semibold))
        }
        .help(loc.t("\(label): velocidad de la última petición en tokens por segundo.",
                    "\(label): last request speed in tokens per second."))
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch server.state {
            case .stopped: return (loc.t("Detenido", "Stopped"), .secondary)
            case .starting: return (loc.t("Cargando…", "Loading…"), .orange)
            case .running: return (loc.t("Activo", "Running"), .green)
            case .failed(let msg): return (msg, .red)
            }
        }()
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).lineLimit(1)
        }
    }
}
