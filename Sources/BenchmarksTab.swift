import SwiftUI

// MARK: - Benchmarks

struct BenchmarksView: View {
    @EnvironmentObject var bench: BenchmarkController
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var profileStore: ProfileStore

    /// Local run configuration — seeded from the saved settings but edited here
    /// without mutating them, so trying many configs never clobbers the setup.
    @State private var cfg: ServerSettings = .fromDefaults()
    @State private var selectedProfile: UUID?
    @State private var savingResult: BenchResult?
    @State private var newProfileName = ""
    @State private var hoveredRun: UUID?
    @State private var appliedToast: String?
    @State private var lastToast = UUID()

    private var gpus: [GPUDevice] { ServerController.availableGPUs() }
    private var busy: Bool { bench.running || bench.sweeping }

    var body: some View {
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
        .onAppear {
            if !busy {
                cfg = .fromDefaults()
                // A MoE model left at ncmoe 0 puts every expert on the GPU and can
                // saturate VRAM; a dense model must not inherit a stale MoE value.
                if !isMoEModel || cfg.ncmoe == 0 {
                    cfg.ncmoe = Estimator.ncmoeForSelection(path: cfg.modelPath, models: models.models)
                }
            }
        }
        .alert(loc.t("Guardar como perfil", "Save as profile"),
               isPresented: Binding(get: { savingResult != nil },
                                    set: { if !$0 { savingResult = nil } })) {
            TextField(loc.t("Nombre del perfil", "Profile name"), text: $newProfileName)
            Button(loc.t("Guardar", "Save")) {
                if let r = savingResult, var p = r.profile {
                    p.name = newProfileName.trimmingCharacters(in: .whitespaces)
                    if !p.name.isEmpty { profileStore.add(p) }
                }
                savingResult = nil
            }
            Button(loc.t("Cancelar", "Cancel"), role: .cancel) { savingResult = nil }
        } message: {
            Text(loc.t("Se guarda la configuración completa de esta corrida. Aparecerá en Ajustes → Perfiles.",
                       "Saves this run's full configuration. It will appear in Settings → Profiles."))
        }
        .overlay(alignment: .bottom) {
            if let msg = appliedToast {
                Label(msg, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.green.opacity(0.92), in: Capsule())
                    .foregroundStyle(.white)
                    .shadow(radius: 8, y: 2)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: appliedToast)
    }

    // MARK: run card

    private var engineName: String {
        if ServerSettings.isTurbo(cfg.serverBinary) { return "TurboQuant" }
        if cfg.serverBinary == ServerSettings.defaultBinary { return loc.t("Integrado", "Bundled") }
        return loc.t("Externo", "External")
    }

    private var isMoEModel: Bool {
        !cfg.modelPath.isEmpty && ServerSettings.modelIsMoE(at: cfg.modelPath)
    }

    /// Model picker binding that seeds ncmoe on selection: the remembered or
    /// recommended value for MoE models, 0 for dense (never carries over stale).
    private var modelBinding: Binding<String> {
        Binding(get: { cfg.modelPath }, set: { newPath in
            cfg.modelPath = newPath
            cfg.ncmoe = Estimator.ncmoeForSelection(path: newPath, models: models.models)
        })
    }

    private var benchLogButton: some View {
        Button { revealInFinder(file: bench.benchLogURL, folder: bench.benchLogDirectory) } label: {
            Label(loc.t("Logs en Finder", "Logs in Finder"), systemImage: "folder").font(.caption)
        }
        .buttonStyle(.borderless).foregroundStyle(.secondary)
        .help(loc.t("Abre la carpeta con el registro completo de cada benchmark (header + salida), para compartir o depurar tras un cuelgue. Se conservan ~30 días.",
                    "Opens the folder with each benchmark's full log (header + output), for sharing or debugging after a freeze. Kept ~30 days."))
    }

    private var runCard: some View {
        Card(title: loc.t("Ejecutar benchmark", "Run benchmark"), icon: "speedometer",
             trailing: AnyView(benchLogButton)) {
            VStack(alignment: .leading, spacing: 14) {
                // Model on its own row so it shares a left edge with the config
                // fields below; selecting a MoE model seeds the recommended ncmoe.
                field(loc.t("Modelo", "Model")) {
                    Picker("", selection: modelBinding) {
                        Text(loc.t("— elegir —", "— pick —")).tag("")
                        ForEach(models.models) { m in Text(m.name).tag(m.url.path) }
                    }
                    .labelsHidden().frame(maxWidth: 480, alignment: .leading)
                }

                // Run configuration: profile seed, GPU, MoE offload as labeled
                // fields, with the run actions on the same baseline at the right.
                HStack(alignment: .bottom, spacing: 22) {
                    Group {
                        field(loc.t("Perfil", "Profile")) {
                            Picker("", selection: $selectedProfile) {
                                Text(loc.t("Ajustes actuales", "Current settings")).tag(UUID?.none)
                                ForEach(profileStore.profiles) { p in Text(p.name).tag(Optional(p.id)) }
                            }
                            .labelsHidden().frame(maxWidth: 260, alignment: .leading)
                            .onChange(of: selectedProfile) { _, id in
                                if let id, let p = profileStore.profiles.first(where: { $0.id == id }) { cfg.apply(p) }
                                else { cfg = .fromDefaults() }
                            }
                        }
                        if !gpus.isEmpty {
                            field("GPU") {
                                GPUSelectionMenu(gpuIndex: $cfg.gpuIndex, gpuList: $cfg.gpuList)
                                    .fixedSize()
                            }
                            .help(loc.t("GPU(s) del benchmark: una fija esa GPU, varias reparten el modelo entre ellas; 'Predeterminada' deja que macOS elija. Se registra en el resultado.",
                                        "Benchmark GPU(s): one pins that GPU, several split the model across them; 'Default' lets macOS pick. It's recorded in the result."))
                        }
                        if isMoEModel {
                            field(loc.t("MoE en CPU", "MoE on CPU")) {
                                HStack(spacing: 6) {
                                    Text("\(cfg.ncmoe)").font(.body.weight(.semibold).monospacedDigit())
                                        .frame(minWidth: 22, alignment: .trailing)
                                    Stepper("", value: $cfg.ncmoe, in: 0...99).labelsHidden()
                                }
                            }
                            .help(loc.t("Solo modelos MoE: capas cuyos expertos corren en CPU. Se siembra con el valor recomendado para tu hardware; subirlo descarga más a CPU, bajarlo arriesga saturar la VRAM.",
                                        "MoE models only: layers whose experts run on the CPU. Seeded with the value recommended for your hardware; raising offloads more to CPU, lowering risks saturating VRAM."))
                        }
                    }
                    .disabled(busy)
                    Spacer()
                    actionButtons
                }

                if let best = bench.sweepBest, !bench.sweeping {
                    HStack(spacing: 10) {
                        Label(bench.sweepStatus, systemImage: "scope")
                            .font(.callout).foregroundStyle(.pink)
                        Button(loc.t("Aplicar ncmoe \(best)", "Apply ncmoe \(best)")) {
                            cfg.ncmoe = best
                            ServerSettings.rememberNcmoe(best, forModel: cfg.modelPath)
                            bench.sweepBest = nil
                        }
                        .controlSize(.small)
                    }
                }

                Divider().opacity(0.35)

                // Effective configuration — the exact run that produces the result.
                HStack(spacing: 6) {
                    chip("ncmoe \(cfg.ncmoe)", active: cfg.ncmoe > 0)
                    chip("K:\(cfg.cacheTypeK)", active: cfg.cacheTypeK != "f16")
                    chip("V:\(cfg.cacheTypeV)", active: cfg.cacheTypeV != "f16")
                    chip(engineName, active: cfg.serverBinary != ServerSettings.defaultBinary)
                    chip(faChipText(cfg.benchmarkFlashAttentionRoute),
                         active: cfg.benchmarkFlashAttentionRoute != "off",
                         icon: cfg.benchmarkFlashAttentionRoute == "amd-gpu" ? "bolt.fill" : "cpu")
                    chip(cfg.gpuLabel, active: cfg.gpuIndex >= 0 || cfg.multiGPU || cfg.gpuList.count >= 2, icon: "cpu")
                    Spacer()
                }

                statusNote
            }
        }
    }

    /// A small caption above a native control, so fields line up as a tidy form
    /// row instead of bare dropdowns floating at different heights.
    private func field<Content: View>(_ label: String,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold)).tracking(0.6)
                .foregroundStyle(.tertiary)
            content()
        }
    }

    @ViewBuilder private var actionButtons: some View {
        HStack(spacing: 10) {
            if bench.running || bench.sweeping {
                ProgressView().controlSize(.small)
                if bench.sweeping {
                    Text(bench.sweepStatus).font(.caption).foregroundStyle(.secondary)
                    Button(loc.t("Cancelar", "Cancel"), role: .destructive) { bench.cancelSweep() }
                } else {
                    Button(loc.t("Cancelar", "Cancel"), role: .destructive) { bench.cancel() }
                }
            } else {
                Button { bench.sweep(settings: cfg) } label: {
                    Label(loc.t("Buscar óptimo", "Find optimum"), systemImage: "scope")
                }
                .disabled(cfg.modelPath.isEmpty || cfg.ncmoe == 0 || server.state == .running || server.state == .starting)
                .help(loc.t("Solo modelos MoE: prueba varios valores de 'Expertos en CPU' bajando hasta detectar la saturación de VRAM, y reporta el mejor. Tarda varios minutos.",
                            "MoE models only: tries several 'experts on CPU' values going down until VRAM saturates, then reports the best. Takes several minutes."))
                Button {
                    ServerSettings.rememberNcmoe(cfg.ncmoe, forModel: cfg.modelPath)
                    bench.run(settings: cfg)
                } label: {
                    Label(loc.t("Ejecutar", "Run"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(cfg.modelPath.isEmpty || server.state == .running || server.state == .starting)
            }
        }
    }

    @ViewBuilder private var statusNote: some View {
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

    private func chip(_ text: String, active: Bool, icon: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 9)) }
            Text(text)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(active ? AnyShapeStyle(.pink.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                    in: Capsule())
        .foregroundStyle(active ? .pink : .secondary)
    }

    private func faChipText(_ route: String) -> String {
        switch route {
        case "amd-gpu": return loc.t("FA AMD GPU", "FA AMD GPU")
        case "standard-cpu": return loc.t("FA CPU", "FA CPU")
        case "standard-auto": return loc.t("FA auto", "FA auto")
        default: return loc.t("FA off", "FA off")
        }
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
                         icon: "bolt.fill", value: best.tg, color: .pink, result: best)
            }
            if let best = bench.history.max(by: { $0.pp < $1.pp }) {
                bestCard(title: loc.t("Mejor prompt", "Best prompt"),
                         icon: "text.alignleft", value: best.pp, color: Color.blue.opacity(0.85), result: best)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Save a run's config snapshot as a profile (name prompt) / apply it to the
    /// global settings so the server uses this winning config next launch.
    private func promptSave(_ r: BenchResult) {
        savingResult = r
        newProfileName = "\(r.shortModel) · \(r.configLabel)"
    }
    private func applyGlobal(_ r: BenchResult) {
        guard let p = r.profile else { return }
        profileStore.setAsDefault(p)
        appliedToast = loc.t("Aplicado al default global", "Applied to global default")
        let token = UUID(); lastToast = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
            if lastToast == token { appliedToast = nil }
        }
    }

    /// A small icon button with its own hover highlight, for the per-row actions
    /// revealed when hovering a comparison or history row.
    private func rowAction(_ system: String, _ help: String, destructive: Bool = false,
                           _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: system) }
            .buttonStyle(HoverIconButtonStyle(tint: destructive ? .red : .pink))
            .help(help)
    }

    private func bestCard(title: String, icon: String, value: Double,
                          color: Color, result: BenchResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28)
                    .background(color.opacity(0.15), in: Circle())
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold)).tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.1f", value))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text("t/s")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color.opacity(0.65))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(result.shortModel).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 5) {
                    chip(result.configLabel, active: false)
                    if let gpu = result.gpu { chip(gpu, active: false, icon: "cpu") }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary.opacity(0.45))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.25), lineWidth: 1))
        )
    }

    // MARK: comparison chart

    private var chartCard: some View {
        let recent = Array(bench.history.prefix(8))
        // Generation (~15–60) and prompt (~50–130) live on very different
        // scales; sharing one axis squashes the generation bars to slivers.
        // Normalize each metric to its own max so both stay readable and the
        // comparison across runs is meaningful.
        let maxTG = recent.map(\.tg).max() ?? 1
        let maxPP = recent.map(\.pp).max() ?? 1
        return Card(title: loc.t("Comparativa (últimas \(recent.count) corridas)",
                                 "Comparison (last \(recent.count) runs)"), icon: "chart.bar") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(recent) { r in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text(r.shortModel).font(.callout.weight(.medium)).lineLimit(1)
                                Text(r.configLabel)
                                    .font(.system(size: 10, design: .monospaced))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.quaternary.opacity(0.6), in: Capsule())
                                    .foregroundStyle(.secondary)
                                if let gpu = r.gpu {
                                    Text(gpu).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            metricBar(loc.t("Gen", "Gen"), value: r.tg, max: maxTG, color: .pink)
                            metricBar("Prompt", value: r.pp, max: maxPP, color: Color.blue.opacity(0.8))
                        }
                        if r.profile != nil {
                            VStack(spacing: 6) {
                                rowAction("square.and.arrow.down",
                                          loc.t("Guardar como perfil", "Save as profile")) { promptSave(r) }
                                rowAction("checkmark.circle",
                                          loc.t("Aplicar a los Ajustes globales", "Apply to global Settings")) { applyGlobal(r) }
                            }
                            .opacity(hoveredRun == r.id ? 1 : 0)
                            .animation(.easeInOut(duration: 0.15), value: hoveredRun)
                        }
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onHover { hoveredRun = $0 ? r.id : (hoveredRun == r.id ? nil : hoveredRun) }
                    if r.id != recent.last?.id { Divider().opacity(0.4) }
                }
                HStack(spacing: 16) {
                    legendDot(.pink, loc.t("Generación", "Generation"))
                    legendDot(Color.blue.opacity(0.8), "Prompt")
                    Spacer()
                    Text(loc.t("t/s · barras normalizadas por métrica",
                               "t/s · bars normalized per metric"))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.top, 4)
            }
        }
    }

    /// One horizontal bar: fixed-width label and value flank a proportional
    /// track, so every row aligns regardless of the numbers.
    private func metricBar(_ label: String, value: Double, max: Double, color: Color) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            GeometryReader { g in
                let frac = max > 0 ? value / max : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.35))
                    Capsule().fill(color.gradient)
                        .frame(width: Swift.max(8, g.size.width * frac))
                }
            }
            .frame(height: 15)
            Text(String(format: "%.1f", value))
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .frame(width: 48, alignment: .trailing)
        }
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: history

    private var historyCard: some View {
        let bestTG = bench.history.max(by: { $0.tg < $1.tg })?.id
        return Card(title: loc.t("Historial completo", "Full history"), icon: "clock",
                    trailing: bench.history.isEmpty ? nil : AnyView(clearHistoryButton)) {
            ForEach(bench.history) { r in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            if r.id == bestTG {
                                Image(systemName: "crown.fill")
                                    .font(.system(size: 9)).foregroundStyle(.yellow)
                                    .help(loc.t("Mejor generación", "Best generation"))
                            }
                            Text(r.shortModel).font(.callout.weight(.medium))
                        }
                        HStack(spacing: 5) {
                            Text(r.configLabel)
                                .font(.system(size: 10, design: .monospaced))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary.opacity(0.6), in: Capsule())
                            if let gpu = r.gpu {
                                Label(gpu, systemImage: "cpu")
                                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
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
                    HStack(spacing: 4) {
                        if r.profile != nil {
                            rowAction("square.and.arrow.down",
                                      loc.t("Guardar como perfil", "Save as profile")) { promptSave(r) }
                            rowAction("checkmark.circle",
                                      loc.t("Aplicar a los Ajustes globales", "Apply to global Settings")) { applyGlobal(r) }
                        }
                        rowAction("trash", loc.t("Eliminar", "Delete"), destructive: true) { bench.delete(r) }
                    }
                }
                .padding(.vertical, 3)
                if r.id != bench.history.last?.id { Divider() }
            }
        }
    }

    private var clearHistoryButton: some View {
        Button(role: .destructive) { bench.clearHistory() } label: {
            Label(loc.t("Limpiar", "Clear"), systemImage: "trash").font(.caption)
        }
        .buttonStyle(.borderless).foregroundStyle(.secondary)
        .help(loc.t("Borrar todo el historial de benchmarks", "Delete the entire benchmark history"))
    }
}

/// Icon button that highlights on hover — used for the per-row save/apply/delete
/// actions so they read as interactive without cluttering the row at rest.
private struct HoverIconButtonStyle: ButtonStyle {
    var tint: Color = .pink
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(hovering ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
            .frame(width: 26, height: 26)
            .background(hovering ? AnyShapeStyle(tint.opacity(0.15)) : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
