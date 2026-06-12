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
            // Auto-start the server when enabled
            if UserDefaults.standard.bool(forKey: "autoStart"),
               server.state == .stopped,
               !(UserDefaults.standard.string(forKey: "modelPath") ?? "").isEmpty {
                server.start(.fromDefaults())
            }
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

// MARK: - Home

struct DashboardView: View {
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var profileStore: ProfileStore
    @AppStorage("modelPath") private var modelPath = ""
    @AppStorage("ncmoe") private var ncmoe = 0

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
                Button(loc.t("Descargar", "Download")) {
                    if let url = updates.releaseURL { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
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

// MARK: - Estimates (helper views)

struct EstimateLine: View {
    let est: MemoryEstimate
    @EnvironmentObject var loc: Localizer

    var body: some View {
        HStack(spacing: 10) {
            badge
            Text(String(format: "VRAM ~%.1f GB", est.vramGB))
            if est.ramGB >= 1 { Text(String(format: "RAM ~%.1f GB", est.ramGB)) }
            Text(est.expectedSpeed)
            if est.suggestedNcmoe > 0 { Text("ncmoe \(est.suggestedNcmoe)") }
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    private var badge: some View {
        let (text, color): (String, Color) = {
            switch est.level {
            case .ideal: return (loc.t("GPU completa", "Full GPU"), .green)
            case .good: return (loc.t("Híbrido GPU+CPU", "GPU+CPU hybrid"), .blue)
            case .slow: return (loc.t("Lento", "Slow"), .orange)
            case .no: return (loc.t("No cabe", "Won't fit"), .red)
            }
        }()
        return Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct CatalogActionButton: View {
    let model: CatalogModel
    let est: MemoryEstimate
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer
    @AppStorage("modelPath") private var modelPath = ""
    @AppStorage("ncmoe") private var ncmoe = 0

    var body: some View {
        if let local = models.localModel(fileName: model.fileName) {
            if modelPath == local.url.path {
                Label(loc.t("Activo", "Active"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
            } else {
                Button(loc.t("Usar", "Use")) {
                    modelPath = local.url.path
                    ncmoe = est.suggestedNcmoe
                }
                .buttonStyle(.borderedProminent)
            }
        } else if models.isDownloading(fileName: model.fileName) {
            ProgressView().controlSize(.small)
        } else if est.level == .no {
            Text(loc.t("No compatible", "Not compatible")).font(.caption).foregroundStyle(.secondary)
        } else {
            Button {
                models.download(urlString: model.urlString)
            } label: {
                Label(loc.t("Descargar", "Download"), systemImage: "arrow.down.circle")
            }
        }
    }
}

// MARK: - Chat

struct ChatTabView: View {
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var loc: Localizer
    @AppStorage("modelPath") private var modelPath = ""

    var body: some View {
        VStack(spacing: 0) {
            StatsBar()
            switch server.state {
            case .running:
                NativeChatView()
                    .toolbar {
                        Button {
                            NSWorkspace.shared.open(server.serverURL)
                        } label: { Image(systemName: "safari") }
                            .help(loc.t("Abrir el chat web en el navegador", "Open the web chat in the browser"))
                    }
            case .starting:
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text(loc.t("Cargando modelo…", "Loading model…")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                VStack(spacing: 16) {
                    Image(systemName: "bolt.slash")
                        .font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text(loc.t("Servidor detenido", "Server stopped"))
                        .font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                    if modelPath.isEmpty {
                        Text(loc.t("Selecciona un modelo en la pestaña Modelos y vuelve aquí.",
                                   "Pick a model in the Models tab, then come back here."))
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            server.start(.fromDefaults())
                        } label: {
                            Label(loc.t("Iniciar servidor", "Start server"), systemImage: "play.fill")
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Models

struct ModelsView: View {
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer
    @AppStorage("modelPath") private var modelPath = ""
    @AppStorage("ncmoe") private var ncmoe = 0
    @State private var customURL = ""
    @State private var pendingDelete: LocalModel?

    var body: some View {
        List {
            if !models.downloads.isEmpty {
                Section(loc.t("Descargas", "Downloads")) {
                    ForEach(models.downloads) { DownloadRow(item: $0) }
                    Button(loc.t("Limpiar terminadas", "Clear finished")) {
                        models.clearFinishedDownloads()
                    }.font(.caption)
                }
            }

            HFSearchSection()

            Section(loc.t("Catálogo — estimaciones para tu equipo",
                          "Catalog — estimates for your machine")) {
                ForEach(Catalog.models) { m in
                    let est = Estimator.estimate(spec: m.spec, hw: hardware)
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(m.name).fontWeight(.medium)
                                Text(String(format: "%.1f GB", m.spec.fileGB))
                                    .font(.caption).foregroundStyle(.secondary)
                                if m.spec.isMoE { MoEBadge() }
                            }
                            Text(m.detail(loc.isSpanish)).font(.caption).foregroundStyle(.secondary)
                            EstimateLine(est: est)
                        }
                        Spacer()
                        CatalogActionButton(model: m, est: est)
                    }
                    .padding(.vertical, 3)
                }
            }

            Section(loc.t("Archivos locales en ~/models", "Local files in ~/models")) {
                if models.models.isEmpty {
                    Text(loc.t("No hay modelos .gguf todavía", "No .gguf models yet"))
                        .foregroundStyle(.secondary)
                }
                ForEach(models.models) { m in
                    let est = Estimator.estimate(spec: Catalog.spec(forLocal: m), hw: hardware)
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(m.name).fontWeight(modelPath == m.url.path ? .semibold : .regular)
                                if m.isMoE { MoEBadge() }
                            }
                            Text(m.sizeGB).font(.caption).foregroundStyle(.secondary)
                            EstimateLine(est: est)
                        }
                        Spacer()
                        if modelPath == m.url.path {
                            Label(loc.t("Activo", "Active"), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.callout)
                        } else {
                            Button(loc.t("Usar", "Use")) {
                                modelPath = m.url.path
                                ncmoe = est.suggestedNcmoe
                            }
                        }
                        Button { NSWorkspace.shared.activateFileViewerSelecting([m.url]) } label: {
                            Image(systemName: "magnifyingglass")
                        }.buttonStyle(.borderless)
                            .help(loc.t("Mostrar en Finder", "Reveal in Finder"))
                        Button { pendingDelete = m } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless).foregroundStyle(.red)
                            .help(loc.t("Eliminar (a la Papelera)", "Delete (to Trash)"))
                    }
                    .padding(.vertical, 3)
                }
            }

            Section(loc.t("URL personalizada (GGUF directo)", "Custom URL (direct GGUF)")) {
                HStack {
                    TextField("https://huggingface.co/…/resolve/main/model.gguf", text: $customURL)
                        .textFieldStyle(.roundedBorder)
                    Button(loc.t("Descargar", "Download")) {
                        models.download(urlString: customURL)
                        customURL = ""
                    }
                    .disabled(!customURL.hasPrefix("http"))
                }
            }
        }
        .toolbar {
            Button { models.refresh() } label: {
                Label(loc.t("Actualizar", "Refresh"), systemImage: "arrow.clockwise")
            }
        }
        .confirmationDialog(
            loc.t("¿Eliminar \(pendingDelete?.name ?? "")?", "Delete \(pendingDelete?.name ?? "")?"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button(loc.t("Mover a la Papelera", "Move to Trash"), role: .destructive) {
                if let m = pendingDelete {
                    if modelPath == m.url.path { modelPath = "" }
                    models.delete(m)
                }
                pendingDelete = nil
            }
            Button(loc.t("Cancelar", "Cancel"), role: .cancel) { pendingDelete = nil }
        }
    }
}

// MARK: - Hugging Face search

struct HFSearchSection: View {
    @EnvironmentObject var search: SearchStore
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        Section(loc.t("Buscar en Hugging Face", "Search Hugging Face")) {
            HStack {
                TextField(loc.t("p. ej. Qwen3.6 35B A3B", "e.g. Qwen3.6 35B A3B"), text: $search.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search.search() } }
                Button {
                    Task { await search.search() }
                } label: {
                    if search.searching { ProgressView().controlSize(.small) }
                    else { Label(loc.t("Buscar", "Search"), systemImage: "magnifyingglass") }
                }
                .disabled(search.query.isEmpty || search.searching)
            }

            if search.didSearch && search.results.isEmpty && !search.searching {
                Text(loc.t("Sin resultados", "No results")).foregroundStyle(.secondary).font(.caption)
            }

            ForEach(search.results) { repo in
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        Task { await search.toggleFiles(repo: repo.id) }
                    } label: {
                        HStack {
                            Image(systemName: search.expanded == repo.id ? "chevron.down" : "chevron.right")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(repo.id).font(.callout)
                            Spacer()
                            if let d = repo.downloads {
                                Label("\(d)", systemImage: "arrow.down.circle")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if search.expanded == repo.id {
                        if let files = search.files[repo.id] {
                            if files.isEmpty {
                                Text(loc.t("Sin archivos .gguf directos", "No direct .gguf files"))
                                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 18)
                            }
                            ForEach(files) { f in
                                let est = Estimator.estimate(
                                    spec: .estimated(fileBytes: f.sizeBytes, isMoE: f.isMoE), hw: hardware)
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(f.path).font(.caption)
                                        EstimateLine(est: est)
                                    }
                                    Spacer()
                                    Text(f.sizeGB).font(.caption2).foregroundStyle(.secondary)
                                    if models.isDownloaded(fileName: URL(fileURLWithPath: f.path).lastPathComponent) {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    } else if est.level == .no {
                                        Text(loc.t("No cabe", "Won't fit")).font(.caption2).foregroundStyle(.red)
                                    } else {
                                        Button {
                                            models.download(urlString: search.downloadURL(repo: repo.id, file: f.path))
                                        } label: { Image(systemName: "arrow.down.circle") }
                                            .buttonStyle(.borderless)
                                    }
                                }
                                .padding(.leading, 18)
                            }
                        } else {
                            ProgressView().controlSize(.small).padding(.leading, 18)
                        }
                    }
                }
            }
        }
    }
}

struct MoEBadge: View {
    var body: some View {
        Text("MoE").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
            .background(.pink.opacity(0.2), in: Capsule())
    }
}

struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    @EnvironmentObject var loc: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.fileName).font(.callout)
                Spacer()
                if let error = item.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if item.finished {
                    Label(loc.t("Completada", "Done"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                } else {
                    Text(String(format: "%.0f / %.0f MB", item.receivedMB, item.totalMB))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Button { item.cancel() } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                }
            }
            if !item.finished && item.error == nil {
                ProgressView(value: item.progress)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Benchmarks

struct BenchmarksView: View {
    @EnvironmentObject var bench: BenchmarkController
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer
    @AppStorage("modelPath") private var modelPath = ""
    @AppStorage("ncmoe") private var ncmoe = 0
    @AppStorage("cacheTypeK") private var cacheTypeK = "f16"
    @AppStorage("cacheTypeV") private var cacheTypeV = "f16"
    @AppStorage("serverBinary") private var serverBinary = ServerSettings.defaultBinary

    var body: some View {
        VStack(spacing: 0) {
            StatsBar()
            ScrollView {
                VStack(spacing: 16) {
                    runCard
                    if bench.running || !bench.output.isEmpty { outputCard }
                    if !bench.history.isEmpty {
                        bestCards
                        chartCard
                        historyCard
                    }
                }
                .padding()
            }
        }
    }

    // MARK: run card

    private var engineName: String {
        if serverBinary == ServerSettings.defaultBinary { return loc.t("Integrado", "Bundled") }
        if serverBinary == ServerSettings.turboBinary { return "TurboQuant" }
        return loc.t("Externo", "External")
    }

    private var runCard: some View {
        Card(title: loc.t("Ejecutar benchmark", "Run benchmark"), icon: "speedometer") {
            HStack(spacing: 12) {
                Picker(loc.t("Modelo", "Model"), selection: $modelPath) {
                    Text(loc.t("— elegir —", "— pick —")).tag("")
                    ForEach(models.models) { m in
                        Text(m.name).tag(m.url.path)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 380)

                Spacer()

                if bench.running {
                    ProgressView().controlSize(.small)
                    Button(loc.t("Cancelar", "Cancel"), role: .destructive) { bench.cancel() }
                } else {
                    Button {
                        bench.run(settings: .fromDefaults())
                    } label: {
                        Label(loc.t("Ejecutar", "Run"), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(modelPath.isEmpty || server.state == .running || server.state == .starting)
                }
            }

            // configuration summary as chips
            HStack(spacing: 6) {
                chip("ncmoe \(ncmoe)", active: ncmoe > 0)
                chip("K:\(cacheTypeK)", active: cacheTypeK != "f16")
                chip("V:\(cacheTypeV)", active: cacheTypeV != "f16")
                chip(engineName, active: serverBinary != ServerSettings.defaultBinary)
                Spacer()
                Text(loc.t("Se configura en Ajustes", "Configured in Settings"))
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            if server.state == .running || server.state == .starting {
                Label(loc.t("Detén el servidor antes de medir: comparten la VRAM.",
                            "Stop the server before benchmarking: they share VRAM."),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text(loc.t("Mide pp512 (prompt) y tg128 (generación), 2 repeticiones. Tarda varios minutos en modelos grandes.",
                           "Measures pp512 (prompt) and tg128 (generation), 2 repetitions. Takes minutes on large models."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chip(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(active ? AnyShapeStyle(.pink.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                        in: Capsule())
            .foregroundStyle(active ? .pink : .secondary)
    }

    private var outputCard: some View {
        Card(title: loc.t("Salida", "Output"), icon: "terminal") {
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    Text(bench.output.isEmpty ? "…" : bench.output)
                        .font(.system(size: 10.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("benchEnd")
                }
                .frame(height: 130)
                .onChange(of: bench.output) { _, _ in proxy.scrollTo("benchEnd", anchor: .bottom) }
            }
        }
    }

    // MARK: best results

    private var bestCards: some View {
        HStack(spacing: 16) {
            if let best = bench.history.max(by: { $0.tg < $1.tg }) {
                bestCard(title: loc.t("Mejor generación", "Best generation"),
                         icon: "bolt.fill",
                         value: String(format: "%.1f t/s", best.tg),
                         detail: "\(best.shortModel) · \(best.configLabel)")
            }
            if let best = bench.history.max(by: { $0.pp < $1.pp }) {
                bestCard(title: loc.t("Mejor prompt", "Best prompt"),
                         icon: "text.alignleft",
                         value: String(format: "%.1f t/s", best.pp),
                         detail: "\(best.shortModel) · \(best.configLabel)")
            }
        }
    }

    private func bestCard(title: String, icon: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.pink)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: comparison chart

    private var chartCard: some View {
        let recent = Array(bench.history.prefix(8))
        return Card(title: loc.t("Comparativa (últimas \(recent.count) corridas)",
                                 "Comparison (last \(recent.count) runs)"), icon: "chart.bar") {
            Chart {
                ForEach(recent) { r in
                    BarMark(x: .value("t/s", r.tg),
                            y: .value("run", "\(r.shortModel)\n\(r.configLabel)"))
                        .position(by: .value("metric", loc.t("Generación", "Generation")))
                        .foregroundStyle(by: .value("metric", loc.t("Generación", "Generation")))
                        .annotation(position: .trailing) {
                            Text(String(format: "%.1f", r.tg)).font(.system(size: 9))
                        }
                    BarMark(x: .value("t/s", r.pp),
                            y: .value("run", "\(r.shortModel)\n\(r.configLabel)"))
                        .position(by: .value("metric", "Prompt"))
                        .foregroundStyle(by: .value("metric", "Prompt"))
                        .annotation(position: .trailing) {
                            Text(String(format: "%.0f", r.pp)).font(.system(size: 9))
                        }
                }
            }
            .chartForegroundStyleScale([
                loc.t("Generación", "Generation"): Color.pink,
                "Prompt": Color.blue.opacity(0.65),
            ])
            .chartXAxisLabel("t/s")
            .frame(height: CGFloat(recent.count) * 52 + 40)
        }
    }

    // MARK: history

    private var historyCard: some View {
        Card(title: loc.t("Historial completo", "Full history"), icon: "clock") {
            ForEach(bench.history) { r in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.shortModel).font(.callout.weight(.medium))
                        HStack(spacing: 5) {
                            Text(r.configLabel)
                                .font(.system(size: 10, design: .monospaced))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary.opacity(0.6), in: Capsule())
                            Text(r.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    HStack(spacing: 14) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("prompt").font(.system(size: 9)).foregroundStyle(.tertiary)
                            Text(String(format: "%.1f", r.pp))
                                .font(.system(.callout, design: .monospaced))
                        }
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("gen").font(.system(size: 9)).foregroundStyle(.tertiary)
                            Text(String(format: "%.1f", r.tg))
                                .font(.system(.callout, design: .monospaced).weight(.semibold))
                                .foregroundStyle(.pink)
                        }
                    }
                    Button { bench.delete(r) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 3)
                if r.id != bench.history.last?.id { Divider() }
            }
        }
    }
}

// MARK: - About

enum AppInfo {
    static let version = "0.81.1"
    static let developerName = "Engelbert Delgado"
    static let developerHandle = "engeldlgado"
    static let githubURL = "https://github.com/engeldlgado"
    static let binancePayID = "engeldlgado"
    static let usdtTRC20 = "TFUG271bbbQEmFu4wkFHyvNNkYRZC5JDUf"
    static let donateNoteES = "Si ToshLLM te resulta útil, puedes apoyar el desarrollo con una donación."
    static let donateNoteEN = "If ToshLLM is useful to you, you can support development with a donation."
}

struct AboutView: View {
    @EnvironmentObject var loc: Localizer
    @State private var showDonate = false
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                   let icon = NSImage(contentsOf: iconURL) {
                    Image(nsImage: icon)
                        .resizable().frame(width: 110, height: 110)
                }
                VStack(spacing: 4) {
                    Text("ToshLLM").font(.largeTitle.weight(.bold))
                    Text(loc.t("Versión", "Version") + " " + AppInfo.version)
                        .foregroundStyle(.secondary)
                }
                Text(loc.t("Modelos de lenguaje locales con aceleración Metal en Macs Intel con GPU AMD.",
                           "Local language models with Metal acceleration on Intel Macs with AMD GPUs."))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)

                Card(title: loc.t("Desarrollador", "Developer"), icon: "person.crop.circle") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppInfo.developerName).font(.headline)
                            Text("@" + AppInfo.developerHandle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            NSWorkspace.shared.open(URL(string: AppInfo.githubURL)!)
                        } label: {
                            Label("GitHub", systemImage: "link")
                        }
                        Button {
                            showDonate = true
                        } label: {
                            Label(loc.t("Donar", "Donate"), systemImage: "heart.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.pink)
                        .popover(isPresented: $showDonate, arrowEdge: .bottom) { donatePopover }
                    }
                }
                .frame(maxWidth: 460)

                Card(title: loc.t("Créditos", "Credits"), icon: "hands.clap") {
                    credit("llama.cpp", "ggml-org — " + loc.t("motor de inferencia", "inference engine"))
                    credit("iRon-Llama (Basten7)", loc.t("parches Metal para AMD dGPU en Mac Intel",
                                                         "Metal patches for AMD dGPU on Intel Mac"))
                }
                .frame(maxWidth: 460)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private var donatePopover: some View { DonateView() }

    private func credit(_ name: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).fontWeight(.medium)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var profileStore: ProfileStore

    @AppStorage("serverBinary") private var serverBinary = ServerSettings.defaultBinary
    @AppStorage("port") private var port = 8080
    @AppStorage("ngl") private var ngl = 99
    @AppStorage("ncmoe") private var ncmoe = 0
    @AppStorage("ctx") private var ctx = 16384
    @AppStorage("threads") private var threads = 6
    @AppStorage("flashAttn") private var flashAttn = "auto"
    @AppStorage("noMmap") private var noMmap = true
    @AppStorage("jinja") private var jinja = true
    @AppStorage("concurrencyDisable") private var concurrencyDisable = ServerSettings.defaultConcurrencyDisable
    @AppStorage("vramReserve") private var vramReserve = 1024
    @AppStorage("gpuIndex") private var gpuIndex = -1
    @AppStorage("extraArgs") private var extraArgs = ""
    @AppStorage("cacheTypeK") private var cacheTypeK = "f16"
    @AppStorage("cacheTypeV") private var cacheTypeV = "f16"
    @AppStorage("mlock") private var mlock = false
    @AppStorage("menuBarIcon") private var menuBarIcon = true
    @AppStorage("autoStart") private var autoStart = false
    @State private var profileName = ""

    // TurboQuant KV types only exist in the experimental engine (llama.cpp PR 23962) or external builds
    private var availableKVTypes: [String] {
        serverBinary == ServerSettings.defaultBinary
            ? ServerSettings.kvCacheTypes
            : ServerSettings.kvCacheTypes + ["turbo4", "turbo3", "turbo2"]
    }

    private var engineSelection: Binding<String> {
        Binding(
            get: {
                if serverBinary == ServerSettings.defaultBinary { return "bundled" }
                if serverBinary == ServerSettings.turboBinary { return "turbo" }
                return "custom"
            },
            set: { kind in
                switch kind {
                case "bundled": serverBinary = ServerSettings.defaultBinary
                case "turbo": serverBinary = ServerSettings.turboBinary ?? ServerSettings.defaultBinary
                default: serverBinary = ""
                }
            })
    }

    var body: some View {
        Form {
            Section(loc.t("Aplicación", "Application")) {
                Picker(loc.t("Idioma", "Language"), selection: $loc.isSpanish) {
                    Text("Español").tag(true)
                    Text("English").tag(false)
                }
                .help(loc.t("Idioma de toda la interfaz de ToshLLM.",
                            "Language for the entire ToshLLM interface."))
                Toggle(loc.t("Icono en la barra de menús", "Menu bar icon"), isOn: $menuBarIcon)
                    .help(loc.t("Muestra un icono en la barra de menús con el estado del servidor y controles rápidos, aunque la ventana esté cerrada.",
                                "Shows a menu bar icon with server status and quick controls, even with the window closed."))
                Toggle(loc.t("Iniciar servidor al abrir la app", "Start server on app launch"), isOn: $autoStart)
                    .help(loc.t("Arranca automáticamente el último modelo configurado al abrir ToshLLM.",
                                "Automatically starts the last configured model when ToshLLM opens."))
            }

            Section(loc.t("Perfiles", "Profiles")) {
                HStack {
                    TextField(loc.t("Nombre del perfil (p. ej. Código, Chat rápido)",
                                    "Profile name (e.g. Coding, Quick chat)"), text: $profileName)
                        .textFieldStyle(.roundedBorder)
                    Button(loc.t("Guardar actual", "Save current")) {
                        profileStore.saveCurrent(name: profileName.trimmingCharacters(in: .whitespaces))
                        profileName = ""
                    }
                    .disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help(loc.t("Guarda toda la configuración actual (modelo incluido) con este nombre.",
                                "Saves the entire current configuration (model included) under this name."))
                }
                ForEach(profileStore.profiles) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).fontWeight(.medium)
                            Text(URL(fileURLWithPath: p.modelPath).lastPathComponent)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(loc.t("Aplicar", "Apply")) { profileStore.apply(p) }
                            .help(loc.t("Carga esta configuración. Reinicia el servidor para usarla.",
                                        "Loads this configuration. Restart the server to use it."))
                        Button { profileStore.delete(p) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .help(loc.t("Eliminar este perfil.", "Delete this profile."))
                    }
                }
            }

            Section(loc.t("GPU y memoria", "GPU & memory")) {
                Picker(loc.t("GPU (Metal)", "GPU (Metal)"), selection: $gpuIndex) {
                    Text(loc.t("Predeterminada", "Default")).tag(-1)
                    ForEach(hardware.gpus) { g in
                        Text("\(g.index): \(g.name) · \(g.vramMB / 1024) GB").tag(g.index)
                    }
                }
                .help(loc.t("Qué GPU usa el servidor si tienes varias. 'Predeterminada' deja elegir a Metal.",
                            "Which GPU the server uses if you have several. 'Default' lets Metal choose."))
                Stepper(loc.t("Capas en GPU (-ngl): \(ngl)", "GPU layers (-ngl): \(ngl)"),
                        value: $ngl, in: 0...99)
                    .help(loc.t("Cuántas capas del modelo van a la GPU. 99 = todas (recomendado si caben en VRAM); bájalo solo si la VRAM se desborda.",
                                "How many model layers go to the GPU. 99 = all (recommended if they fit in VRAM); lower it only if VRAM overflows."))
                Stepper(loc.t("Expertos MoE en CPU: \(ncmoe)", "MoE experts on CPU: \(ncmoe)"),
                        value: $ncmoe, in: 0...99)
                    .help(loc.t("Solo modelos MoE: capas cuyos 'expertos' viven en RAM y los procesa el CPU. Se ajusta solo al elegir modelo; súbelo si la VRAM se satura, bájalo si te sobra.",
                                "MoE models only: layers whose 'experts' live in RAM and run on the CPU. Auto-set when picking a model; raise if VRAM saturates, lower if you have headroom."))
                Stepper(loc.t("Reserva de VRAM: \(vramReserve) MB", "VRAM reserve: \(vramReserve) MB"),
                        value: $vramReserve, in: 256...4096, step: 256)
                    .help(loc.t("VRAM que se deja libre para el sistema y la interfaz. 1024 MB es un margen seguro.",
                                "VRAM left free for the system and UI. 1024 MB is a safe margin."))
                Toggle(loc.t("Copiar pesos a VRAM (--no-mmap, recomendado)",
                             "Copy weights to VRAM (--no-mmap, recommended)"), isOn: $noMmap)
                    .help(loc.t("Copia los pesos a la VRAM en vez de leerlos por PCIe en cada token. En GPU dedicada multiplica la velocidad (~6×). Desactívalo solo para depurar.",
                                "Copies weights into VRAM instead of reading them over PCIe per token. On a discrete GPU this multiplies speed (~6×). Disable only for debugging."))
                Toggle(loc.t("Bloquear modelo en RAM (--mlock)", "Lock model in RAM (--mlock)"), isOn: $mlock)
                    .help(loc.t("Impide que macOS mueva el modelo a swap o lo comprima: estabilidad de velocidad constante. Útil con modelos MoE grandes; requiere RAM suficiente.",
                                "Prevents macOS from swapping or compressing the model: consistent speed. Useful with large MoE models; requires enough free RAM."))
            }

            Section(loc.t("Inferencia y contexto", "Inference & context")) {
                Picker(loc.t("Contexto", "Context"), selection: $ctx) {
                    ForEach([4096, 8192, 16384, 32768, 65536], id: \.self) { Text("\($0) tokens").tag($0) }
                }
                .help(loc.t("Tamaño máximo de la conversación en tokens. Más contexto = más memoria para el KV cache (mira los tipos de abajo para compensar).",
                            "Maximum conversation size in tokens. More context = more KV cache memory (see the types below to compensate)."))
                Picker(loc.t("KV cache: claves (-ctk)", "KV cache: keys (-ctk)"), selection: $cacheTypeK) {
                    ForEach(availableKVTypes, id: \.self) { Text($0).tag($0) }
                }
                .help(loc.t("Cuantización de las claves del KV cache. En GPU AMD: q8_0 reduce las claves a la mitad casi sin costo de velocidad (recomendado); q4_0 a un cuarto. Los tipos turbo* (TurboQuant) requieren el motor externo experimental.",
                            "Quantization for KV cache keys. On AMD GPUs: q8_0 halves key memory at almost no speed cost (recommended); q4_0 quarters it. turbo* types (TurboQuant) require the experimental external engine."))
                Picker(loc.t("KV cache: valores (-ctv)", "KV cache: values (-ctv)"), selection: $cacheTypeV) {
                    ForEach(availableKVTypes, id: \.self) { Text($0).tag($0) }
                }
                .help(loc.t("Cuantización de los valores del KV cache. ⚠️ En GPU AMD esto fuerza Flash Attention en CPU: la generación baja ~3× (de ~50 a ~15-19 t/s en un 8B). Úsalo solo cuando necesites contexto enorme; si no, déjalo en f16 y cuantiza solo las claves.",
                            "Quantization for KV cache values. ⚠️ On AMD GPUs this forces Flash Attention onto the CPU: generation drops ~3× (from ~50 to ~15-19 t/s on an 8B). Use only when you need huge context; otherwise keep f16 and quantize keys only."))
                Stepper(loc.t("Hilos de CPU: \(threads)", "CPU threads: \(threads)"),
                        value: $threads, in: 1...16)
                    .help(loc.t("Hilos para la parte que corre en CPU (expertos MoE, tokenización). Los núcleos físicos (\(hardware.physicalCores)) suelen ser el óptimo; más hilos no acelera si el límite es la RAM.",
                                "Threads for the CPU side (MoE experts, tokenization). Physical cores (\(hardware.physicalCores)) are usually optimal; more threads won't help if RAM bandwidth is the limit."))
                Picker("Flash Attention", selection: $flashAttn) {
                    Text("auto").tag("auto"); Text("on").tag("on"); Text("off").tag("off")
                }
                .help(loc.t("Atención optimizada en memoria. 'auto' la activa solo donde el backend la soporta bien (recomendado en GPU AMD). Necesaria para cuantizar los valores del KV cache.",
                            "Memory-efficient attention. 'auto' enables it only where the backend supports it well (recommended on AMD GPUs). Required for quantized KV cache values."))
                Toggle(loc.t("Plantilla de chat (--jinja)", "Chat template (--jinja)"), isOn: $jinja)
                    .help(loc.t("Usa la plantilla de chat oficial del modelo (formato de mensajes, herramientas). Déjalo activado salvo problemas con un modelo concreto.",
                                "Uses the model's official chat template (message format, tools). Keep it on unless a specific model misbehaves."))
                Toggle(loc.t("Estabilidad AMD dGPU (concurrencia desactivada)",
                             "AMD dGPU stability (concurrency disabled)"), isOn: $concurrencyDisable)
                    .help(loc.t("Imprescindible en GPUs AMD discretas: sin esto la salida se corrompe (texto basura).",
                                "Required on discrete AMD GPUs: output corrupts (garbage text) without it."))
            }

            Section(loc.t("Avanzado", "Advanced")) {
                TextField(loc.t("Puerto", "Port"), value: $port, format: .number)
                    .help(loc.t("Puerto local del servidor (API compatible con OpenAI y chat web).",
                                "Local server port (OpenAI-compatible API and web chat)."))
                Picker(loc.t("Motor de inferencia", "Inference engine"), selection: engineSelection) {
                    Text(loc.t("Integrado (oficial)", "Bundled (official)")).tag("bundled")
                    if ServerSettings.turboBinary != nil {
                        Text("TurboQuant (experimental)").tag("turbo")
                    }
                    Text(loc.t("Externo…", "External…")).tag("custom")
                }
                .help(loc.t("Integrado: llama.cpp oficial, recomendado. TurboQuant: motor experimental con KV cache turbo2/3/4 (~6× más contexto, pero la generación baja ~3× en GPU AMD). Externo: cualquier llama-server tuyo.",
                            "Bundled: official llama.cpp, recommended. TurboQuant: experimental engine with turbo2/3/4 KV cache (~6× more context, but generation drops ~3× on AMD GPUs). External: any llama-server of yours."))
                if engineSelection.wrappedValue == "custom" {
                    TextField(loc.t("Ruta del llama-server externo", "External llama-server path"), text: $serverBinary)
                        .font(.system(.caption, design: .monospaced))
                        .help(loc.t("Ruta a un llama-server alternativo para probar otras builds.",
                                    "Path to an alternative llama-server to test other builds."))
                }
                TextField(loc.t("Argumentos extra", "Extra arguments"), text: $extraArgs)
                    .font(.system(.caption, design: .monospaced))
                    .help(loc.t("Argumentos adicionales de llama-server separados por espacios (para opciones que la app no expone).",
                                "Additional llama-server arguments, space-separated (for options the app doesn't expose)."))
                Text(loc.t("Los cambios se aplican al reiniciar el servidor.",
                           "Changes take effect when the server restarts."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(loc.t("Registro del servidor", "Server log")) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(server.log.isEmpty ? loc.t("(sin salida todavía)", "(no output yet)") : server.log)
                            .font(.system(size: 10.5, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id("logEnd")
                    }
                    .frame(height: 200)
                    .onChange(of: server.log) { _, _ in proxy.scrollTo("logEnd", anchor: .bottom) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
