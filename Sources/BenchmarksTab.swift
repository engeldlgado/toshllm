import SwiftUI
import Charts

// MARK: - Benchmarks

struct BenchmarksView: View {
    @EnvironmentObject var bench: BenchmarkController
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""
    @AppStorage(SettingsKeys.ncmoe) private var ncmoe = 0
    @AppStorage(SettingsKeys.cacheTypeK) private var cacheTypeK = "f16"
    @AppStorage(SettingsKeys.cacheTypeV) private var cacheTypeV = "f16"
    @AppStorage(SettingsKeys.serverBinary) private var serverBinary = ServerSettings.defaultBinary

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

                if bench.running || bench.sweeping {
                    ProgressView().controlSize(.small)
                    if bench.sweeping {
                        Text(bench.sweepStatus).font(.caption).foregroundStyle(.secondary)
                        Button(loc.t("Cancelar", "Cancel"), role: .destructive) { bench.cancelSweep() }
                    } else {
                        Button(loc.t("Cancelar", "Cancel"), role: .destructive) { bench.cancel() }
                    }
                } else {
                    Button {
                        bench.sweep(settings: .fromDefaults())
                    } label: {
                        Label(loc.t("Buscar óptimo", "Find optimum"), systemImage: "scope")
                    }
                    .disabled(modelPath.isEmpty || ncmoe == 0 || server.state == .running || server.state == .starting)
                    .help(loc.t("Solo modelos MoE: prueba varios valores de 'Expertos en CPU' bajando hasta detectar la saturación de VRAM, y reporta el mejor. Tarda varios minutos.",
                                "MoE models only: tries several 'experts on CPU' values going down until VRAM saturates, then reports the best. Takes several minutes."))
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

            if let best = bench.sweepBest, !bench.sweeping {
                HStack {
                    Label(bench.sweepStatus, systemImage: "scope")
                        .font(.callout).foregroundStyle(.pink)
                    Button(loc.t("Aplicar ncmoe \(best)", "Apply ncmoe \(best)")) {
                        ncmoe = best
                        bench.sweepBest = nil
                    }
                    .controlSize(.small)
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
