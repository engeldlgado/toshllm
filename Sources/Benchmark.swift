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
    /// Effective Flash Attention route for this run:
    /// "amd-gpu", "standard-cpu", "standard-auto" or "off".
    var fa: String?
    /// GPU that ran this benchmark, and the full config snapshot — the snapshot
    /// lets any past run be saved as a profile, not just the most recent.
    var gpu: String?
    var profile: Profile?
    /// Workload sizes (-p / -n / -d). Nil on older results (pp512/tg128, depth 0).
    var ppN: Int?
    var tgN: Int?
    var depth: Int?
    var kind: String?      // "real" = server generation; nil = raw llama-bench
    var accept: Double?    // MTP acceptance 0-1, real runs only

    var shortModel: String { ModelName(model).title }

    var configLabel: String {
        var parts: [String] = []
        if kind == "real" { parts.append("gen real") }
        if let ppN, let tgN, ppN != 512 || tgN != 128 { parts.append("pp\(ppN)/tg\(tgN)") }
        if let depth, depth > 0 { parts.append("d\(depth)") }
        if let accept { parts.append("MTP \(Int((accept * 100).rounded()))%") }
        if ncmoe > 0 { parts.append("ncmoe \(ncmoe)") }
        if let ctk, ctk != "f16" { parts.append("K:\(ctk)") }
        if let ctv, ctv != "f16" { parts.append("V:\(ctv)") }
        if let faLabel { parts.append(faLabel) }
        if let engine, engine != "bundled" { parts.append(engine) }
        return parts.isEmpty ? "base" : parts.joined(separator: " · ")
    }

    var faLabel: String? {
        switch fa {
        case "amd-gpu": return "FA AMD GPU"
        case "standard-cpu": return "FA CPU"
        case "standard-auto": return "FA auto"
        case "off": return nil
        default: return nil
        }
    }
}

struct SweepSample: Identifiable {
    let ncmoe: Int
    let pp: Double
    let tg: Double
    let vram: Double?

    var id: Int { ncmoe }
}

@MainActor
final class BenchmarkController: ObservableObject {
    @Published var running = false
    @Published var output = ""
    @Published var history: [BenchResult] = []
    @Published var sweeping = false
    @Published var sweepStatus = ""
    @Published var sweepBest: Int?
    @Published var sweepSamples: [SweepSample] = []

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
        FA:     \(settings.benchmarkFlashAttentionLabel)
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

    // MARK: real-generation benchmark

    /// Fixed prompt so runs are comparable across models and sessions.
    static let realPrompt = "Write a complete Python implementation of a thread-safe LRU cache with get, put and eviction. Include docstrings and a short usage example."
    private static let realPort = 18123

    /// Measures against a real llama-server (the path the chat uses, MTP included,
    /// unlike llama-bench): one discarded warm-up, then 3 reps, median. Warm runs
    /// gain ~6% by themselves, so single-shot numbers overstate any change.
    func runReal(settings base: ServerSettings) {
        guard !running, !sweeping else { return }
        guard FileManager.default.fileExists(atPath: base.serverBinary) else {
            output = "llama-server no encontrado / not found: \(base.serverBinary)"
            return
        }
        guard FileManager.default.fileExists(atPath: base.modelPath) else {
            output = "Modelo no encontrado / model not found"
            return
        }

        var s = base
        s.port = Self.realPort
        s.routerMode = false
        s.localNetworkDiscovery = false

        let head = header(for: s).replacingOccurrences(of: "args:", with: "mode:   real generation (llama-server)\nargs:")
        output = head
        fileLog.append(head)
        running = true

        Task {
            defer { running = false; process?.terminate(); process = nil }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: s.serverBinary)
            p.arguments = s.arguments
            p.environment = s.environment
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch {
                emit("→ \(error.localizedDescription)\n")
                return
            }
            process = p

            emit("… cargando modelo / loading model\n")
            guard await waitForHealth(port: s.port, process: p) else {
                emit("→ el servidor no arrancó / server did not start\n")
                return
            }

            emit("… calentamiento (descartado) / warm-up (discarded)\n")
            guard await completeOnce(port: s.port, nPredict: 64) != nil else {
                emit("→ la generación falló / generation failed\n")
                return
            }

            var reps: [(tg: Double, pp: Double, accept: Double?)] = []
            for i in 1...3 {
                guard running, let r = await completeOnce(port: s.port, nPredict: s.benchTGClamped) else { break }
                reps.append(r)
                let acc = r.accept.map { String(format: " · MTP %.0f%%", $0 * 100) } ?? ""
                emit(String(format: "rep %d: %.2f t/s gen · %.1f t/s prompt%@\n", i, r.tg, r.pp, acc))
            }
            guard reps.count == 3 else {
                fileLog.append("→ result: real-generation run incomplete\n\n")
                fileLog.prune()
                return
            }

            let tg = median(reps.map(\.tg))
            let pp = median(reps.map(\.pp))
            let accept = reps.compactMap(\.accept).last
            let name = URL(fileURLWithPath: s.modelPath).lastPathComponent
            let engine = s.serverBinary == ServerSettings.defaultBinary ? "bundled" : "externo"
            history.insert(BenchResult(date: .now, model: name, ncmoe: s.ncmoe, pp: pp, tg: tg,
                                       ctk: s.cacheTypeK, ctv: s.cacheTypeV, engine: engine,
                                       fa: s.benchmarkFlashAttentionRoute,
                                       gpu: s.gpuLabel, profile: base.makeProfile(name: name),
                                       ppN: nil, tgN: s.benchTGClamped,
                                       kind: "real", accept: accept),
                           at: 0)
            save()
            let accLine = accept.map { String(format: " · MTP %.0f%%", $0 * 100) } ?? ""
            emit(String(format: "→ mediana / median: %.2f t/s gen · %.1f t/s prompt%@\n\n", tg, pp, accLine))
            fileLog.prune()
        }
    }

    private func emit(_ text: String) {
        output += text
        fileLog.append(text)
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Polls /health until the model is loaded (large MoE loads take minutes).
    private func waitForHealth(port: Int, process: Process) async -> Bool {
        for _ in 0..<240 {
            guard running, process.isRunning else { return false }
            if let url = URL(string: "http://127.0.0.1:\(port)/health"),
               let (data, _) = try? await URLSession.shared.data(from: url),
               String(data: data, encoding: .utf8)?.contains("ok") == true {
                return true
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    /// One /completion request; greedy and seeded so reps within a run only
    /// differ by machine state, never by sampling.
    private func completeOnce(port: Int, nPredict: Int) async -> (tg: Double, pp: Double, accept: Double?)? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/completion") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "prompt": Self.realPrompt, "n_predict": nPredict,
            "temperature": 0, "seed": 42, "cache_prompt": false,
        ])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["timings"] as? [String: Any],
              let tg = t["predicted_per_second"] as? Double,
              let pp = t["prompt_per_second"] as? Double else { return nil }
        var accept: Double?
        if let dn = t["draft_n"] as? Int, dn > 0, let da = t["draft_n_accepted"] as? Int {
            accept = Double(da) / Double(dn)
        }
        return (tg, pp, accept)
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

        let ppTest = "pp\(settings.benchPPClamped)"
        let tgTest = "tg\(settings.benchTGClamped)"
        if let pp = speed(ppTest), let tg = speed(tgTest) {
            let name = URL(fileURLWithPath: settings.modelPath).lastPathComponent
            let engine = settings.serverBinary == ServerSettings.defaultBinary ? "bundled" : "externo"
            history.insert(BenchResult(date: .now, model: name, ncmoe: settings.ncmoe, pp: pp, tg: tg,
                                       ctk: settings.cacheTypeK, ctv: settings.cacheTypeV, engine: engine,
                                       fa: settings.benchmarkFlashAttentionRoute,
                                       gpu: settings.gpuLabel, profile: settings.makeProfile(name: name),
                                       ppN: settings.benchPPClamped, tgN: settings.benchTGClamped,
                                       depth: settings.benchDepthClamped),
                           at: 0)
            save()
            fileLog.append(String(format: "→ result: %@ = %.1f t/s · %@ = %.1f t/s\n\n", ppTest, pp, tgTest, tg))
        } else {
            fileLog.append("→ result: could not parse \(ppTest)/\(tgTest) (run failed or was cancelled)\n\n")
        }
        fileLog.prune()
    }

    /// Runs llama-bench to completion and returns the parsed speeds plus, when the
    /// verbose load log is present, the fraction of device VRAM the run occupied.
    private func runOnce(settings: ServerSettings, extraArgs: [String] = []) async -> (pp: Double, tg: Double, vram: Double?)? {
        let benchPath = URL(fileURLWithPath: settings.serverBinary)
            .deletingLastPathComponent().appendingPathComponent("llama-bench").path
        guard FileManager.default.fileExists(atPath: benchPath) else { return nil }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: benchPath)
        p.arguments = settings.benchmarkArguments + extraArgs
        p.environment = settings.environment
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("toshllm-sweep-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let outputHandle = try? FileHandle(forWritingTo: outputURL) else { return nil }
        p.standardOutput = outputHandle
        p.standardError = outputHandle

        fileLog.append(header(for: settings))
        await withCheckedContinuation { continuation in
            p.terminationHandler = { _ in continuation.resume() }
            do {
                try p.run()
                self.process = p
            } catch {
                continuation.resume()
            }
        }
        process = nil
        try? outputHandle.close()
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        try? FileManager.default.removeItem(at: outputURL)
        let text = String(data: data, encoding: .utf8) ?? ""
        fileLog.append(text)

        func speed(_ test: String) -> Double? {
            for line in text.split(separator: "\n") where line.contains(" \(test) ") {
                if let r = line.range(of: #"([0-9]+\.[0-9]+) ±"#, options: .regularExpression) {
                    return Double(line[r].split(separator: " ")[0])
                }
            }
            return nil
        }
        guard let pp = speed("pp\(settings.benchPPClamped)"),
              let tg = speed("tg\(settings.benchTGClamped)") else { return nil }
        return (pp, tg, Self.vramFraction(fromLog: text))
    }

    /// Parses the Metal buffer sizes from a verbose llama-bench load log and returns the
    /// fraction of the device's free VRAM they occupy (model + compute + KV + recurrent +
    /// a prefetch-slot allowance), or nil if the log doesn't carry them.
    nonisolated static func vramFraction(fromLog text: String) -> Double? {
        func mib(_ pattern: String) -> Double? {
            guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
            let s = String(text[r])
            return s.split { !$0.isNumber && $0 != "." }.compactMap { Double($0) }.last
        }
        // free VRAM reported at device selection, e.g. "... - 12271 MiB free"
        guard let total = mib(#"[0-9]+ MiB free"#), total > 0, total < 1_000_000 else { return nil }
        guard let model = mib(#"MTL0_Private model buffer size = *[0-9.]+ MiB"#), model > 0 else { return nil }
        let compute = mib(#"MTL0_Private compute buffer size = *[0-9.]+ MiB"#) ?? 0
        let kv = mib(#"MTL0_Private KV buffer size = *[0-9.]+ MiB"#) ?? 0
        let rs = mib(#"MTL0_Private RS buffer size = *[0-9.]+ MiB"#) ?? 0
        // prefetch reserves ~3 VRAM slots of the largest expert tensor; a rough allowance
        // so the fraction reflects real occupancy while prefetch is on.
        let slots = 650.0
        return (model + compute + kv + rs + slots) / total
    }

    nonisolated static func bestSweepCandidate(pp: [Int: Double], vram: [Int: Double], ceiling: Double) -> Int? {
        pp.keys
            .filter { (vram[$0] ?? 0) <= ceiling }
            .max { (pp[$0] ?? 0) < (pp[$1] ?? 0) }
    }

    nonisolated static func sweepHeadroomCandidate(lowestSafe: Int, cliff: Int?, margin: Int = 3) -> Int {
        let preferred = lowestSafe + margin
        guard let cliff else { return preferred }
        return max(lowestSafe, min(preferred, cliff - 1))
    }

    /// Finds the best `--n-cpu-moe` and the prefetch cliff: walks ncmoe down until
    /// prompt speed jumps (the cliff), records it so the server keeps prefetch below
    /// it, and tracks VRAM so it never recommends a saturated setting. Only the
    /// final recommendation is persisted.
    func sweep(settings base: ServerSettings) {
        guard !running, !sweeping, base.ncmoe > 0 else { return }
        sweeping = true
        sweepBest = nil
        sweepSamples = []

        let modelPath = base.modelPath
        // Re-measure from scratch: clearing the stored cliff makes every candidate run
        // with prefetch on (the server gates prefetch below the stored cliff).
        ServerSettings.rememberPrefetchCliff(nil, forModel: modelPath)

        Task {
            let name = URL(fileURLWithPath: modelPath).lastPathComponent
            // Intermediate runs stay internal; only the final recommendation enters history.
            var fast = base
            fast.benchPP = 512
            fast.benchTG = 128
            fast.benchDepth = 0

            var pp: [Int: Double] = [:]
            var tg: [Int: Double] = [:]
            var vram: [Int: Double] = [:]
            let vramCeiling = 0.95   // never descend into (or recommend) a saturated setting

            @MainActor func measure(_ candidate: Int) async -> Double? {
                if let cached = pp[candidate] { return cached }
                var s = fast
                s.ncmoe = candidate
                sweepStatus = "ncmoe \(candidate)…"
                guard let r = await runOnce(settings: s, extraArgs: ["-v"]) else { return nil }
                pp[candidate] = r.pp
                tg[candidate] = r.tg
                if let v = r.vram { vram[candidate] = v }
                sweepSamples.append(SweepSample(ncmoe: candidate, pp: r.pp, tg: r.tg, vram: r.vram))
                return r.pp
            }

            // Find the lowest fast setting that still fits, continuing after any cliff.
            let floorValue = max(0, base.ncmoe - 8)
            var candidate = base.ncmoe
            var prevPp: Double? = nil
            var cliff: Int? = nil
            while candidate >= floorValue {
                guard let cur = await measure(candidate) else { break }
                if cur < 1 { break }
                if let v = vram[candidate], v > vramCeiling { break }
                if cliff == nil, let pv = prevPp, cur >= pv * 1.5 {
                    let middle = candidate + 1
                    if let middlePp = await measure(middle), middlePp >= cur * 0.7 {
                        cliff = middle + 1
                    } else {
                        cliff = middle
                    }
                }
                prevPp = cur
                candidate -= 2
            }

            let safe = pp.keys.filter { (vram[$0] ?? 0) <= vramCeiling }
            let bestPp = safe.compactMap { pp[$0] }.max() ?? 0
            let fastSafe = safe.filter { (pp[$0] ?? 0) >= bestPp * 0.6 }
            guard let lowestSafe = fastSafe.min() else {
                sweepBest = nil
                sweepStatus = pp.isEmpty
                    ? "Sweep sin resultados / sweep produced no results"
                    : "Sweep sin configuración VRAM segura / no VRAM-safe result"
                sweeping = false
                fileLog.prune()
                return
            }

            // Move three steps away from the VRAM-tight edge without crossing a known cliff.
            var recommended = Self.sweepHeadroomCandidate(lowestSafe: lowestSafe, cliff: cliff)
            if await measure(recommended) == nil {
                let target = recommended
                recommended = fastSafe.min {
                    abs($0 - target) < abs($1 - target)
                } ?? lowestSafe
            }

            while recommended > lowestSafe,
                  ((vram[recommended] ?? 0) > vramCeiling || (pp[recommended] ?? 0) < bestPp * 0.6) {
                cliff = min(cliff ?? recommended, recommended)
                recommended -= 1
                _ = await measure(recommended)
            }

            if let cliff {
                ServerSettings.rememberPrefetchCliff(cliff, forModel: modelPath)
            }

            guard let finalPp = pp[recommended], let finalTg = tg[recommended] else {
                sweepBest = nil
                sweepStatus = "Sweep sin resultados / sweep produced no results"
                sweeping = false
                fileLog.prune()
                return
            }

            var finalSettings = fast
            finalSettings.ncmoe = recommended
            let engine = finalSettings.serverBinary == ServerSettings.defaultBinary ? "bundled" : "externo"
            history.insert(BenchResult(date: .now, model: name, ncmoe: recommended,
                                       pp: finalPp, tg: finalTg,
                                       ctk: finalSettings.cacheTypeK, ctv: finalSettings.cacheTypeV,
                                       engine: engine, fa: finalSettings.benchmarkFlashAttentionRoute,
                                       gpu: finalSettings.gpuLabel,
                                       profile: finalSettings.makeProfile(name: "\(name) ncmoe \(recommended)"),
                                       ppN: finalSettings.benchPPClamped, tgN: finalSettings.benchTGClamped),
                           at: 0)
            save()

            sweepBest = recommended
            let vpct = vram[recommended].map { String(format: " · VRAM %.0f%%", $0 * 100) } ?? ""
            if let cliff {
                sweepStatus = String(format: "Óptimo: ncmoe %d (%.0f pp)%@ · cliff %d, prefetch off ≥%d",
                                     recommended, finalPp, vpct, cliff, cliff)
            } else {
                sweepStatus = String(format: "Óptimo: ncmoe %d (%.0f pp)%@", recommended, finalPp, vpct)
            }
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
