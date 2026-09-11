// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import Charts

// MARK: - Benchmarks

private enum BenchmarkDashboardSection: Hashable {
    case results, comparison, charts, history
}

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
    @State private var appliedToast: String?
    @State private var lastToast = UUID()
    @State private var showShareSheet = false
    @State private var showAdvanced = false
    @State private var resultsLimit = 20
    @State private var historyLimit = 20
    @State private var dashboardSection: BenchmarkDashboardSection = .results
    @State private var resultSearch = ""
    @State private var resultKind = "all"
    @State private var hardware = HardwareInfo.detect()
    @State private var comparisonAID: UUID?
    @State private var comparisonBID: UUID?
    @State private var outputDismissed = false

    private var gpus: [GPUDevice] { hardware.gpus }
    private var busy: Bool { bench.running || bench.sweeping || bench.optimizingDynamicMoe }

    var body: some View {

        ScrollView {
            VStack(spacing: 16) {
                compactRunCard
                contextualStatusCard
                if !bench.history.isEmpty {
                    bestCards
                    resultsNavigation
                    Group {
                        switch dashboardSection {
                        case .results: resultsCard
                        case .comparison: comparisonCard
                        case .charts: chartsCard
                        case .history: historyCard
                        }
                    }
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
        .onChange(of: bench.dynamicMoeOptimizationProfile?.modelFingerprint) { _, fingerprint in
            guard fingerprint != nil else { return }
            cfg.dynamicMoe = true
            cfg.dynamicMoePolicy = "auto"
        }
        .onChange(of: busy) { _, running in
            if running { outputDismissed = false }
        }
        .sheet(isPresented: $showShareSheet) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    SectionGlyph(systemName: "person.3")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.t("Compartir con la comunidad", "Share with the community"))
                            .font(.title3.weight(.semibold))
                        Text(loc.t("Publica una medición verificable en toshllm.com",
                                   "Publish a verifiable measurement on toshllm.com"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { showShareSheet = false } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(GlassIconButtonStyle())
                    .iconHelp(loc.t("Cerrar", "Close"))
                }
                .padding(18)
                Divider()
                ScrollView {
                    BenchmarkShareCard(cfg: cfg, inheritanceLabel: inheritanceLabel)
                        .padding(18)
                }
            }
            .background(WorkspaceStyle.canvas)
            .frame(minWidth: 700, idealWidth: 780, maxWidth: 860,
                   minHeight: 480, idealHeight: 520, maxHeight: 660)
        }
    }

    // MARK: run card

    private var engineName: String {
        if cfg.serverBinary == ServerSettings.defaultBinary { return loc.t("Integrado", "Bundled") }
        return loc.t("Externo", "External")
    }

    private var isMoEModel: Bool {
        guard !cfg.modelPath.isEmpty else { return false }
        return ModelTraitsCache.cached(for: cfg.modelPath)?.isMoE
            ?? ModelName.looksMoE(URL(fileURLWithPath: cfg.modelPath).lastPathComponent)
    }

    /// K is per layer and bounded by the model: at least the experts a token uses,
    /// at most the ones the GGUF really has.
    private var dmoeSlotRange: ClosedRange<Int> {
        guard let info = cfg.dynamicMoeModelInfo else { return 1...256 }
        return min(max(info.activeExpertCount, 1), info.expertCount)...info.expertCount
    }
    private var dmoeSlotBinding: Binding<Int> {
        Binding(get: { cfg.effectiveDynamicMoeSlots },
                set: { v in
                    let r = dmoeSlotRange
                    cfg.dynamicMoeSlots = min(max(v, r.lowerBound), r.upperBound)
                })
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
        benchLogButton
    }

    private var inheritanceLabel: String {
        if let id = selectedProfile, let p = profileStore.profiles.first(where: { $0.id == id }) {
            return loc.t("Configuración del perfil «%@»", "Config from profile “%@”", "\(p.name)")
        }
        return loc.t("Configuración heredada de Ajustes", "Config inherited from Settings")
    }

    private var compactRunCard: some View {
        Card(title: loc.t("Configuración del benchmark", "Benchmark configuration"),
             icon: "gearshape",
             trailing: {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.snappy(duration: 0.22)) { showAdvanced.toggle() }
                    } label: {
                        Label(loc.t("Avanzado", "Advanced"),
                              systemImage: showAdvanced ? "chevron.up" : "slider.horizontal.3")
                    }
                    .glassButton().controlSize(.small)

                    Button { rememberWorkload(); bench.runReal(settings: cfg) } label: {
                        Label(loc.t("Generación real", "Real generation"), systemImage: "text.bubble")
                    }
                    .glassButton().controlSize(.small)
                    .disabled(busy || cfg.modelPath.isEmpty
                              || server.state == .running || server.state == .starting)

                    Button { showShareSheet = true } label: {
                        Label(loc.t("Compartir", "Share"), systemImage: "person.3")
                    }
                    .glassButton().controlSize(.small)
                    .disabled(busy || cfg.modelPath.isEmpty)

                    if busy {
                        Button(loc.t("Cancelar", "Cancel"), role: .destructive) {
                            if bench.optimizingDynamicMoe { bench.cancelDynamicMoeOptimization() }
                            else if bench.sweeping { bench.cancelSweep() }
                            else { bench.cancel() }
                        }
                        .glassButton().controlSize(.small)
                    } else {
                        Button {
                            ServerSettings.rememberNcmoe(cfg.ncmoe, forModel: cfg.modelPath)
                            rememberWorkload()
                            bench.run(settings: cfg)
                        } label: {
                            Label(loc.t("Ejecutar benchmark", "Run benchmark"), systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent).controlSize(.regular)
                        .disabled(cfg.modelPath.isEmpty || server.state == .running || server.state == .starting)
                    }
                }
             }) {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        compactModelField.frame(minWidth: 260, maxWidth: .infinity)
                        compactDivider
                        compactProfileField.frame(width: 220)
                        compactDivider
                        compactGPUField.frame(width: 220)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        compactModelField
                        HStack(alignment: .top, spacing: 14) {
                            compactProfileField
                            compactGPUField
                        }
                    }
                }
                .disabled(busy)

                BenchmarkWrappingLayout(spacing: 6) {
                    chip("pp\(cfg.benchPPClamped)/tg\(cfg.benchTGClamped)",
                         active: cfg.benchPPClamped != 512 || cfg.benchTGClamped != 128)
                    if cfg.benchDepthClamped > 0 {
                        chip("d\(cfg.benchDepthClamped)", active: true)
                    }
                    if cfg.effectiveDynamicMoe {
                        chip("dMoE K\(cfg.effectiveDynamicMoeSlots)", active: true)
                    } else if isMoEModel {
                        chip("ncmoe \(cfg.ncmoe)", active: cfg.ncmoe > 0)
                    }
                    chip("K:\(cfg.cacheTypeK)", active: cfg.cacheTypeK != "f16")
                    chip("V:\(cfg.cacheTypeV)", active: cfg.cacheTypeV != "f16")
                    chip(engineName, active: cfg.serverBinary != ServerSettings.defaultBinary)
                    chip(faChipText(cfg.benchmarkFlashAttentionRoute),
                         active: cfg.benchmarkFlashAttentionRoute != "off",
                         icon: cfg.benchmarkFlashAttentionRoute == "amd-gpu" ? "bolt.fill" : "cpu")
                    chip(cfg.gpuLabel,
                         active: cfg.gpuIndex >= 0 || cfg.multiGPU || cfg.gpuList.count >= 2,
                         icon: "display")
                    if cfg.mgpuPeer && cfg.isSplitting {
                        chip("IF Link", active: true, icon: "bolt.horizontal")
                    }
                }

                if showAdvanced {
                    Divider().opacity(0.55)
                    advancedBenchmarkControls
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                benchmarkRuntimeStatus

                if busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(bench.sweeping ? bench.sweepStatus : bench.optimizingDynamicMoe
                             ? bench.dynamicMoeOptimizationStatus.localized(using: loc)
                             : loc.t("Benchmark en curso…", "Benchmark running…"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                statusNote
            }
        }
    }

    private var compactModelField: some View {
        field(loc.t("Modelo", "Model")) {
            Picker("", selection: modelBinding) {
                Text(loc.t("— elegir —", "— pick —")).tag("")
                ForEach(models.modelGroups) { group in
                    Section(group.isOther ? loc.t("Otros", "Others") : group.family) {
                        ForEach(group.models) { model in
                            Text(ModelName.forPath(model.url.path).display
                                 + (ModelTraitsCache.cached(for: model.url.path)?.pickerSuffix(spanish: loc.isSpanish) ?? ""))
                                .tag(model.url.path)
                        }
                    }
                }
            }
            .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            Text(loc.t("La prueba no modifica tus servidores.", "The test does not change your servers."))
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var compactProfileField: some View {
        field(loc.t("Perfil del motor", "Engine profile")) {
            Picker("", selection: $selectedProfile) {
                Text(loc.t("Ajustes actuales", "Current settings")).tag(UUID?.none)
                ForEach(profileStore.profiles) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            }
            .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: selectedProfile) { _, id in
                if let id, let profile = profileStore.profiles.first(where: { $0.id == id }) {
                    cfg.apply(profile)
                } else {
                    cfg = .fromDefaults()
                }
            }
        }
    }

    private var compactGPUField: some View {
        field("GPU") {
            GPUSelectionMenu(gpuIndex: $cfg.gpuIndex, gpuList: $cfg.gpuList)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let gpu = hardware.bestGPU {
                Text("\(gpu.name) · \(gpu.vramGB) GB")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }

    private var compactWorkloadFields: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(loc.t("CARGA", "WORKLOAD"))
                .font(.system(size: 9, weight: .semibold)).tracking(0.6)
                .foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                compactNumberField("Prompt", value: $cfg.benchPP)
                compactNumberField(loc.t("Generación", "Generation"), value: $cfg.benchTG)
                compactNumberField(loc.t("Profundidad", "Depth"), value: $cfg.benchDepth)
            }
        }
    }

    private func compactNumberField(_ label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            BenchmarkIntegerField(value: value)
                .frame(height: 17)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(WorkspaceStyle.inset, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(WorkspaceStyle.border))
        }
        .frame(maxWidth: .infinity)
    }

    private var compactDivider: some View {
        Divider().padding(.horizontal, 14).frame(height: 70)
    }

    private var advancedBenchmarkControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                compactWorkloadFields.frame(maxWidth: 360)
                Divider().frame(height: 54)
                if isMoEModel && cfg.effectiveDynamicMoe {
                    field(loc.t("Ranuras dMoE", "dMoE slots")) {
                        Stepper("\(cfg.effectiveDynamicMoeSlots)", value: dmoeSlotBinding, in: dmoeSlotRange)
                    }
                } else if isMoEModel {
                    field(loc.t("MoE en CPU", "MoE on CPU")) {
                        Stepper("\(cfg.ncmoe)", value: $cfg.ncmoe, in: 0...99)
                    }
                    field(loc.t("Micro-lote", "Micro-batch")) {
                        Picker("", selection: $cfg.ubatch) {
                            ForEach(ServerSettings.ubatchOptions, id: \.self) { value in
                                Text(ServerSettings.ubatchLabel(value, loc: loc)).tag(value)
                            }
                        }.labelsHidden()
                    }
                }
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(loc.t("Modos avanzados", "Advanced modes"), systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.semibold))
                    Text(loc.t("Pruebas del servidor real y optimización para modelos MoE.",
                               "Real-server tests and optimization for MoE models."))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if isMoEModel {
                    Button { rememberWorkload(); bench.sweep(settings: cfg) } label: {
                        Label(loc.t("Encontrar equilibrio", "Find balance"), systemImage: "scope")
                    }
                    .disabled(cfg.modelPath.isEmpty || cfg.ncmoe == 0 || cfg.effectiveDynamicMoe
                              || server.state == .running || server.state == .starting)
                }
                if isMoEModel && cfg.dynamicMoeUIUnlocked {
                    Button { rememberWorkload(); bench.optimizeDynamicMoe(settings: cfg) } label: {
                        Label(loc.t("Optimizar dMoE", "Optimize dMoE"), systemImage: "gearshape.2")
                    }
                    .disabled(cfg.modelPath.isEmpty || cfg.serverBinary != ServerSettings.defaultBinary
                              || server.state == .running || server.state == .starting)
                }
            }
        }
        .disabled(busy)
    }

    /// Sweep samples and dMoE optimization results were part of the original
    /// benchmark workflow. Keep them outside the disclosure so a completed run
    /// never becomes invisible merely because Advanced is collapsed.
    @ViewBuilder private var benchmarkRuntimeStatus: some View {
        if let best = bench.sweepBest, !bench.sweeping {
            HStack(spacing: 10) {
                Label(bench.sweepStatus, systemImage: "scope")
                    .font(.callout).foregroundStyle(Color.appAccent)
                Button(loc.t("Aplicar ncmoe %@", "Apply ncmoe %@", "\(best)")) {
                    cfg.ncmoe = best
                    ServerSettings.rememberNcmoe(best, forModel: cfg.modelPath)
                    bench.sweepBest = nil
                    bench.sweepSamples = []
                }
                .controlSize(.small)
            }
        }
        if !bench.sweepSamples.isEmpty { sweepProgress }
        if bench.optimizingDynamicMoe || bench.dynamicMoeOptimizationStatus != .idle {
            DynamicMoeOptimizationStatusView(
                running: bench.optimizingDynamicMoe,
                status: bench.dynamicMoeOptimizationStatus,
                profile: bench.dynamicMoeOptimizationProfile,
                samples: bench.dynamicMoeOptimizationSamples)
        }
    }

    private var runCard: some View {
        Card(title: loc.t("Laboratorio de rendimiento", "Performance lab"), icon: "gauge.with.needle",
            trailing: { cardAccessories }) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    parameterSectionTitle(loc.t("1 · Elige el modelo", "1 · Choose a model"), icon: "cube")
                    Picker("", selection: modelBinding) {
                        Text(loc.t("— elegir —", "— pick —")).tag("")
                        ForEach(models.modelGroups) { group in
                            Section(group.isOther ? loc.t("Otros", "Others") : group.family) {
                                ForEach(group.models) { m in
                                    Text(ModelName.forPath(m.url.path).display
                                         + (ModelTraitsCache.cached(for: m.url.path)?.pickerSuffix(spanish: loc.isSpanish) ?? ""))
                                        .tag(m.url.path)
                                }
                            }
                        }
                    }
                    .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    Text(loc.t("La configuración se prueba de forma aislada y no modifica tus servidores.",
                               "The configuration is tested in isolation and does not change your servers."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .benchmarkPanel()

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        parameterSectionTitle(loc.t("2 · Motor y hardware", "2 · Engine and hardware"), icon: "cpu")
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                                  alignment: .leading, spacing: 12) {
                            field(loc.t("Perfil", "Profile")) {
                                Picker("", selection: $selectedProfile) {
                                    Text(loc.t("Ajustes actuales", "Current settings")).tag(UUID?.none)
                                    ForEach(profileStore.profiles) { p in
                                        Text(p.name.count > 28 ? p.name.prefix(28) + "…" : p.name).tag(Optional(p.id))
                                    }
                                }
                                .labelsHidden().frame(maxWidth: .infinity)
                                .onChange(of: selectedProfile) { _, id in
                                    if let id, let p = profileStore.profiles.first(where: { $0.id == id }) { cfg.apply(p) }
                                    else { cfg = .fromDefaults() }
                                }
                            }
                            if !gpus.isEmpty {
                                field("GPU") {
                                    GPUSelectionMenu(gpuIndex: $cfg.gpuIndex, gpuList: $cfg.gpuList)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            if isMoEModel && cfg.effectiveDynamicMoe {
                                field(loc.t("Ranuras dMoE", "dMoE slots")) {
                                    Stepper("\(cfg.effectiveDynamicMoeSlots)", value: dmoeSlotBinding, in: dmoeSlotRange)
                                        .fixedSize()
                                }
                            } else if isMoEModel {
                                field(loc.t("MoE en CPU", "MoE on CPU")) {
                                    Stepper("\(cfg.ncmoe)", value: $cfg.ncmoe, in: 0...99).fixedSize()
                                }
                                field(loc.t("Micro-lote", "Micro-batch")) {
                                    Picker("", selection: $cfg.ubatch) {
                                        ForEach(ServerSettings.ubatchOptions, id: \.self) { n in
                                            Text(ServerSettings.ubatchLabel(n, loc: loc)).tag(n)
                                        }
                                    }
                                    .labelsHidden().frame(maxWidth: .infinity)
                                }
                            }
                        }
                        .disabled(busy)
                        HStack(spacing: 6) {
                            chip(engineName, active: cfg.serverBinary != ServerSettings.defaultBinary)
                            chip(faChipText(cfg.benchmarkFlashAttentionRoute),
                                 active: cfg.benchmarkFlashAttentionRoute != "off",
                                 icon: cfg.benchmarkFlashAttentionRoute == "amd-gpu" ? "bolt.fill" : "cpu")
                            chip(cfg.gpuLabel, active: cfg.gpuIndex >= 0 || cfg.multiGPU || cfg.gpuList.count >= 2,
                                 icon: "cpu")
                        }
                    }
                    .benchmarkPanel()

                    VStack(alignment: .leading, spacing: 12) {
                        parameterSectionTitle(loc.t("3 · Define la carga", "3 · Set the workload"), icon: "waveform.path.ecg")
                        HStack(spacing: 12) {
                            workloadField("Prompt", flag: "-p", value: $cfg.benchPP,
                                          help: loc.t("Tokens del prompt que se procesarán.", "Prompt tokens to process."))
                            workloadField(loc.t("Generación", "Generation"), flag: "-n", value: $cfg.benchTG,
                                          help: loc.t("Tokens que se generarán.", "Tokens to generate."))
                            workloadField(loc.t("Profundidad", "Depth"), flag: "-d", value: $cfg.benchDepth,
                                          help: loc.t("Tokens ya presentes en el contexto.", "Tokens already present in context."))
                        }
                        HStack {
                            Label("pp\(cfg.benchPPClamped) · tg\(cfg.benchTGClamped)", systemImage: "timer")
                            Spacer()
                            Text(cfg.benchDepthClamped == 0
                                 ? loc.t("Contexto vacío", "Empty context")
                                 : loc.t("Contexto: %@ tokens", "Context: %@ tokens", "\(cfg.benchDepthClamped)"))
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .benchmarkPanel()
                }

                VStack(alignment: .leading, spacing: 10) {
                    parameterSectionTitle(loc.t("4 · Elige qué medir", "4 · Choose what to measure"), icon: "play.circle")
                    if busy {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(bench.sweeping ? bench.sweepStatus : bench.optimizingDynamicMoe
                                 ? bench.dynamicMoeOptimizationStatus.localized(using: loc)
                                 : loc.t("Benchmark en curso…", "Benchmark running…"))
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button(loc.t("Cancelar", "Cancel"), role: .destructive) {
                                if bench.optimizingDynamicMoe { bench.cancelDynamicMoeOptimization() }
                                else if bench.sweeping { bench.cancelSweep() }
                                else { bench.cancel() }
                            }
                        }
                        .padding(12)
                    } else {
                        HStack(spacing: 10) {
                            runChoice(loc.t("Velocidad estándar", "Standard speed"),
                                      subtitle: loc.t("Resultado comparable de prompt y generación.",
                                                      "Comparable prompt and generation result."),
                                      icon: "speedometer", prominent: true,
                                      disabled: cfg.modelPath.isEmpty || server.state == .running || server.state == .starting) {
                                ServerSettings.rememberNcmoe(cfg.ncmoe, forModel: cfg.modelPath)
                                rememberWorkload(); bench.run(settings: cfg)
                            }
                            runChoice(loc.t("Generación real", "Real generation"),
                                      subtitle: loc.t("Simula el chat e incluye MTP.", "Simulates chat and includes MTP."),
                                      icon: "text.bubble", prominent: false,
                                      disabled: cfg.modelPath.isEmpty || server.state == .running || server.state == .starting) {
                                rememberWorkload(); bench.runReal(settings: cfg)
                            }
                            if isMoEModel {
                                runChoice(loc.t("Encontrar equilibrio", "Find best balance"),
                                          subtitle: loc.t("Busca la distribución GPU/CPU más segura.",
                                                          "Finds a safe GPU/CPU distribution."),
                                          icon: "scope", prominent: false,
                                          disabled: cfg.modelPath.isEmpty || cfg.ncmoe == 0 || cfg.effectiveDynamicMoe
                                            || server.state == .running || server.state == .starting) {
                                    rememberWorkload(); bench.sweep(settings: cfg)
                                }
                            }
                            if isMoEModel && cfg.dynamicMoeUIUnlocked {
                                runChoice(loc.t("Optimizar dMoE", "Optimize dMoE"),
                                          subtitle: loc.t("Crea y activa el mejor mapa de expertos.",
                                                          "Builds and activates the best expert map."),
                                          icon: "gearshape.2", prominent: false,
                                          disabled: cfg.modelPath.isEmpty
                                            || cfg.serverBinary != ServerSettings.defaultBinary
                                            || server.state == .running || server.state == .starting) {
                                    rememberWorkload(); bench.optimizeDynamicMoe(settings: cfg)
                                }
                            }
                        }
                    }
                }

                if let best = bench.sweepBest, !bench.sweeping {
                    HStack(spacing: 10) {
                        Label(bench.sweepStatus, systemImage: "scope")
                            .font(.callout).foregroundStyle(Color.appAccent)
                        Button(loc.t("Aplicar ncmoe %@", "Apply ncmoe %@", "\(best)")) {
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

                if bench.optimizingDynamicMoe || bench.dynamicMoeOptimizationStatus != .idle {
                    DynamicMoeOptimizationStatusView(
                        running: bench.optimizingDynamicMoe,
                        status: bench.dynamicMoeOptimizationStatus,
                        profile: bench.dynamicMoeOptimizationProfile,
                        samples: bench.dynamicMoeOptimizationSamples)
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

    private func parameterSectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func workloadField(_ title: String, flag: String, value: Binding<Int>, help: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(title.uppercased())
                Text(flag).foregroundStyle(.tertiary)
            }
            .font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
            BenchmarkIntegerField(value: value, pointSize: 15)
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorkspaceStyle.border))
                .disabled(busy)
        }
        .frame(maxWidth: .infinity)
        .help(help)
    }

    private func runChoice(_ title: String, subtitle: String, icon: String, prominent: Bool,
                           disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).symbolRenderingMode(.hierarchical)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 31, height: 31)
                    .background(prominent ? Color.white.opacity(0.16) : Color.appAccent.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 10)).opacity(0.72).lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "play.fill").font(.caption)
            }
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(11).frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(prominent ? Color.appAccent : WorkspaceStyle.inset,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(prominent ? Color.clear : WorkspaceStyle.border))
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.45 : 1)
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
            Text(loc.t("Mide pp%@ (prompt) y tg%@ (generación), 2 repeticiones. Tarda varios minutos en modelos grandes.", "Measures pp%@ (prompt) and tg%@ (generation), 2 repetitions. Takes minutes on large models.", "\(cfg.benchPPClamped)", "\(cfg.benchTGClamped)"))
                .font(.caption).foregroundStyle(.secondary)
            if ModelTraitsCache.cached(for: cfg.modelPath)?.hasMTP == true {
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

    private var systemCard: some View {
        Card(title: loc.t("Tu sistema", "Your system"), icon: "cpu") {
            HStack(spacing: 0) {
                systemFact("cpu", hardware.cpuBrand,
                           "\(hardware.physicalCores) cores / \(hardware.logicalCores) threads")
                systemDivider
                systemFact("memorychip", String(format: "%.0f GB RAM", hardware.ramGB), hardware.arch)
                systemDivider
                systemFact("display", hardware.bestGPU?.name ?? "GPU",
                           hardware.bestGPU.map { "\($0.vramGB) GB VRAM" } ?? "—")
                systemDivider
                systemFact("apple.logo", hardware.osVersion, hardware.model)
                systemDivider
                systemFact("bolt.fill", "Metal", faChipText(cfg.benchmarkFlashAttentionRoute))
            }
        }
    }

    @ViewBuilder private var contextualStatusCard: some View {
        if (busy || bench.hasOutput) && !outputDismissed {
            outputCard
                .transition(.opacity)
        } else {
            systemCard
                .transition(.opacity)
        }
    }

    private func systemFact(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 25)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var systemDivider: some View {
        Divider().frame(height: 36).padding(.horizontal, 12)
    }

    private var resultsNavigation: some View {
        HStack(spacing: 12) {
            GlassSegmentedControl(selection: $dashboardSection, segments: [
                .init(value: .results, title: loc.t("Resultados", "Results")),
                .init(value: .comparison, title: loc.t("Comparación", "Comparison")),
                .init(value: .charts, title: loc.t("Gráficos", "Charts")),
                .init(value: .history, title: loc.t("Historial", "History")),
            ])
            Spacer()
            if dashboardSection == .results || dashboardSection == .history {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(loc.t("Buscar modelos…", "Search models…"), text: $resultSearch)
                        .textFieldStyle(.plain).frame(width: 170)
                    if !resultSearch.isEmpty {
                        Button { resultSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorkspaceStyle.border))

                Menu {
                    Button(loc.t("Todos", "All")) { resultKind = "all" }
                    Button(loc.t("Benchmark estándar", "Standard benchmark")) { resultKind = "raw" }
                    Button(loc.t("Generación real", "Real generation")) { resultKind = "real" }
                } label: {
                    Label(loc.t("Filtros", "Filters"), systemImage: "line.3.horizontal.decrease")
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
    }

    private var filteredResults: [BenchResult] {
        bench.history.filter { result in
            let matchesKind = resultKind == "all"
                || (resultKind == "real" && result.kind == "real")
                || (resultKind == "raw" && result.kind != "real")
            let query = resultSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            return matchesKind && (query.isEmpty
                || result.shortModel.localizedCaseInsensitiveContains(query)
                || result.quantization.localizedCaseInsensitiveContains(query)
                || result.configLabel.localizedCaseInsensitiveContains(query))
        }
    }

    private var resultsCard: some View {
        let visible = Array(filteredResults.prefix(resultsLimit))
        let maxPrompt = visible.map(\.pp).max() ?? 1
        let maxGeneration = visible.map(\.tg).max() ?? 1
        return Card(title: loc.t("Resultados", "Results"), icon: "tablecells",
                    trailing: {
                        Text("\(visible.count) / \(filteredResults.count)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }) {
            VStack(spacing: 0) {
                BenchmarkResultTableHeader(loc: loc)
                Divider()
                ForEach(visible) { result in
                    BenchmarkResultTableRow(result: result,
                                            isBest: result.id == bench.history.max(by: { $0.tg < $1.tg })?.id,
                                            maxPrompt: maxPrompt,
                                            maxGeneration: maxGeneration,
                                            loc: loc,
                                            onSaveProfile: { promptSave(result) },
                                            onApplyGlobal: { applyGlobal(result) },
                                            onDelete: { bench.delete(result) })
                    if result.id != visible.last?.id { Divider().opacity(0.45) }
                }
                if visible.isEmpty {
                    ContentUnavailableView.search(text: resultSearch)
                        .frame(height: 120)
                }
                if visible.count < filteredResults.count {
                    Divider().opacity(0.45)
                    BenchmarkLoadMoreButton(remaining: filteredResults.count - visible.count,
                                            loc: loc) {
                        resultsLimit = min(resultsLimit + 20, filteredResults.count)
                    }
                }
            }
        }
    }

    private var outputCard: some View {
        BenchmarkOutputCard(buffer: bench.outputBuffer, loc: loc) {
            outputDismissed = true
        }
    }

    // MARK: best results

    private var bestCards: some View {
        HStack(spacing: 12) {
            if let best = bench.history.max(by: { $0.tg < $1.tg }) {
                bestCard(title: loc.t("Mejor generación", "Best generation"),
                         icon: "bolt.fill", value: best.tg, color: Color.appAccent, result: best)
            }
            if let best = bench.history.max(by: { $0.pp < $1.pp }) {
                bestCard(title: loc.t("Mejor prompt", "Best prompt"),
                         icon: "text.alignleft", value: best.pp, color: Color.chartSecondary.opacity(0.85), result: best)
            }
            summaryStatCard(title: loc.t("Total de pruebas", "Total runs"), icon: "clock",
                            value: "\(bench.history.count)",
                            subtitle: loc.t("en %@ modelos", "across %@ models",
                                            "\(Set(bench.history.map(\.shortModel)).count)"),
                            color: .purple)
            summaryStatCard(title: loc.t("Completadas", "Completed"), icon: "checkmark",
                            value: "100%", subtitle: loc.t("Sin errores guardados", "No saved errors"),
                            color: .green)
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
        VStack(alignment: .leading, spacing: 10) {
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
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text("t/s")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color.opacity(0.65))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(result.shortModel).font(.callout.weight(.medium)).lineLimit(1)
                Text(result.configLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary.opacity(0.45))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.25), lineWidth: 1))
        )
    }

    private func summaryStatCard(title: String, icon: String, value: String,
                                 subtitle: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
                    .frame(width: 28, height: 28).background(color.opacity(0.15), in: Circle())
                Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(value).font(.system(size: 29, weight: .bold, design: .rounded)).foregroundStyle(color)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.45))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.25))))
    }

    // MARK: comparison and charts

    private var comparisonA: BenchResult? {
        comparisonAID.flatMap { id in bench.history.first(where: { $0.id == id }) }
            ?? bench.history.first
    }

    private var comparisonB: BenchResult? {
        comparisonBID.flatMap { id in bench.history.first(where: { $0.id == id }) }
            ?? bench.history.dropFirst().first
            ?? bench.history.first
    }

    private func comparisonBinding(primary: Bool) -> Binding<UUID> {
        Binding {
            if primary { return comparisonA?.id ?? UUID() }
            return comparisonB?.id ?? UUID()
        } set: { id in
            if primary { comparisonAID = id } else { comparisonBID = id }
        }
    }

    @ViewBuilder private var comparisonCard: some View {
        if bench.history.count < 2 {
            Card(title: loc.t("Comparación", "Comparison"), icon: "arrow.left.arrow.right") {
                ContentUnavailableView(loc.t("Se necesitan dos resultados", "Two results are required"),
                                       systemImage: "chart.bar.xaxis",
                                       description: Text(loc.t("Ejecuta otro benchmark para comparar.",
                                                               "Run another benchmark to compare.")))
                    .frame(height: 150)
            }
        } else if let first = comparisonA, let second = comparisonB {
            Card(title: loc.t("Comparar ejecuciones", "Compare runs"), icon: "arrow.left.arrow.right") {
                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        comparisonPicker(loc.t("Ejecución A", "Run A"), selection: comparisonBinding(primary: true))
                        Image(systemName: "arrow.left.arrow.right")
                            .foregroundStyle(.secondary).accessibilityHidden(true)
                        comparisonPicker(loc.t("Ejecución B", "Run B"), selection: comparisonBinding(primary: false))
                    }
                    HStack(spacing: 12) {
                        comparisonMetric(title: "Prompt", first: first.pp, second: second.pp,
                                         color: Color.chartSecondary)
                        comparisonMetric(title: loc.t("Generación", "Generation"),
                                         first: first.tg, second: second.tg, color: Color.appAccent)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        comparisonDetails(first, label: "A")
                        comparisonDetails(second, label: "B")
                    }
                }
            }
        }
    }

    private func comparisonPicker(_ title: String, selection: Binding<UUID>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Picker("", selection: selection) {
                ForEach(bench.history) { result in
                    Text("\(result.shortModel) · \(result.quantization) · \(result.date.formatted(date: .abbreviated, time: .shortened))")
                        .tag(result.id)
                }
            }
            .labelsHidden().frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private func comparisonMetric(title: String, first: Double, second: Double, color: Color) -> some View {
        let delta = first == 0 ? 0 : ((second - first) / first) * 100
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Label(String(format: "%+.1f%%", delta),
                      systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(delta >= 0 ? Color.green : Color.orange)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("A").font(.caption).foregroundStyle(.secondary)
                Text(String(format: "%.1f", first)).font(.system(size: 25, weight: .bold, design: .rounded))
                Spacer()
                Text("B").font(.caption).foregroundStyle(.secondary)
                Text(String(format: "%.1f", second)).font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text("t/s").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(maxWidth: .infinity)
        .background(WorkspaceStyle.inset.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.22)))
    }

    private func comparisonDetails(_ result: BenchResult, label: String) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.headline).foregroundStyle(Color.appAccent)
            ModelBrandIcon(name: result.shortModel, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.shortModel).font(.callout.weight(.semibold))
                Text("\(result.quantization) · \(result.configLabel)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(result.gpu ?? "Default GPU").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(10).frame(maxWidth: .infinity)
        .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(WorkspaceStyle.border))
    }

    private var chartsCard: some View {
        let points = Array(bench.history.prefix(24).reversed())
        return Card(title: loc.t("Tendencias de rendimiento", "Performance trends"), icon: "chart.xyaxis.line",
                    trailing: {
                        Text(loc.t("Últimos %@ resultados", "Last %@ results", "\(points.count)"))
                            .font(.caption).foregroundStyle(.secondary)
                    }) {
            HStack(spacing: 14) {
                benchmarkChart(title: "Prompt", points: points, value: \.pp,
                               color: Color.chartSecondary)
                benchmarkChart(title: loc.t("Generación", "Generation"), points: points, value: \.tg,
                               color: Color.appAccent)
            }
        }
    }

    private func benchmarkChart(title: String, points: [BenchResult],
                                value: KeyPath<BenchResult, Double>, color: Color) -> some View {
        let average = points.isEmpty ? 0 : points.reduce(0) { $0 + $1[keyPath: value] } / Double(points.count)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).font(.headline)
                Spacer()
                Text(loc.t("Promedio %@ t/s", "Average %@ t/s", String(format: "%.1f", average)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Chart(points) { result in
                LineMark(x: .value("Date", result.date),
                         y: .value(title, result[keyPath: value]))
                    .foregroundStyle(color)
                    .interpolationMethod(.catmullRom)
                PointMark(x: .value("Date", result.date),
                          y: .value(title, result[keyPath: value]))
                    .foregroundStyle(color)
                    .symbolSize(18)
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 220)
        }
        .padding(12).frame(maxWidth: .infinity)
        .background(WorkspaceStyle.inset.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.18)))
    }

    private var chartCard: some View {
        let recent = Array(bench.history.prefix(8))
        // Generation and prompt live on very different scales; one shared axis
        // would squash the generation bars, so each metric normalizes to its own max.
        let maxTG = recent.map(\.tg).max() ?? 1
        let maxPP = recent.map(\.pp).max() ?? 1
        return Card(title: loc.t("Comparativa (últimas %@ corridas)", "Comparison (last %@ runs)", "\(recent.count)"), icon: "chart.bar") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(recent) { r in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text(r.shortModel).font(.callout.weight(.medium)).lineLimit(1)
                                quantChip(r.quantization)
                                Text(r.configLabel)
                                    .font(.system(size: 10, design: .monospaced))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.quaternary.opacity(0.6), in: Capsule())
                                    .foregroundStyle(.secondary)
                                if let gpu = r.gpu {
                                    Text(gpu).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                                }
                                if let v = r.appVersion {
                                    Text("v\(v)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .help(loc.t("Versión de ToshLLM que hizo esta medición",
                                                    "ToshLLM version that produced this run"))
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
                        }
                    }
                    .padding(.vertical, 3)
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

    private func quantChip(_ quant: String) -> some View {
        Text(quant)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(quant == "—" ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.appAccent))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((quant == "—" ? Color.secondary : Color.appAccent).opacity(0.12), in: Capsule())
            .help(quant == "—"
                  ? loc.t("El resultado antiguo no guardó el quant", "This older result did not store its quant")
                  : loc.t("Quantización del modelo", "Model quantization"))
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
        let visible = Array(bench.history.prefix(historyLimit))
        let lastID = visible.last?.id
        return Card(title: loc.t("Historial completo", "Full history"), icon: "clock",
                    trailing: {
                        HStack(spacing: 12) {
                            Text(loc.t("%@ de %@", "%@ of %@", "\(visible.count)", "\(bench.history.count)"))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            if !bench.history.isEmpty { clearHistoryButton }
                        }
                    }) {
            // Lazy + Equatable rows: offscreen rows aren't built, and visible
            // ones skip re-rendering during the frequent in-run publishes.
            LazyVStack(spacing: 0) {
                ForEach(visible) { r in
                    BenchHistoryRow(r: r, isBest: r.id == bestTG, showsDivider: r.id != lastID,
                                    loc: loc,
                                    onSaveProfile: { promptSave(r) },
                                    onApplyGlobal: { applyGlobal(r) },
                                    onDelete: { bench.delete(r) })
                        .equatable()
                }
            }
            if visible.count < bench.history.count {
                Divider().opacity(0.45)
                BenchmarkLoadMoreButton(remaining: bench.history.count - visible.count,
                                        loc: loc) {
                    historyLimit = min(historyLimit + 20, bench.history.count)
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

private extension View {
    func benchmarkPanel() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(WorkspaceStyle.inset.opacity(0.52), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(WorkspaceStyle.border))
    }
}

/// A lightweight wrapping row for the effective configuration. Unlike a clipped
/// HStack, every active benchmark option remains readable at narrow widths.
private struct BenchmarkWrappingLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? usedWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct BenchmarkLoadMoreButton: View {
    let remaining: Int
    let loc: Localizer
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10, weight: .bold))
                    Text(loc.t("Cargar 20 más", "Load 20 more"))
                    Text("\(remaining)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
            .buttonStyle(GlassPillButtonStyle())
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }
}

/// Native numeric entry keeps keystrokes inside AppKit and commits only when
/// editing ends. Updating the benchmark configuration on every character would
/// otherwise invalidate the history, comparisons and charts around this field.
private struct BenchmarkIntegerField: NSViewRepresentable {
    @Binding var value: Int
    var pointSize: CGFloat = 13

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: String(value))
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: pointSize, weight: .semibold)
        field.focusRingType = .none
        // A formatter rejects non-digits before they are inserted. Filtering in
        // controlTextDidChange instead means reassigning stringValue mid-edit,
        // which tears down the field editor and moves the caret on every key.
        let digits = NumberFormatter()
        digits.numberStyle = .none
        digits.allowsFloats = false
        digits.minimum = 0
        field.formatter = digits
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        guard field.currentEditor() == nil else { return }
        let expected = String(value)
        if field.stringValue != expected { field.stringValue = expected }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: BenchmarkIntegerField
        init(_ parent: BenchmarkIntegerField) { self.parent = parent }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if let number = Int(field.stringValue) { parent.value = number }
            field.stringValue = String(parent.value)
        }
    }
}

private struct BenchmarkResultTableHeader: View {
    let loc: Localizer

    var body: some View {
        HStack(spacing: 12) {
            Text(loc.t("MODELO", "MODEL")).frame(minWidth: 230, maxWidth: .infinity, alignment: .leading)
            Text(loc.t("QUANT", "QUANT")).frame(width: 96, alignment: .leading)
            Text(loc.t("CONFIGURACIÓN / GPU", "CONFIGURATION / GPU"))
                .frame(width: 180, alignment: .leading)
            HStack(spacing: 14) {
                Label("Prompt t/s", systemImage: "circle.fill").foregroundStyle(Color.chartSecondary)
                Label(loc.t("Generación t/s", "Generation t/s"), systemImage: "circle.fill")
                    .foregroundStyle(Color.appAccent)
            }
            .frame(minWidth: 300, maxWidth: .infinity, alignment: .leading)
            Text(loc.t("ACCIONES", "ACTIONS")).frame(width: 92, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 7)
    }
}

private struct BenchmarkResultTableRow: View, Equatable {
    let result: BenchResult
    let isBest: Bool
    let maxPrompt: Double
    let maxGeneration: Double
    let loc: Localizer
    let onSaveProfile: () -> Void
    let onApplyGlobal: () -> Void
    let onDelete: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.result.id == rhs.result.id && lhs.isBest == rhs.isBest
            && lhs.maxPrompt == rhs.maxPrompt && lhs.maxGeneration == rhs.maxGeneration
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                ModelBrandIcon(name: result.shortModel, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(result.shortModel).font(.callout.weight(.semibold)).lineLimit(1)
                        if isBest { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow) }
                        if let fa = result.faLabel {
                            Label(fa, systemImage: "bolt.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.appAccent)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.appAccent.opacity(0.13), in: Capsule())
                                .fixedSize()
                        }
                    }
                    Text(result.date, format: .dateTime.day().month().hour().minute())
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 230, maxWidth: .infinity, alignment: .leading)

            Text(result.quantization)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 96, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(engineLine)
                    .font(.caption.weight(.medium)).lineLimit(1)
                Text(result.gpu ?? loc.t("GPU predeterminada", "Default GPU"))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text(workloadLine)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1)
                Text(storageAndVersionLine)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary).lineLimit(1)
            }
            .frame(width: 180, alignment: .leading)
            .help(completeConfiguration)

            VStack(spacing: 5) {
                tableMetric(value: result.pp, maximum: maxPrompt, color: Color.chartSecondary)
                tableMetric(value: result.tg, maximum: maxGeneration, color: Color.appAccent)
            }
            .frame(minWidth: 300, maxWidth: .infinity)

            HStack(spacing: 4) {
                if result.profile != nil {
                    tableAction("square.and.arrow.down", loc.t("Guardar como perfil", "Save as profile"), onSaveProfile)
                    tableAction("checkmark.circle", loc.t("Aplicar a Ajustes", "Apply to Settings"), onApplyGlobal)
                }
                tableAction("trash", loc.t("Eliminar", "Delete"), destructive: true, onDelete)
            }
            .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private var engineLine: String {
        let engine = result.engine == "bundled" || result.engine == nil
            ? loc.t("Integrado", "Bundled")
            : (result.engine ?? "—")
        return engine
    }

    /// Nil workload values belong to the old on-disk format, whose fixed values
    /// were pp512/tg128/d0. Showing those defaults preserves useful context while
    /// unknown KV/version values remain explicitly unknown.
    private var workloadLine: String {
        let pp = result.ppN ?? 512
        let tg = result.tgN ?? 128
        let depth = result.depth ?? 0
        var values = ["pp\(pp)", "tg\(tg)", "d\(depth)"]
        if let accept = result.accept {
            values.append("MTP \(Int((accept * 100).rounded()))%")
        }
        if let dmoe = result.dmoeK, dmoe > 0 {
            values.append("dMoE K\(dmoe)")
        } else if result.ncmoe > 0 {
            values.append("ncmoe \(result.ncmoe)")
        }
        return values.joined(separator: " · ")
    }

    private var storageAndVersionLine: String {
        let key = result.ctk ?? "—"
        let value = result.ctv ?? "—"
        var values = ["KV \(key)/\(value)", "v\(result.appVersion ?? "—")"]
        if result.peer == true { values.append("IF Link") }
        if result.shared == true { values.append(loc.t("Compartido", "Shared")) }
        return values.joined(separator: " · ")
    }

    private var completeConfiguration: String {
        [engineLine, result.gpu ?? loc.t("GPU predeterminada", "Default GPU"),
         workloadLine, storageAndVersionLine].joined(separator: "\n")
    }

    private func tableMetric(value: Double, maximum: Double, color: Color) -> some View {
        HStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.55))
                    Capsule().fill(color.gradient)
                        .frame(width: max(5, geometry.size.width * value / max(1, maximum)))
                }
            }
            .frame(height: 7)
            Text(String(format: "%.1f", value))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .frame(width: 52, alignment: .trailing)
        }
    }

    private func tableAction(_ image: String, _ help: String, destructive: Bool = false,
                             _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: image) }
            .buttonStyle(HoverIconButtonStyle(tint: destructive ? .red : Color.appAccent))
            .help(help)
    }
}

/// Observes only the coalesced process text. Frequent output updates no longer
/// invalidate the benchmark form, comparison chart, or history rows.
private struct BenchmarkOutputCard: View {
    @ObservedObject var buffer: BenchmarkOutputBuffer
    let loc: Localizer
    let onClose: () -> Void

    var body: some View {
        Card(title: loc.t("Salida de la ejecución", "Run output"), icon: "terminal", trailing: {
            Button(action: onClose) {
                Label(loc.t("Cerrar salida", "Close output"), systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(GlassIconButtonStyle())
            .help(loc.t("Oculta la salida y vuelve a mostrar la información del sistema.",
                        "Hide the output and show system information again."))
        }) {
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    Text(buffer.text.isEmpty ? "…" : buffer.text)
                        .font(.system(size: 10.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("benchEnd")
                }
                .frame(height: 130)
                .onChange(of: buffer.text) { _, _ in proxy.scrollTo("benchEnd", anchor: .bottom) }
            }
        }
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
                    Text(r.quantization)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(r.quantization == "—" ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.appAccent))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((r.quantization == "—" ? Color.secondary : Color.appAccent).opacity(0.12),
                                    in: Capsule())
                        .help(r.quantization == "—"
                              ? loc.t("El resultado antiguo no guardó el quant", "This older result did not store its quant")
                              : loc.t("Quantización del modelo", "Model quantization"))
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
                    if let version = r.appVersion {
                        Text("v\(version)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .help(loc.t("Versión de ToshLLM que hizo esta medición",
                                        "ToshLLM version that produced this run"))
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
