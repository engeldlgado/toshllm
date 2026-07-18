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
    @State private var showShare = false
    @AppStorage(SettingsKeys.benchAdvanced) private var benchAdvanced = false

    private var gpus: [GPUDevice] { ServerController.availableGPUs() }
    private var busy: Bool { bench.running || bench.sweeping }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                runCard
                shareCard
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

    private var cardAccessories: some View {
        HStack(spacing: 14) {
            Toggle(loc.t("Avanzado", "Advanced"), isOn: $benchAdvanced)
                .toggleStyle(.checkbox).font(.caption)
                .help(loc.t("Muestra los tamaños de la corrida (-p, -n, -d). Los valores por defecto (pp512/tg128) son el estándar comparable entre equipos.",
                            "Shows the run's workload sizes (-p, -n, -d). The defaults (pp512/tg128) are the standard comparable across machines."))
            benchLogButton
        }
    }

    private var inheritanceLabel: String {
        if let id = selectedProfile, let p = profileStore.profiles.first(where: { $0.id == id }) {
            return loc.t("Configuración del perfil «\(p.name)»", "Config from profile “\(p.name)”")
        }
        return loc.t("Configuración heredada de Ajustes", "Config inherited from Settings")
    }

    // Sharing lives at the top so a long run history never buries it; collapsed by
    // default behind the header toggle, and it publishes the benchmark's own cfg.
    private var shareCard: some View {
        Card(title: loc.t("Compartir con la comunidad", "Share with the community"),
             icon: "square.and.arrow.up",
             trailing: AnyView(shareToggle)) {
            if showShare {
                BenchmarkShareCard(cfg: cfg, inheritanceLabel: inheritanceLabel)
            } else {
                Button {
                    withAnimation(.snappy) { showShare = true }
                } label: {
                    HStack(spacing: 8) {
                        Text(loc.t("Publica una medición verificable de tu equipo en toshllm.com",
                                   "Publish a verifiable measurement of your machine on toshllm.com"))
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var shareToggle: some View {
        Button {
            withAnimation(.snappy) { showShare.toggle() }
        } label: {
            Label(showShare ? loc.t("Ocultar", "Hide") : loc.t("Compartir", "Share"),
                  systemImage: showShare ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(Color.appAccent)
    }

    private var runCard: some View {
        Card(title: loc.t("Ejecutar benchmark", "Run benchmark"), icon: "speedometer",
             trailing: AnyView(cardAccessories)) {
            VStack(alignment: .leading, spacing: 14) {
                // Model on its own row so it shares a left edge with the config
                // fields below; selecting a MoE model seeds the recommended ncmoe.
                field(loc.t("Modelo", "Model")) {
                    Picker("", selection: modelBinding) {
                        Text(loc.t("— elegir —", "— pick —")).tag("")
                        ForEach(models.models) { m in Text(ModelName.forPath(m.url.path).display).tag(m.url.path) }
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
                                ForEach(profileStore.profiles) { p in
                                    Text(p.name.count > 28 ? p.name.prefix(28) + "…" : p.name).tag(Optional(p.id))
                                }
                            }
                            .labelsHidden().fixedSize()
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
                        if benchAdvanced {
                            field("Prompt · -p") {
                                TextField("", value: $cfg.benchPP, format: .number.grouping(.never))
                                    .textFieldStyle(.roundedBorder).frame(width: 64)
                                    .multilineTextAlignment(.trailing)
                            }
                            .help(loc.t("Tokens de prompt a medir (test ppN). 512 es el estándar comparable; 2048-4096 mide el prefill profundo. Más tokens = corrida más larga.",
                                        "Prompt tokens to measure (ppN test). 512 is the comparable standard; 2048-4096 measures deep prefill. More tokens = longer run."))
                            field("Gen · -n") {
                                TextField("", value: $cfg.benchTG, format: .number.grouping(.never))
                                    .textFieldStyle(.roundedBorder).frame(width: 64)
                                    .multilineTextAlignment(.trailing)
                            }
                            .help(loc.t("Tokens a generar (test tgN). 128 es el estándar comparable; 512+ mide la generación sostenida. Más tokens = corrida más larga.",
                                        "Tokens to generate (tgN test). 128 is the comparable standard; 512+ measures sustained generation. More tokens = longer run."))
                            field(loc.t("Profundidad · -d", "Depth · -d")) {
                                TextField("", value: $cfg.benchDepth, format: .number.grouping(.never))
                                    .textFieldStyle(.roundedBorder).frame(width: 64)
                                    .multilineTextAlignment(.trailing)
                            }
                            .help(loc.t("Tokens ya en el contexto antes de medir (una conversación avanzada). 0 = contexto vacío, el caso más favorable; 4096 refleja el uso real y es donde Flash Attention marca la diferencia.",
                                        "Tokens already in the context before measuring (a conversation in progress). 0 = empty context, the most favorable case; 4096 reflects real use and is where Flash Attention makes the difference."))
                        }
                    }
                    .disabled(busy)
                    Spacer()
                    actionButtons
                }

                if let best = bench.sweepBest, !bench.sweeping {
                    HStack(spacing: 10) {
                        Label(bench.sweepStatus, systemImage: "scope")
                            .font(.callout).foregroundStyle(Color.appAccent)
                        Button(loc.t("Aplicar ncmoe \(best)", "Apply ncmoe \(best)")) {
                            cfg.ncmoe = best
                            ServerSettings.rememberNcmoe(best, forModel: cfg.modelPath)
                            bench.sweepBest = nil
                            bench.sweepSamples = []
                        }
                        .controlSize(.small)
                    }
                }

                if !bench.sweepSamples.isEmpty {
                    sweepProgress
                }

                Divider().opacity(0.35)

                // Effective configuration — the exact run that produces the result.
                HStack(spacing: 6) {
                    chip("pp\(cfg.benchPPClamped)/tg\(cfg.benchTGClamped)",
                         active: cfg.benchPPClamped != 512 || cfg.benchTGClamped != 128)
                    if cfg.benchDepthClamped > 0 { chip("d\(cfg.benchDepthClamped)", active: true) }
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
                Button { rememberWorkload(); bench.sweep(settings: cfg) } label: {
                    Label(loc.t("Buscar óptimo", "Find optimum"), systemImage: "scope")
                }
                .disabled(cfg.modelPath.isEmpty || cfg.ncmoe == 0 || server.state == .running || server.state == .starting)
                .help(loc.t("Solo modelos MoE: busca el ncmoe mínimo seguro y recomienda tres pasos por encima para dejar margen de VRAM. Muestra cada medición temporalmente y solo guarda el óptimo.",
                            "MoE models only: finds the lowest safe ncmoe and recommends three steps above it for VRAM headroom. Shows each measurement temporarily and saves only the optimum."))
                Button { rememberWorkload(); bench.runReal(settings: cfg) } label: {
                    Label(loc.t("Generación real", "Real generation"), systemImage: "text.bubble")
                }
                .disabled(cfg.modelPath.isEmpty || server.state == .running || server.state == .starting)
                .help(loc.t("Mide contra un llama-server real, el mismo camino que usa el chat: 1 calentamiento descartado + 3 repeticiones, guarda la mediana. Incluye la aceleración MTP, que el benchmark crudo no ve.",
                            "Measures against a real llama-server, the same path the chat uses: 1 discarded warm-up + 3 repetitions, saves the median. Includes MTP acceleration, which the raw benchmark can't see."))
                Button {
                    ServerSettings.rememberNcmoe(cfg.ncmoe, forModel: cfg.modelPath)
                    rememberWorkload()
                    bench.run(settings: cfg)
                } label: {
                    Label(loc.t("Ejecutar", "Run"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(cfg.modelPath.isEmpty || server.state == .running || server.state == .starting)
            }
        }
    }

    private var sweepProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: bench.sweeping ? "waveform.path.ecg" : "checkmark.circle.fill")
                    .foregroundStyle(bench.sweeping ? Color.appAccent : .green)
                Text(bench.sweeping
                     ? loc.t("Midiendo configuraciones", "Measuring configurations")
                     : loc.t("Resultados temporales del sweep", "Temporary sweep results"))
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(bench.sweepSamples.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(bench.sweepSamples) { sample in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("ncmoe \(sample.ncmoe)")
                                .font(.caption.weight(.semibold).monospacedDigit())
                            HStack(spacing: 7) {
                                Text(sample.pp, format: .number.precision(.fractionLength(1)))
                                Text("pp").foregroundStyle(.tertiary)
                                Text(sample.tg, format: .number.precision(.fractionLength(1)))
                                Text("tg").foregroundStyle(.tertiary)
                            }
                            .font(.system(size: 10.5, design: .monospaced))
                            if let vram = sample.vram {
                                ProgressView(value: min(vram, 1))
                                    .tint(vram > 0.95 ? .orange : .pink)
                                Text(vram, format: .percent.precision(.fractionLength(0)))
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 8))
                        .help(loc.t("Resultado temporal; solo el óptimo se guarda en el historial.",
                                    "Temporary result; only the optimum is saved to history."))
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(10)
        .background(Color.appAccent.opacity(0.055), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.appAccent.opacity(0.14), lineWidth: 1)
        }
        .animation(.easeInOut(duration: 0.2), value: bench.sweepSamples.count)
    }

    @ViewBuilder private var statusNote: some View {
        if server.state == .running || server.state == .starting {
            Label(loc.t("Detén el servidor antes de medir: comparten la VRAM.",
                        "Stop the server before benchmarking: they share VRAM."),
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        } else {
            Text(loc.t("Mide pp\(cfg.benchPPClamped) (prompt) y tg\(cfg.benchTGClamped) (generación), 2 repeticiones. Tarda varios minutos en modelos grandes.",
                       "Measures pp\(cfg.benchPPClamped) (prompt) and tg\(cfg.benchTGClamped) (generation), 2 repetitions. Takes minutes on large models."))
                .font(.caption).foregroundStyle(.secondary)
            if !cfg.modelPath.isEmpty && ServerSettings.modelHasMTP(at: cfg.modelPath) {
                Label(loc.t("Ejecutar mide el decode crudo, sin MTP. Para la velocidad real de este modelo usa \"Generación real\".",
                            "Run measures raw decode, without MTP. For this model's real speed use \"Real generation\"."),
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Clamp and persist the workload sizes so the next session seeds them.
    private func rememberWorkload() {
        cfg.benchPP = cfg.benchPPClamped
        cfg.benchTG = cfg.benchTGClamped
        cfg.benchDepth = cfg.benchDepthClamped
        UserDefaults.standard.set(cfg.benchPP, forKey: SettingsKeys.benchPP)
        UserDefaults.standard.set(cfg.benchTG, forKey: SettingsKeys.benchTG)
        UserDefaults.standard.set(cfg.benchDepth, forKey: SettingsKeys.benchDepth)
    }

    private func chip(_ text: String, active: Bool, icon: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 9)) }
            Text(text)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(active ? AnyShapeStyle(Color.appAccent.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                    in: Capsule())
        .foregroundStyle(active ? Color.appAccent : .secondary)
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
                         icon: "bolt.fill", value: best.tg, color: Color.appAccent, result: best)
            }
            if let best = bench.history.max(by: { $0.pp < $1.pp }) {
                bestCard(title: loc.t("Mejor prompt", "Best prompt"),
                         icon: "text.alignleft", value: best.pp, color: Color.chartSecondary.opacity(0.85), result: best)
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
            .buttonStyle(HoverIconButtonStyle(tint: destructive ? .red : Color.appAccent))
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
        // Generation and prompt live on very different scales; one shared axis
        // would squash the generation bars, so each metric normalizes to its own max.
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
                            metricBar(loc.t("Gen", "Gen"), value: r.tg, max: maxTG, color: Color.appAccent)
                            metricBar("Prompt", value: r.pp, max: maxPP, color: Color.chartSecondary.opacity(0.8))
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
                    legendDot(Color.appAccent, loc.t("Generación", "Generation"))
                    legendDot(Color.chartSecondary.opacity(0.8), "Prompt")
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
        let lastID = bench.history.last?.id
        return Card(title: loc.t("Historial completo", "Full history"), icon: "clock",
                    trailing: bench.history.isEmpty ? nil : AnyView(clearHistoryButton)) {
            // Lazy + Equatable rows: offscreen rows aren't built, and visible
            // ones skip re-rendering during the frequent in-run publishes.
            LazyVStack(spacing: 0) {
                ForEach(bench.history) { r in
                    BenchHistoryRow(r: r, isBest: r.id == bestTG, showsDivider: r.id != lastID,
                                    loc: loc,
                                    onSaveProfile: { promptSave(r) },
                                    onApplyGlobal: { applyGlobal(r) },
                                    onDelete: { bench.delete(r) })
                        .equatable()
                }
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
    var tint: Color = Color.appAccent
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

/// One history row; Equatable so in-run publishes don't re-render the list.
private struct BenchHistoryRow: View, Equatable {
    let r: BenchResult
    let isBest: Bool
    let showsDivider: Bool
    let loc: Localizer
    let onSaveProfile: () -> Void
    let onApplyGlobal: () -> Void
    let onDelete: () -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.r.id == b.r.id && a.isBest == b.isBest && a.showsDivider == b.showsDivider
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if isBest {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 9)).foregroundStyle(.yellow)
                            .help(loc.t("Mejor generación", "Best generation"))
                    }
                    Text(r.shortModel).font(.callout.weight(.medium))
                    if r.shared == true {
                        Image(systemName: "globe")
                            .font(.system(size: 9)).foregroundStyle(Color.appAccent)
                            .help(loc.t("Compartido con la comunidad", "Shared with the community"))
                    }
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
                    Text(r.date, format: .dateTime.day().month().hour().minute())
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 12)
            // Fixed-width metric columns so values line up across rows.
            HStack(spacing: 18) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("prompt").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text(String(format: "%.1f", r.pp))
                        .font(.system(.callout, design: .monospaced))
                }
                .frame(minWidth: 58, alignment: .trailing)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("gen").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text(String(format: "%.1f", r.tg))
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .foregroundStyle(Color.appAccent)
                }
                .frame(minWidth: 48, alignment: .trailing)
            }
            HStack(spacing: 6) {
                if r.profile != nil {
                    action("square.and.arrow.down",
                           loc.t("Guardar como perfil", "Save as profile"), onSaveProfile)
                    action("checkmark.circle",
                           loc.t("Aplicar a los Ajustes globales", "Apply to global Settings"), onApplyGlobal)
                }
                action("trash", loc.t("Eliminar", "Delete"), destructive: true, onDelete)
            }
            .padding(.leading, 10)
        }
        .padding(.vertical, 6)
        if showsDivider { Divider() }
    }

    private func action(_ system: String, _ help: String, destructive: Bool = false,
                        _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Image(systemName: system) }
            .buttonStyle(HoverIconButtonStyle(tint: destructive ? .red : Color.appAccent))
            .help(help)
    }
}
