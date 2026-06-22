import Foundation

struct BenchResult: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let model: String
    let ncmoe: Int
    let pp: Double
    let tg: Double
    // optional for backward compatibility with older saved results
    var ctk: String?
    var ctv: String?
    var engine: String?
    /// GPU that ran this benchmark, and the full config snapshot — the snapshot
    /// lets any past run be saved as a profile, not just the most recent.
    var gpu: String?
    var profile: Profile?

    var shortModel: String {
        model.replacingOccurrences(of: ".gguf", with: "")
            .replacingOccurrences(of: "-Instruct", with: "")
            .replacingOccurrences(of: "-2507", with: "")
            .replacingOccurrences(of: "-UD", with: "")
    }

    var configLabel: String {
        var parts: [String] = []
        if ncmoe > 0 { parts.append("ncmoe \(ncmoe)") }
        if let ctk, ctk != "f16" { parts.append("K:\(ctk)") }
        if let ctv, ctv != "f16" { parts.append("V:\(ctv)") }
        if let engine, engine != "bundled" { parts.append(engine) }
        return parts.isEmpty ? "base" : parts.joined(separator: " · ")
    }
}

@MainActor
final class BenchmarkController: ObservableObject {
    @Published var running = false
    @Published var output = ""
    @Published var history: [BenchResult] = []
    @Published var sweeping = false
    @Published var sweepStatus = ""
    @Published var sweepBest: Int?

    private var process: Process?
    private let storeKey = "benchHistory"
    /// Persists every run (full header + llama-bench output) to one `benchmarks.txt`,
    /// pruned to the last 3 days, so a shareable history survives restarts and a
    /// crash still leaves the run on file.
    private let fileLog = BenchmarkLog(retentionDays: 3)

    var benchLogURL: URL { fileLog.url }
    var benchLogDirectory: URL { fileLog.directory }

    init() { load() }

    /// Run header with date, GPU and the exact config — the same text shown on
    /// screen and written to the log file, so a shared log is self-describing.
    private func header(for settings: ServerSettings) -> String {
        let model = URL(fileURLWithPath: settings.modelPath).lastPathComponent
        return """
        === ToshLLM benchmark · \(Date().formatted(.iso8601)) ===
        model:  \(model)
        GPU:    \(settings.gpuLabel)
        engine: \(settings.engineTag)\(settings.ncmoe > 0 ? " · ncmoe \(settings.ncmoe)" : "") · K:\(settings.cacheTypeK) V:\(settings.cacheTypeV)
        args:   \(settings.benchmarkArguments.joined(separator: " "))
        =========================

        """
    }

    func run(settings: ServerSettings) {
        guard !running else { return }
        let benchPath = URL(fileURLWithPath: settings.serverBinary)
            .deletingLastPathComponent().appendingPathComponent("llama-bench").path
        guard FileManager.default.fileExists(atPath: benchPath) else {
            output = "llama-bench no encontrado / not found: \(benchPath)"
            return
        }
        guard FileManager.default.fileExists(atPath: settings.modelPath) else {
            output = "Modelo no encontrado / model not found"
            return
        }

        // Header so both the on-screen log and the saved file record which GPU and
        // config produced the run.
        let head = header(for: settings)
        output = head
        fileLog.append(head)
        running = true

        let p = Process()
        p.executableURL = URL(fileURLWithPath: benchPath)
        p.arguments = settings.benchmarkArguments
        p.environment = settings.environment

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let log = fileLog
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            log.append(text)
            Task { @MainActor in self?.output += text }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.finish(settings: settings) }
        }

        do {
            try p.run()
            process = p
        } catch {
            output = error.localizedDescription
            running = false
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
        running = false
    }

    private func finish(settings: ServerSettings) {
        running = false
        process = nil

        func speed(_ test: String) -> Double? {
            for line in output.split(separator: "\n") where line.contains(" \(test) ") {
                if let r = line.range(of: #"([0-9]+\.[0-9]+) ±"#, options: .regularExpression) {
                    return Double(line[r].split(separator: " ")[0])
                }
            }
            return nil
        }

        if let pp = speed("pp512"), let tg = speed("tg128") {
            let name = URL(fileURLWithPath: settings.modelPath).lastPathComponent
            let engine: String
            if settings.serverBinary == ServerSettings.defaultBinary {
                engine = "bundled"
            } else if settings.serverBinary == ServerSettings.turboBinary {
                engine = "turbo"
            } else {
                engine = "externo"
            }
            history.insert(BenchResult(date: .now, model: name, ncmoe: settings.ncmoe, pp: pp, tg: tg,
                                       ctk: settings.cacheTypeK, ctv: settings.cacheTypeV, engine: engine,
                                       gpu: settings.gpuLabel, profile: settings.makeProfile(name: name)),
                           at: 0)
            save()
            fileLog.append(String(format: "→ result: pp512 = %.1f t/s · tg128 = %.1f t/s\n\n", pp, tg))
        } else {
            fileLog.append("→ result: could not parse pp512/tg128 (run failed or was cancelled)\n\n")
        }
        fileLog.prune()
    }

    /// Runs llama-bench to completion and returns the parsed speeds.
    private func runOnce(settings: ServerSettings) async -> (pp: Double, tg: Double)? {
        let benchPath = URL(fileURLWithPath: settings.serverBinary)
            .deletingLastPathComponent().appendingPathComponent("llama-bench").path
        guard FileManager.default.fileExists(atPath: benchPath) else { return nil }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: benchPath)
        p.arguments = settings.benchmarkArguments
        p.environment = settings.environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        fileLog.append(header(for: settings))
        let text: String = await withCheckedContinuation { continuation in
            p.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do { try p.run(); self.process = p } catch { continuation.resume(returning: "") }
        }
        process = nil
        fileLog.append(text)

        func speed(_ test: String) -> Double? {
            for line in text.split(separator: "\n") where line.contains(" \(test) ") {
                if let r = line.range(of: #"([0-9]+\.[0-9]+) ±"#, options: .regularExpression) {
                    return Double(line[r].split(separator: " ")[0])
                }
            }
            return nil
        }
        guard let pp = speed("pp512"), let tg = speed("tg128") else { return nil }
        return (pp, tg)
    }

    /// Finds the best `--n-cpu-moe` automatically: starts at the configured
    /// value and walks down (more experts on GPU) until VRAM saturation makes
    /// performance collapse, recording every run in the history.
    func sweep(settings base: ServerSettings) {
        guard !running, !sweeping, base.ncmoe > 0 else { return }
        sweeping = true
        sweepBest = nil

        Task {
            var best: (ncmoe: Int, tg: Double)?
            var candidate = base.ncmoe
            let floorValue = max(0, base.ncmoe - 8)
            let name = URL(fileURLWithPath: base.modelPath).lastPathComponent

            while candidate >= floorValue {
                var settings = base
                settings.ncmoe = candidate
                sweepStatus = "ncmoe \(candidate)…"

                guard let result = await runOnce(settings: settings) else { break }
                let engine = settings.serverBinary == ServerSettings.defaultBinary ? "bundled"
                    : settings.serverBinary == ServerSettings.turboBinary ? "turbo" : "externo"
                history.insert(BenchResult(date: .now, model: name, ncmoe: candidate,
                                           pp: result.pp, tg: result.tg,
                                           ctk: settings.cacheTypeK, ctv: settings.cacheTypeV,
                                           engine: engine, gpu: settings.gpuLabel,
                                           profile: settings.makeProfile(name: "\(name) ncmoe \(candidate)")),
                               at: 0)
                save()

                if let current = best {
                    // VRAM saturation shows up as a sharp drop; stop one step late.
                    if result.tg < current.tg * 0.90 || result.pp < 1 {
                        break
                    }
                    if result.tg > current.tg { best = (candidate, result.tg) }
                } else {
                    best = (candidate, result.tg)
                }
                candidate -= 2
            }

            sweepBest = best?.ncmoe
            sweepStatus = best.map { String(format: "Óptimo: ncmoe %d (%.1f t/s)", $0.ncmoe, $0.tg) }
                ?? "Sweep sin resultados / sweep produced no results"
            sweeping = false
            fileLog.prune()
        }
    }

    func cancelSweep() {
        process?.terminate()
        sweeping = false
        sweepStatus = ""
    }

    func delete(_ result: BenchResult) {
        history.removeAll { $0.id == result.id }
        save()
    }

    func clearHistory() {
        history.removeAll()
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let h = try? JSONDecoder().decode([BenchResult].self, from: data) else { return }
        history = h
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }
}
