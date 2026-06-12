import SwiftUI
import Charts

enum Section_: String, CaseIterable, Identifiable {
    case dashboard, chat, models, benchmarks, docs, settings, about
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.50percent"
        case .chat: return "bubble.left.and.bubble.right"
        case .models: return "shippingbox"
        case .benchmarks: return "speedometer"
        case .docs: return "book"
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
        case .settings: return loc.t("Ajustes", "Settings")
        case .about: return loc.t("Acerca de", "About")
        }
    }
}

let hardware = HardwareInfo.detect()

struct ContentView: View {
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer
    @State private var section: Section_ = .dashboard
    @AppStorage(SettingsKeys.onboardingDone) private var onboardingDone = false
    @State private var showOnboarding = false

    var body: some View {
        NavigationSplitView {
            List(Section_.allCases, selection: $section) { s in
                Label(s.title(loc), systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 220)
        } detail: {
            switch section {
            case .dashboard: DashboardView()
            case .chat: ChatTabView()
            case .models: ModelsView()
            case .benchmarks: BenchmarksView()
            case .docs: DocsView()
            case .settings: SettingsView()
            case .about: AboutView()
            }
        }
        .tint(.pink)
        .navigationTitle("ToshLLM")
        .onAppear {
            models.refresh()
            if !onboardingDone && models.models.isEmpty {
                showOnboarding = true
            }
            // Auto-start the server when enabled
            if UserDefaults.standard.bool(forKey: SettingsKeys.autoStart),
               server.state == .stopped,
               !(UserDefaults.standard.string(forKey: SettingsKeys.modelPath) ?? "").isEmpty {
                server.start(.fromDefaults())
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingSheet {
                onboardingDone = true
                showOnboarding = false
                section = .models
            } onDismiss: {
                onboardingDone = true
                showOnboarding = false
            }
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
                step("3", loc.t("Inicia el servidor en Inicio y abre el Chat.",
                                "Start the server from Home and open the Chat."))
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

struct StatsBar: View {
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var vram: VRAMMonitor
    @EnvironmentObject var loc: Localizer

    var body: some View {
        HStack(spacing: 22) {
            stat("Prompt", server.promptSpeed)
            stat(loc.t("Generación", "Generation"), server.genSpeed)
            VStack(alignment: .leading, spacing: 2) {
                Text("VRAM").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ProgressView(value: min(vram.fraction, 1)).frame(width: 90)
                        .tint(vram.fraction > 0.9 ? .red : vram.fraction > 0.75 ? .orange : .accentColor)
                    Text(String(format: "%.1f / %.0f GB", vram.usedMB / 1024, vram.totalMB / 1024))
                        .font(.system(.caption, design: .monospaced))
                }
            }
            if !server.genHistory.isEmpty {
                Chart(Array(server.genHistory.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("n", i), y: .value("t/s", v))
                        .interpolationMethod(.catmullRom)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(width: 120, height: 30)
                .foregroundStyle(.pink)
            }
            Spacer()
            statusBadge
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func stat(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.1f t/s", $0) } ?? "—")
                .font(.system(.body, design: .monospaced).weight(.semibold))
        }
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch server.state {
            case .stopped: return (loc.t("Detenido", "Stopped"), .secondary)
            case .starting: return (loc.t("Cargando modelo…", "Loading model…"), .orange)
            case .running: return (loc.t("Activo", "Running"), .green)
            case .failed(let msg): return (msg, .red)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(.callout).lineLimit(1)
        }
    }
}
