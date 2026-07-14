import Foundation
import Metal

extension Notification.Name {
    /// Posted when a fresh engine process has launched (KV slots are empty).
    static let engineDidStart = Notification.Name("toshEngineDidStart")
}

struct GPUDevice: Identifiable, Hashable {
    let index: Int
    let name: String
    let vramMB: Int
    var isExternal: Bool = false   // eGPU (MTLDeviceLocation.external)
    var isIntegrated: Bool = false // iGPU (MTLDevice.isLowPower); never auto-selected
    var id: Int { index }
}

struct ServerSettings {
    var serverBinary: String
    var modelPath: String
    var port: Int
    var ngl: Int
    var ncmoe: Int
    var ctx: Int
    var threads: Int
    var flashAttn: String      // auto | on | off
    var noMmap: Bool
    var jinja: Bool
    var concurrencyDisable: Bool
    var vramReserveMB: Int
    var gpuIndex: Int          // -1 = system default
    /// Explicit set of physical GPUs to split across (2+ entries). Overrides
    /// `gpuIndex` and the all/N `multiGPU` split.
    var gpuList: [Int] = []
    var extraArgs: String
    /// Serve /v1/embeddings (--embeddings). llama-server restricts the process
    /// to embedding use, so it's meant for a dedicated embedding-model server.
    var embeddings: Bool = false
    var cacheTypeK: String     // f16 | q8_0 | q5_x | q4_x | iq4_nl
    var cacheTypeV: String
    var mlock: Bool
    /// Host-RAM prompt cache cap in MiB (0 disables). llama-server defaults to
    /// 8192 MiB, which next to a large model pushes 32 GB machines into swap
    /// and progressively degrades generation speed.
    var cacheRAM: Int = 2048
    /// Emit reasoning inline in `content` (<think>…) instead of the separate
    /// `reasoning_content` field, for external clients that ignore the latter.
    var reasoningInline: Bool = false
    /// Server slots (0 = engine auto, currently 4). With 1, requests queue
    /// instead of competing for the GPU, and a prefill aborted by a client
    /// timeout stays in the slot so the retry resumes where it left off —
    /// crucial for coding assistants that send huge prompts.
    var parallelSlots: Int = 1
    var apiKeyEnabled: Bool = false
    /// Expose the HTTP server beyond loopback and advertise it with Bonjour.
    /// Off by default: when enabled, any device on the local network can reach
    /// the OpenAI-compatible API, so pairing it with `apiKeyEnabled` is strongly
    /// recommended.
    var localNetworkDiscovery: Bool = false
    /// Legacy profile field kept for decoding older saved settings. MTP is now
    /// selected automatically from model capability and expert offload.
    var specMTP: Bool = false
    /// Experimental: route attention through the dedicated AMD Metal
    /// Flash-Attention kernel (gated by the TOSH_FA_AMD env var in the engine).
    /// Forces `-fa 1`, but the patched engine routes supported AMD cases to TOSH_FA_AMD.
    var faAmd: Bool = true
    /// MoE-offload prefill boost: upload expert weights through a second Metal
    /// queue overlapping compute (GGML_SCHED_PREFETCH_EXPERTS) and keep CPU
    /// experts unpacked so their matmuls can offload (GGML_CPU_NO_REPACK).
    var prefetchExperts: Bool = true
    /// Router mode (`--models-preset`): one process auto-loads/unloads whichever
    /// model a request's "model" field names, instead of the fixed `modelPath`.
    var routerMode: Bool = false
    /// Models the router keeps loaded at once (LRU); 1 is safest on a single GPU.
    var routerModelsMax: Int = 1
    /// Persist each conversation's KV cache to disk (`--slot-save-path`) so
    /// reopening a chat — or restarting the app/engine — skips re-processing the
    /// prompt. Only effective on the turbo engine with the AMD FA kernel: without
    /// FA, llama.cpp stores the V cache transposed and slot save/restore copies it
    /// row-by-row, which on AMD's staging path is unusably slow (~13 s vs ~0.1 s).
    /// Gated to the turbo engine in Settings.
    var persistCache: Bool = false
    /// EXPERIMENTAL, needs more testing. Split one model's layers across all
    /// detected GPUs (`--split-mode layer`) instead of pinning to one. The modern
    /// Metal backend registers each AMD GPU as a separate device (MTL0, MTL1…), so
    /// this is possible in principle, but it is UNVALIDATED on AMD/Metal: cross-GPU
    /// copies are a different path than the host↔device staging the patch covers and
    /// could corrupt or deadlock. Works the same on both engines. Off by default.
    var multiGPU: Bool = false
    /// How many GPUs to split across when `multiGPU` is on. 0 = all detected.
    /// Fewer GPUs can generate faster (less cross-card sync) at the cost of prompt
    /// speed, which the #16 tester asked to control per workload.
    var multiGPUCount: Int = 0
    /// Force VRAM-resident (private) Metal buffers. The backend forces shared
    /// (system-memory) buffers for external GPUs, which streams weights over
    /// Thunderbolt every op (~0.8 t/s); this overrides that for the default-GPU
    /// case where the app can't tell macOS picked an eGPU. Off by default.
    var forcePrivateBuffers: Bool = false
    /// Reuse shifted KV chunks across mid-prompt divergences (agent edits, a
    /// stripped <think> block). Fast but approximate — the KV shift is not a
    /// bit-exact reconstruction — so the user can turn it off for exact results.
    /// Force-disabled for turbo2/3/4 KV (crashes on a shift). On by default.
    var cacheReuse: Bool = true
    /// Load the multimodal projector (mmproj) for vision-capable models. Off skips it
    /// so a vision model runs text-only and frees the VRAM the image encoder would use.
    var loadVision: Bool = true
    /// llama-bench workload sizes: prompt tokens (-p → ppN) and generated tokens
    /// (-n → tgN). Benchmark-only; llama-server ignores them.
    var benchPP: Int = 512
    var benchTG: Int = 128

    /// True when the selected binary is the bundled or dev turbo engine.
    static func isTurbo(_ binary: String) -> Bool {
        binary.contains("bin-turbo") || binary == turboBinary
    }
    var isTurboEngine: Bool { Self.isTurbo(serverBinary) }
    var isMultimodal: Bool { Self.mmprojPath(forModel: modelPath) != nil }

    /// Directory where one server's per-conversation KV slot files live. Namespaced
    /// by port so independent servers don't overwrite each other's slot 0 / prefix
    /// files in a shared folder.
    static func slotCacheDir(port: Int) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ToshLLM/slots/\(port)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Slot directory of the primary server (the one the native chat talks to).
    static var primarySlotCacheDir: URL { slotCacheDir(port: fromDefaults().port) }

    static let defaultFaAmd = true
    static let kvCacheTypes = ["f16", "q8_0", "q5_1", "q5_0", "q4_1", "q4_0", "iq4_nl"]

    var arguments: [String] {
        if routerMode { return routerArguments }
        // Quantized KV requires FA, so it stays forced. The AMD kernel rides on
        // "auto": the engine keeps FA on GPU where the kernel covers the model
        // (head 128/256/512) and disables it elsewhere, never the CPU fallback
        // that an explicit "1" causes on uncovered models.
        let faValue = kvNeedsFlashAttention ? "1" : (effectiveFaAmd ? "auto" : flashAttn)
        var args = [
            "-m", modelPath,
            "-ngl", String(ngl),
            "-c", String(ctx),
            "-t", String(threads),
            "-fa", faValue,
            "--host", localNetworkDiscovery ? "0.0.0.0" : "127.0.0.1",
            "--port", String(port),
        ]
        if ncmoe > 0 { args += ["--n-cpu-moe", String(ncmoe)] }
        if noMmap { args.append("--no-mmap") }
        // Vision: if the model has a sibling multimodal projector, load it so the
        // model can read attached images. Requires the chat template (--jinja).
        // Skipped when the user wants text-only, to free the image encoder's VRAM.
        let mmproj = loadVision ? Self.mmprojPath(forModel: modelPath) : nil
        if let mmproj { args += ["--mmproj", mmproj] }
        if jinja || mmproj != nil { args.append("--jinja") }
        if cacheTypeK != "f16" { args += ["-ctk", cacheTypeK] }
        if cacheTypeV != "f16" { args += ["-ctv", cacheTypeV] }
        if mlock { args.append("--mlock") }
        args += ["--cache-ram", String(cacheRAM)]
        // Reuse shifted KV chunks when a prompt diverges mid-way: agent clients
        // edit their prompts between turns, and a reasoning turn's <think> is
        // stripped from the resent history (a removed middle chunk) — KV shifting
        // skips re-prefilling it. Fast but approximate (the shifted KV isn't a
        // bit-exact reconstruction), so it's user-toggleable. Safe with f16 and
        // standard quantized KV (q8_0/q4_0), including the AMD FA kernel; the
        // TurboQuant rotation types (turbo2/3/4) still crash on a shift (no
        // f32->turbo requantize kernel), so it's force-disabled for those.
        let turboKV = cacheTypeK.hasPrefix("turbo") || cacheTypeV.hasPrefix("turbo")
        if cacheReuse && !turboKV && mmproj == nil {
            args += ["--cache-reuse", "256"]
        }
        if parallelSlots > 0 { args += ["--parallel", String(parallelSlots)] }
        // With an explicit --parallel N (N>1), llama-server splits the context
        // pool across slots (e.g. 16384 → 8192 each) instead of sharing it; only
        // --parallel "auto" auto-enables unified KV. Pass --kv-unified ourselves so
        // the N slots share one pool: the main chat keeps the full context window
        // and concurrent API requests don't multiply KV memory.
        if parallelSlots > 1 { args.append("--kv-unified") }
        // EXPERIMENTAL multi-GPU: split layers across the detected Metal devices
        // (all/N via multiGPU, or the explicit gpuList set). Device selection is
        // done through the env vars below.
        if multiGPU || gpuList.count >= 2 { args += ["--split-mode", "layer"] }
        if embeddings { args.append("--embeddings") }
        // Persist KV slots to disk so reopening a chat skips re-prefill. Only on
        // the turbo engine, where the AMD FA kernel keeps the V cache contiguous
        // (the official engine's transposed-V save/restore is unusably slow on AMD).
        if persistCache && isTurboEngine {
            args += ["--slot-save-path", Self.slotCacheDir(port: port).path]
        }
        if reasoningInline { args += ["--reasoning-format", "none"] }
        if apiKeyEnabled { args += ["--api-key", Keychain.apiKey()] }
        if ncmoe > 0 && Self.modelHasMTP(at: modelPath) {
            args += ["--spec-type", "draft-mtp"]
        }
        if let ui = Self.chatUIPath { args += ["--path", ui] }
        args += extraArgTokens.cli
        return args
    }

    /// Router-mode CLI args: no `-m`, the preset file lists every model. Per-model
    /// flags (mmproj, ncmoe, MTP...) live in that INI instead, see `routerPresetINI`.
    private var routerArguments: [String] {
        var args = [
            "--models-preset", Self.routerPresetPath(port: port).path,
            "--models-max", String(routerModelsMax),
            "--models-autoload",
            "--host", localNetworkDiscovery ? "0.0.0.0" : "127.0.0.1",
            "--port", String(port),
        ]
        if apiKeyEnabled { args += ["--api-key", Keychain.apiKey()] }
        if let ui = Self.chatUIPath { args += ["--path", ui] }
        return args
    }

    /// Same folder `ModelStore` scans (`~/models` or the custom override),
    /// resolved independently since `ServerController` has no `ModelStore`.
    static var modelsDirectory: URL {
        let custom = UserDefaults.standard.string(forKey: SettingsKeys.modelsDir) ?? ""
        return custom.isEmpty ? ModelStore.defaultDirectory : URL(fileURLWithPath: custom, isDirectory: true)
    }

    static func routerPresetPath(port: Int) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ToshLLM/router")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("preset-\(port).ini")
    }

    /// Stable, INI/URL-safe id derived from a model's filename: the router
    /// preset's section name and the value clients send as `"model"`.
    static func routerAlias(for modelPath: String) -> String {
        let base = URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
        var slug = String(base.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "model" : slug
    }

    /// Builds the router's `--models-preset` INI: one `[alias]` section per model,
    /// shared engine config plus per-path ncmoe/mmproj/MTP. `extraArgs` (free-form
    /// CLI tokens) isn't representable generically here, so it's skipped.
    func routerPresetINI(modelPaths: [String], ncmoeByPath: [String: Int]) -> String {
        // Same FA policy as `arguments`: force only for quantized KV.
        let faValue = kvNeedsFlashAttention ? "on" : (effectiveFaAmd ? "auto" : flashAttn)
        let turboKV = cacheTypeK.hasPrefix("turbo") || cacheTypeV.hasPrefix("turbo")
        var seenAliases = Set<String>()
        var sections: [String] = []
        for path in modelPaths.sorted() {
            var alias = Self.routerAlias(for: path)
            if seenAliases.contains(alias) { alias += "-\(abs(path.hashValue) % 1000)" }
            seenAliases.insert(alias)

            var lines = ["[\(alias)]", "model = \(path)", "n-gpu-layers = \(ngl)",
                         "ctx-size = \(ctx)", "threads = \(threads)", "flash-attn = \(faValue)"]
            if let ncmoe = ncmoeByPath[path], ncmoe > 0 { lines.append("n-cpu-moe = \(ncmoe)") }
            if noMmap { lines.append("no-mmap = true") }
            let mmproj = loadVision ? Self.mmprojPath(forModel: path) : nil
            if let mmproj { lines.append("mmproj = \(mmproj)") }
            if jinja || mmproj != nil { lines.append("jinja = true") }
            if cacheTypeK != "f16" { lines.append("cache-type-k = \(cacheTypeK)") }
            if cacheTypeV != "f16" { lines.append("cache-type-v = \(cacheTypeV)") }
            if mlock { lines.append("mlock = true") }
            lines.append("cache-ram = \(cacheRAM)")
            if cacheReuse && !turboKV && mmproj == nil { lines.append("cache-reuse = 256") }
            if parallelSlots > 0 { lines.append("parallel = \(parallelSlots)") }
            if parallelSlots > 1 { lines.append("kv-unified = true") }
            if multiGPU || gpuList.count >= 2 { lines.append("split-mode = layer") }
            if persistCache && isTurboEngine {
                lines.append("slot-save-path = \(Self.slotCacheDir(port: port).appendingPathComponent(alias).path)")
            }
            if reasoningInline { lines.append("reasoning-format = none") }
            if (ncmoeByPath[path] ?? 0) > 0 && Self.modelHasMTP(at: path) {
                lines.append("spec-type = draft-mtp")
            }
            sections.append(lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    /// Splits the Extra arguments field: a token shaped like `KEY=VALUE` whose name
    /// is an UPPERCASE env-style identifier (`[A-Z_][A-Z0-9_]*`) becomes an environment
    /// variable — so an advanced user can flip an engine env knob (e.g.
    /// `GGML_METAL_WAVE64_SAFEMODE=1` for GCN/Vega cards) without a dedicated UI field.
    /// Everything else stays a llama-server CLI argument, including lowercase flag
    /// values that contain `=` (e.g. `--override-kv key=str:foo`), which is why the
    /// name must be uppercase to qualify as env.
    var extraArgTokens: (env: [String: String], cli: [String]) {
        func isEnvName(_ s: Substring) -> Bool {
            guard let first = s.first, first == "_" || (first.isLetter && first.isUppercase) else { return false }
            return s.allSatisfy { $0 == "_" || $0.isNumber || ($0.isLetter && $0.isUppercase) }
        }
        var env: [String: String] = [:]
        var cli: [String] = []
        for tok in ShellWords.split(extraArgs) {
            if let eq = tok.firstIndex(of: "="), eq != tok.startIndex, isEnvName(tok[..<eq]) {
                env[String(tok[..<eq])] = String(tok[tok.index(after: eq)...])
            } else {
                cli.append(tok)
            }
        }
        return (env, cli)
    }

    /// Arguments for `llama-bench`. Kept separate from `llama-server` arguments
    /// because server-only flags (`--host`, `--port`, chat UI, slot cache, etc.)
    /// are not valid for the benchmark tool, but benchmark must still honor the
    /// GPU/memory options that affect performance.
    var benchmarkArguments: [String] {
        var args = ["-m", modelPath, "-ngl", String(ngl), "--mmap", "0", "-r", "2",
                    "-p", String(benchPPClamped), "-n", String(benchTGClamped)]
        if ncmoe > 0 { args += ["-ncmoe", String(ncmoe)] }
        if cacheTypeK != "f16" { args += ["-ctk", cacheTypeK] }
        if cacheTypeV != "f16" { args += ["-ctv", cacheTypeV] }
        if kvNeedsFlashAttention || flashAttn == "on" {
            args += ["-fa", "1"]
        } else if effectiveFaAmd {
            args += ["-fa", "auto"]
        }
        if multiGPU || gpuList.count >= 2 { args += ["--split-mode", "layer"] }
        return args
    }

    /// Workload sizes kept within what llama-bench accepts and a Mac can finish.
    var benchPPClamped: Int { min(max(benchPP, 16), 32768) }
    var benchTGClamped: Int { min(max(benchTG, 16), 8192) }

    /// Human-readable name of the GPU a run actually used, for the benchmark
    /// record. Resolves the macOS-picked default to its real device name.
    var gpuLabel: String {
        let gpus = ServerController.availableGPUs()
        if gpuList.count >= 2 { return "Split · \(gpuList.count) GPUs" }
        if multiGPU {
            let discrete = gpus.filter { !$0.isIntegrated }.count
            let limit = discrete > 0 ? discrete : gpus.count
            let n = multiGPUCount > 0 ? min(multiGPUCount, limit) : limit
            return "Split · \(max(2, n)) GPUs"
        }
        if gpuIndex >= 0 { return gpus.first { $0.index == gpuIndex }?.name ?? "GPU \(gpuIndex)" }
        return MTLCreateSystemDefaultDevice()?.name ?? "default"
    }

    /// Web chat UI bundled with the app (served via llama-server --path).
    static var chatUIPath: String? {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("test-ui").path,
              FileManager.default.fileExists(atPath: bundled + "/index.html") else { return nil }
        return bundled
    }

    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["GGML_METAL_CONCURRENCY_DISABLE"] = concurrencyDisable ? "1" : nil
        env["GGML_METAL_VRAM_RESERVE_MB"] = String(vramReserveMB)
        // Physical GPU selection (consumed by the patched Metal backend, which maps
        // these to MTLCopyAllDevices() — the same order as the app's GPU picker).
        let gpus = ServerController.availableGPUs()
        if gpuList.count >= 2 {
            // Split across exactly these GPUs; slot i maps to the i-th listed index.
            env["GGML_METAL_DEVICE_LIST"] = gpuList.map(String.init).joined(separator: ",")
        } else if multiGPU {
            // Split across N GPUs. Fewer than all lets the user trade prompt speed
            // (more GPUs) for generation speed (fewer, less cross-card sync). 0 = all.
            // Integrated iGPUs don't count: the engine skips them when mapping slots.
            let discrete = gpus.filter { !$0.isIntegrated }.count
            let limit = discrete > 0 ? discrete : gpus.count
            let n = multiGPUCount > 0 ? min(multiGPUCount, limit) : limit
            env["GGML_METAL_DEVICES"] = String(max(2, n))
        } else if gpuIndex >= 0 {
            // Pin the engine to one physical GPU by index.
            env["GGML_METAL_DEVICE_INDEX"] = String(gpuIndex)
        }
        // eGPU fix: the Metal backend forces system-memory (shared) buffers for external
        // GPUs, so weights stream over Thunderbolt every op (~0.8 t/s). Forcing private
        // VRAM-resident buffers restores normal speed. Auto-enable it when the selected
        // card is external; the manual override covers the default case (macOS picks).
        let splittingList = gpuList.count >= 2
        let selectedExternal = !multiGPU && !splittingList && gpuIndex >= 0
            && gpus.first { $0.index == gpuIndex }?.isExternal == true
        let anyExternalInSplit = (multiGPU && !splittingList && gpus.contains { $0.isExternal })
            || (splittingList && gpus.contains { gpuList.contains($0.index) && $0.isExternal })
        if forcePrivateBuffers || selectedExternal || anyExternalInSplit {
            env["GGML_METAL_SHARED_BUFFERS_DISABLE"] = "1"
        }
        if effectiveFaAmd { env["TOSH_FA_AMD"] = "1" }
        // Router mode has no single ncmoe (it's per-model, in the preset INI);
        // the envs are harmless no-ops for dense models, gated per-op internally.
        if prefetchExperts && (ncmoe > 0 || routerMode) {
            // At/above the measured per-model cliff the prefetch overlap collapses and
            // the GPU stalls (slower than plain repack), so only enable it below the
            // cliff. Router mode carries per-model ncmoe in the INI, so keep it on there.
            let cliff = Self.recalledPrefetchCliff(forModel: modelPath)
            if routerMode || cliff == nil || ncmoe < cliff! {
                env["GGML_SCHED_PREFETCH_EXPERTS"] = "1"
                env["GGML_CPU_NO_REPACK"] = "1"
            }
        }
        // KEY=VALUE tokens from Extra arguments become env vars (e.g. the GCN/Vega
        // wave64 safe-mode flag). Applied last so the user can override the above.
        for (k, v) in extraArgTokens.env { env[k] = v }
        return env.compactMapValues { $0 }
    }

    /// Metal concurrency is stable and faster on Apple Silicon, but it corrupts
    /// output on discrete AMD GPUs (Intel Macs / Hackintosh), where it must stay off.
    static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return value == 1
    }()

    static var defaultConcurrencyDisable: Bool { !isAppleSilicon }


    /// Default engine: the one bundled with the app (portable); falls back to the dev checkout.
    static var defaultBinary: String {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/llama-server").path,
           FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        // patched master build: supports recent architectures (qwen35moe / Qwen 3.6)
        return NSString(string: "~/dev/repositorios/llama.cpp/build/bin/llama-server").expandingTildeInPath
    }

    /// Experimental TurboQuant engine (repaired llama.cpp PR 23962), when bundled.
    static var turboBinary: String? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin-turbo/llama-server").path,
           FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        let dev = NSString(string: "~/dev/repositorios/llama.cpp-turboquant/build-static/bin/llama-server")
            .expandingTildeInPath
        return FileManager.default.fileExists(atPath: dev) ? dev : nil
    }

    /// gpuList is persisted as a comma-separated string so @AppStorage can bind it.
    static func gpuList(fromCSV csv: String?) -> [Int] {
        (csv ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Reads persisted settings (same keys as the views' @AppStorage).
    static func fromDefaults() -> ServerSettings {
        let d = UserDefaults.standard
        func int(_ key: String, _ def: Int) -> Int { d.object(forKey: key) == nil ? def : d.integer(forKey: key) }
        func bool(_ key: String, _ def: Bool) -> Bool { d.object(forKey: key) == nil ? def : d.bool(forKey: key) }
        return ServerSettings(
            serverBinary: d.string(forKey: SettingsKeys.serverBinary) ?? defaultBinary,
            modelPath: d.string(forKey: SettingsKeys.modelPath) ?? "",
            port: int(SettingsKeys.port, 8080),
            ngl: int(SettingsKeys.ngl, 99),
            ncmoe: int(SettingsKeys.ncmoe, 0),
            ctx: int(SettingsKeys.ctx, 16384),
            threads: int(SettingsKeys.threads, 6),
            flashAttn: d.string(forKey: SettingsKeys.flashAttn) ?? "auto",
            noMmap: bool(SettingsKeys.noMmap, true),
            jinja: bool(SettingsKeys.jinja, true),
            concurrencyDisable: bool(SettingsKeys.concurrencyDisable, defaultConcurrencyDisable),
            vramReserveMB: int(SettingsKeys.vramReserve, 1024),
            gpuIndex: int(SettingsKeys.gpuIndex, -1),
            gpuList: gpuList(fromCSV: d.string(forKey: SettingsKeys.gpuList)),
            extraArgs: d.string(forKey: SettingsKeys.extraArgs) ?? "",
            embeddings: bool(SettingsKeys.embeddings, false),
            cacheTypeK: d.string(forKey: SettingsKeys.cacheTypeK) ?? "f16",
            cacheTypeV: d.string(forKey: SettingsKeys.cacheTypeV) ?? "f16",
            mlock: bool(SettingsKeys.mlock, false),
            cacheRAM: int(SettingsKeys.cacheRAM, 2048),
            reasoningInline: bool(SettingsKeys.reasoningInline, false),
            parallelSlots: int(SettingsKeys.parallelSlots, 1),
            apiKeyEnabled: bool(SettingsKeys.apiKeyEnabled, false),
            localNetworkDiscovery: bool(SettingsKeys.localNetworkDiscovery, false),
            specMTP: bool(SettingsKeys.specMTP, false),
            faAmd: bool(SettingsKeys.faAmd, defaultFaAmd),
            prefetchExperts: bool(SettingsKeys.prefetchExperts, true),
            routerMode: bool(SettingsKeys.routerMode, false),
            routerModelsMax: int(SettingsKeys.routerModelsMax, 1),
            persistCache: bool(SettingsKeys.persistCache, false),
            multiGPU: bool(SettingsKeys.multiGPU, false),
            multiGPUCount: int(SettingsKeys.multiGPUCount, 0),
            forcePrivateBuffers: bool(SettingsKeys.forcePrivateBuffers, false),
            cacheReuse: bool(SettingsKeys.cacheReuse, true),
            loadVision: bool(SettingsKeys.loadVision, true),
            benchPP: int(SettingsKeys.benchPP, 512),
            benchTG: int(SettingsKeys.benchTG, 128))
    }

    /// True when the model's attention head dim exceeds 256 (Gemma 4's global
    /// layers use key_length 512). Reads the real uint32 value from
    /// the GGUF header (`<arch>.attention.key_length`), skipping the `_swa`
    /// sibling. Cached by the shared GGUF reader.
    nonisolated static func modelHasBigHeadDim(at path: String) -> Bool {
        (GGUFMetadataCache.metadata(at: path)?.uint32(forSuffix: "attention.key_length") ?? 0) > 256
    }

    var kvNeedsFlashAttention: Bool {
        cacheTypeK != "f16" || cacheTypeV != "f16"
    }

    /// The user's AMD Flash-Attention choice. Quantized KV may still force
    /// normal Flash Attention when this is off.
    var effectiveFaAmd: Bool {
        faAmd
    }

    var benchmarkFlashAttentionRoute: String {
        if effectiveFaAmd { return "amd-gpu" }
        if flashAttn == "on" || kvNeedsFlashAttention { return "standard-cpu" }
        if flashAttn == "auto" { return "standard-auto" }
        return "off"
    }

    var benchmarkFlashAttentionLabel: String {
        switch benchmarkFlashAttentionRoute {
        case "amd-gpu": return "AMD Flash Attention (GPU)"
        case "standard-cpu": return "standard Flash Attention (CPU)"
        case "standard-auto": return "standard Flash Attention (auto)"
        default: return "off"
        }
    }

    /// Whether a GGUF ships the MTP (multi-token prediction) head. The
    /// `<arch>.nextn_predict_layers` metadata key decides when present:
    /// quantizers often strip the head but keep the key at 0 (a bare "nextn"
    /// grep reads that as MTP and the server then aborts on the missing draft
    /// tensors). Without the key, the `.nextn.` tensor names decide, for
    /// conversions that keep the tensors but drop the metadata.
    /// Cached by the shared GGUF reader.
    nonisolated static func modelHasMTP(at path: String) -> Bool {
        if let layers = ggufUInt32("nextn_predict_layers", at: path) {
            return layers >= 1
        }
        return GGUFMetadataCache.tensorFlags(at: path).hasNextNTensor
    }

    /// True when the model's weights use a TurboQuant type (ggml_type 45/46). Read
    /// from the tensor types, since these GGUFs carry no usable `general.file_type`.
    /// False on an unparseable header, so we never block a model we can't read.
    /// Cached by the shared GGUF reader.
    nonisolated static func modelIsTurboQuantWeights(at path: String) -> Bool {
        GGUFMetadataCache.tensorFlags(at: path).hasTurboQuantTensor
    }

    /// First uint32 value for an exact GGUF metadata key or architecture suffix.
    nonisolated static func ggufUInt32(_ keySuffix: String, at path: String) -> UInt32? {
        GGUFMetadataCache.metadata(at: path)?.uint32(forSuffix: keySuffix)
    }

    /// String value for an exact GGUF metadata key.
    nonisolated static func ggufString(_ key: String, at path: String) -> String? {
        GGUFMetadataCache.metadata(at: path)?.string(for: key)
    }

    /// True when the model is a Mixture-of-Experts (GGUF `<arch>.expert_count` > 0).
    /// Gates the `--n-cpu-moe` control, which a dense model ignores.
    nonisolated static func modelIsMoE(at path: String) -> Bool {
        (ggufUInt32("expert_count", at: path) ?? 0) > 0
    }

    /// Remembers the ncmoe the user settled on for a MoE model, so selecting
    /// that model again restores it instead of re-deriving the recommendation.
    nonisolated static func rememberNcmoe(_ value: Int, forModel path: String) {
        guard !path.isEmpty, modelIsMoE(at: path) else { return }
        var map = UserDefaults.standard.dictionary(forKey: SettingsKeys.ncmoeByModel) as? [String: Int] ?? [:]
        map[path] = value
        UserDefaults.standard.set(map, forKey: SettingsKeys.ncmoeByModel)
    }

    nonisolated static func recalledNcmoe(forModel path: String) -> Int? {
        (UserDefaults.standard.dictionary(forKey: SettingsKeys.ncmoeByModel) as? [String: Int])?[path]
    }

    /// Remembers the ncmoe at which prompt processing collapses for a MoE model: at and
    /// above it the expert-prefetch overlap stalls the GPU (slower than plain repack), so
    /// prefetch is only enabled below this value. Passing nil clears it (e.g. before a
    /// sweep re-measures, so every candidate runs with prefetch on).
    nonisolated static func rememberPrefetchCliff(_ value: Int?, forModel path: String) {
        guard !path.isEmpty else { return }
        var map = UserDefaults.standard.dictionary(forKey: SettingsKeys.prefetchCliffByModel) as? [String: Int] ?? [:]
        if let value { map[path] = value } else { map.removeValue(forKey: path) }
        UserDefaults.standard.set(map, forKey: SettingsKeys.prefetchCliffByModel)
    }

    nonisolated static func recalledPrefetchCliff(forModel path: String) -> Int? {
        (UserDefaults.standard.dictionary(forKey: SettingsKeys.prefetchCliffByModel) as? [String: Int])?[path]
    }

    /// Finds the multimodal projector (mmproj) paired with a model, if any.
    private static func mmprojPairKey(_ model: String, _ projector: String) -> String {
        model + "\u{1}" + projector
    }

    /// Records that `projector` failed to load with `model` (e.g. an unknown CLIP
    /// projector type), so `mmprojPath` won't auto-attach it again. Persistent.
    nonisolated static func recordIncompatibleMmproj(model: String, projector: String) {
        var list = UserDefaults.standard.stringArray(forKey: SettingsKeys.incompatibleMmproj) ?? []
        let key = mmprojPairKey(model, projector)
        if !list.contains(key) {
            list.append(key)
            UserDefaults.standard.set(list, forKey: SettingsKeys.incompatibleMmproj)
        }
    }

    nonisolated static func isIncompatibleMmproj(model: String, projector: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: SettingsKeys.incompatibleMmproj) ?? [])
            .contains(mmprojPairKey(model, projector))
    }

    nonisolated static func mmprojPath(forModel modelPath: String) -> String? {
        guard !modelPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: modelPath)
        let name = url.deletingPathExtension().lastPathComponent
        if name.lowercased().contains("mmproj") { return nil }  // the model itself is not a projector
        let dir = url.deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        var projectors = files.filter {
            $0.pathExtension.lowercased() == "gguf" && $0.lastPathComponent.lowercased().contains("mmproj")
        }
        guard !projectors.isEmpty else { return nil }

        // Embedding-dim compatibility: keep only projectors whose projection_dim
        // matches the model's embedding_length. Projectors we can't read are kept
        // (don't punish unreadable headers); if the model's dim is known and NO
        // projector matches it, the model has no compatible projector.
        if let modelEmbd = ggufUInt32("embedding_length", at: modelPath) {
            let compatible = projectors.filter { p in
                guard let proj = ggufUInt32("projection_dim", at: p.path) else { return true }
                return proj == modelEmbd
            }
            if compatible.isEmpty { return nil }
            projectors = compatible
        }

        // Skip projectors recorded as incompatible with this model; a different
        // one for the same model still gets picked up.
        projectors = projectors.filter { !isIncompatibleMmproj(model: modelPath, projector: $0.path) }
        guard !projectors.isEmpty else { return nil }

        // Managed downloads use an exact model-specific stem. Preserve this as the
        // highest-confidence path before considering legacy projector names.
        func core(_ s: String) -> String {
            String(s.lowercased().replacingOccurrences(of: "mmproj", with: "").filter { $0.isLetter || $0.isNumber })
        }
        let mn = core(name)
        guard !mn.isEmpty else { return nil }
        if let exact = projectors.first(where: {
            core($0.deletingPathExtension().lastPathComponent) == mn
        }) {
            return exact.path
        }

        // Legacy/manual names often omit the quant or model size. Fall back only
        // when the GGUF dimensions match and exactly one same-family projector
        // remains; ambiguity deliberately returns nil instead of guessing.
        guard let modelEmbd = ggufUInt32("embedding_length", at: modelPath) else { return nil }
        func family(_ value: String) -> String {
            ModelName(value).title.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        func sameFamily(_ lhs: String, _ rhs: String) -> Bool {
            guard lhs.count >= 5, rhs.count >= 5 else { return false }
            return lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
        }
        let modelFamily = family(name)
        let matches = projectors.filter { projector in
            guard ggufUInt32("projection_dim", at: projector.path) == modelEmbd else { return false }
            return sameFamily(modelFamily, family(projector.lastPathComponent))
        }
        return matches.count == 1 ? matches[0].path : nil
    }

    /// The API key the chat must send, when protection is enabled in Settings.
    static func activeAPIKey() -> String? {
        UserDefaults.standard.bool(forKey: SettingsKeys.apiKeyEnabled) ? Keychain.apiKey() : nil
    }

    /// The model alias the native chat should send as `"model"`, or nil when
    /// the primary server isn't in router mode (single-model requests omit it).
    static func activeRouterModel() -> String? {
        let d = UserDefaults.standard
        guard d.bool(forKey: SettingsKeys.routerMode) else { return nil }
        let alias = d.string(forKey: SettingsKeys.chatSelectedModel) ?? ""
        if !alias.isEmpty { return alias }
        // Default to the first model when the chat hasn't picked one yet (its
        // picker's default-selection task lives in a lazily-built popover).
        return LocalModel.scan(in: modelsDirectory).first.map { routerAlias(for: $0.url.path) }
    }
}

/// Owns the running engine instance(s). For now there is exactly one, so behavior
/// matches the previous singleton; the multi-server UI is built on top of this.
@MainActor
final class ServerManager: ObservableObject {
    static let shared = ServerManager()

    @Published var servers: [ServerController]
    /// The instance the chat and benchmark act on.
    @Published var activeID: UUID

    private static let storeKey = "multiServerProfiles"

    private init() {
        // Server 1 is the default: nil profile → driven by the global settings.
        let first = ServerController()
        var list = [first]
        // Recreate any extra servers the user added, each with its own config.
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let profiles = try? JSONDecoder().decode([Profile].self, from: data) {
            for p in profiles {
                let c = ServerController()
                c.name = p.name
                c.profile = p
                list.append(c)
            }
        }
        servers = list
        activeID = first.id
    }

    var active: ServerController { servers.first { $0.id == activeID } ?? servers[0] }

    func setActive(_ id: UUID) {
        if servers.contains(where: { $0.id == id }) { activeID = id }
    }

    /// Lowest port not already taken by a server, starting at the default.
    func freePort() -> Int {
        let used = Set(servers.map { $0.profile?.port ?? ServerSettings.fromDefaults().port })
        var p = 8080
        while used.contains(p) { p += 1 }
        return p
    }

    /// Adds a server from a base profile (or the current config), on a free port.
    @discardableResult
    func addServer(name: String, from base: Profile?) -> ServerController {
        var p = base ?? ServerSettings.fromDefaults().makeProfile(name: name)
        p.name = name
        p.port = freePort()
        let c = ServerController()
        c.name = name
        c.profile = p
        servers.append(c)
        activeID = c.id
        persist()
        return c
    }

    /// Removes an added server (never the default). Stops it first.
    func removeServer(_ id: UUID) {
        guard let i = servers.firstIndex(where: { $0.id == id }), i != 0 else { return }
        servers[i].stop()
        let wasActive = servers[i].id == activeID
        servers.remove(at: i)
        if wasActive { activeID = servers[0].id }
        persist()
    }

    func stopAll() { servers.forEach { $0.stop() } }

    /// Persists only the added servers (those with their own profile).
    func persist() {
        let profiles = servers.compactMap { $0.profile }
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
}

@MainActor
final class ServerController: ObservableObject {
    let id = UUID()
    @Published var name: String = "Servidor 1"
    /// Per-server config. nil = the default server, which uses the global settings
    /// (the Settings/Dashboard bindings), so today's single-server behavior is unchanged.
    @Published var profile: Profile?

    /// Config this server launches with: its own profile, or the global defaults.
    func effectiveSettings() -> ServerSettings {
        guard let profile else { return .fromDefaults() }
        var s = ServerSettings.fromDefaults()
        s.apply(profile)
        return s
    }

    enum State: Equatable { case stopped, starting, running, failed(String) }

    @Published var state: State = .stopped
    @Published var log: String = ""
    @Published var promptSpeed: Double?
    @Published var genSpeed: Double?
    @Published var genHistory: [Double] = []
    @Published var requestCount = 0

    private var process: Process?
    private var healthTask: Task<Void, Never>?
    private var lastStoppedPID: Int32?
    /// After a projector load failure, makes the next launch drop `--mmproj`
    /// (text-only). Reset on every fresh `start()`.
    private var retryWithoutMmproj = false
    private var currentPort = 8080
    private var discoveryService: NetService?
    private var discoveryEnabled = false
    private let fileLog = RotatingFileLog(name: "server.log")
    /// Whether to pre-warm slot 0 across restarts for external clients (VS Code /
    /// Cline send a fixed 15-19k-token prefix every request; restoring it makes
    /// the first request instant instead of a multi-minute prefill). Set per launch:
    /// needs disk-cache persistence, the turbo engine, and a non-MTP model (MTP's
    /// extra KV breaks slot restore). The native chat manages its own per-conversation
    /// slots and simply overrides slot 0 on its first turn, so there's no conflict.
    private var prewarmActive = false
    /// Single fixed file for the external-client prefix (not a conversation UUID,
    /// so the chat's orphan-prune leaves it alone).
    static func externalSlotFile(port: Int) -> URL {
        ServerSettings.slotCacheDir(port: port).appendingPathComponent("external.bin")
    }

    var logFileURL: URL { fileLog.fileURL }
    /// The folder holding all per-session log files (kept ~3 days). Revealed in
    /// Finder so the user can find — or share — past sessions, not just the live one.
    var logsDirectory: URL { fileLog.directory }

    var serverURL: URL { URL(string: "http://127.0.0.1:\(currentPort)/")! }

    /// Web chat URL with the app's language and the real Metal device name
    /// passed through, so the bundled console matches the language picked in
    /// Settings and shows the GPU actually in use (instead of guessing).
    var webChatURL: URL {
        let lang = UserDefaults.standard.string(forKey: SettingsKeys.language) ?? "en"
        var comps = URLComponents(string: "http://127.0.0.1:\(currentPort)/")!
        var items = [URLQueryItem(name: "lang", value: lang)]
        if let gpu = ServerController.availableGPUs().max(by: { $0.vramMB < $1.vramMB })?.name {
            items.append(URLQueryItem(name: "gpu", value: gpu))
        }
        // Real inference backend, read from the engine's startup log (a custom
        // external build may use Vulkan instead of the bundled Metal engine).
        let backend = log.range(of: "vulkan", options: .caseInsensitive) != nil ? "Vulkan" : "Metal"
        items.append(URLQueryItem(name: "backend", value: backend))
        comps.queryItems = items
        return comps.url!
    }

    nonisolated static func availableGPUs() -> [GPUDevice] {
        MTLCopyAllDevices().enumerated().map { i, dev in
            GPUDevice(index: i, name: dev.name,
                      vramMB: Int(dev.recommendedMaxWorkingSetSize / 1_048_576),
                      isExternal: dev.location == .external,
                      isIntegrated: dev.isLowPower)
        }
    }

    /// Whether any detected GPU is an external eGPU. Used to surface the
    /// VRAM-resident-weights option, which fixes eGPU slowness over Thunderbolt.
    nonisolated static func hasExternalGPU() -> Bool {
        availableGPUs().contains { $0.isExternal }
    }

    func start(_ settings: ServerSettings) {
        guard state == .stopped || isFailed else { return }
        guard FileManager.default.fileExists(atPath: settings.serverBinary) else {
            state = .failed("No existe el binario llama-server en la ruta configurada")
            return
        }
        if settings.routerMode {
            guard !LocalModel.scan(in: ServerSettings.modelsDirectory).isEmpty else {
                let lang = UserDefaults.standard.string(forKey: SettingsKeys.language) ?? "en"
                state = .failed(lang == "es"
                    ? "No hay modelos descargados en la carpeta de modelos"
                    : "No models downloaded in the models folder")
                return
            }
        } else {
            guard FileManager.default.fileExists(atPath: settings.modelPath) else {
                state = .failed("Selecciona un modelo en la pestaña Modelos")
                return
            }
            // TurboQuant weight quants (tq3_1s/tq4_1s) decode to garbage on this
            // engine; block the launch instead of serving it. KV-cache TurboQuant
            // and standard quants are unaffected.
            if ServerSettings.modelIsTurboQuantWeights(at: settings.modelPath) {
                let lang = UserDefaults.standard.string(forKey: SettingsKeys.language) ?? "en"
                state = .failed(lang == "es"
                    ? "Modelo TurboQuant no soportado: la cuantización de pesos TurboQuant (tq3_1s/tq4_1s) produce salida incorrecta en este motor, tanto en modelos densos como MoE. Usa un modelo en cuantización estándar (Q4_K, Q5_K, Q6_K, Q8_0…)."
                    : "TurboQuant model not supported: TurboQuant weight quantization (tq3_1s/tq4_1s) produces incorrect output on this engine, for both dense and MoE models. Use a standard-quant model (Q4_K, Q5_K, Q6_K, Q8_0…).")
                return
            }
        }

        log = ""
        retryWithoutMmproj = false
        promptSpeed = nil
        genSpeed = nil
        genHistory = []
        requestCount = 0
        currentPort = settings.port
        discoveryEnabled = settings.localNetworkDiscovery
        stopDiscovery()
        state = .starting

        // A stopped engine can take seconds to die (SIGTERM mid-generation)
        // and meanwhile still holds the port; launching too early fails with
        // a bind error. Wait for the previous PID to actually exit first.
        let previousPID = lastStoppedPID
        lastStoppedPID = nil
        Task { [weak self] in
            if let pid = previousPID {
                for _ in 0..<24 where kill(pid, 0) == 0 {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            self?.launch(settings)
        }
    }

    /// A self-contained header written to the top of the server log: app version,
    /// engine, model, detected GPUs and the resolved settings/env/args. Makes a log
    /// a tester pastes enough to debug without round-trips. The API key is redacted.
    nonisolated static func startupBanner(settings: ServerSettings) -> String {
        func redact(_ items: [String]) -> [String] {
            var out = items
            if let i = out.firstIndex(of: "--api-key"), i + 1 < out.count { out[i + 1] = "***" }
            return out
        }
        let engine: String
        switch settings.serverBinary {
        case ServerSettings.defaultBinary: engine = "bundled (official)"
        case ServerSettings.turboBinary:   engine = "turbo (experimental)"
        default:                           engine = "external"
        }
        let gpus = availableGPUs().map {
            "    [\($0.index)] \($0.name) · \($0.vramMB / 1024) GB\($0.isExternal ? " · EXTERNAL/eGPU" : "")\($0.isIntegrated ? " · iGPU (not auto-selected)" : "")"
        }.joined(separator: "\n")
        let envKeys = ["GGML_METAL_CONCURRENCY_DISABLE", "GGML_METAL_VRAM_RESERVE_MB",
                       "GGML_METAL_DEVICE_INDEX", "GGML_METAL_DEVICES",
                       "GGML_METAL_SHARED_BUFFERS_DISABLE", "TOSH_FA_AMD",
                       "GGML_SCHED_PREFETCH_EXPERTS", "GGML_CPU_NO_REPACK"]
        let env = settings.environment
        let envLine = envKeys.compactMap { k in env[k].map { "\(k)=\($0)" } }.joined(separator: " ")
        let gpuSel = settings.multiGPU ? "split-all" : (settings.gpuIndex >= 0 ? "index \(settings.gpuIndex)" : "default (macOS picks)")
        return """
        ========================================================
         ToshLLM \(AppInfo.version) — server start (\(ServerSettings.isAppleSilicon ? "arm64" : "x86_64")\(AppInfo.isNoAVX2 ? " · no-AVX2 build" : ""))
         engine : \(engine)
         model  : \(settings.routerMode ? "router (autoload, max \(settings.routerModelsMax) loaded)" : (settings.modelPath as NSString).lastPathComponent)
         GPUs detected:
        \(gpus.isEmpty ? "    (none)" : gpus)
         GPU select: \(gpuSel) | force-VRAM-buffers: \(env["GGML_METAL_SHARED_BUFFERS_DISABLE"] == "1" ? "yes" : "no")
         settings: ngl=\(settings.ngl) ncmoe=\(settings.ncmoe) ctx=\(settings.ctx) fa=\(settings.flashAttn) ctk=\(settings.cacheTypeK) ctv=\(settings.cacheTypeV) cacheRAM=\(settings.cacheRAM) concurrencyDisable=\(settings.concurrencyDisable)
         env: \(envLine)
         args: \(redact(settings.arguments).joined(separator: " "))
        ========================================================

        """
    }

    private func launch(_ settings: ServerSettings) {
        guard state == .starting else { return }   // user hit Stop meanwhile

        if settings.routerMode {
            let models = LocalModel.scan(in: ServerSettings.modelsDirectory)
            let paths = models.map(\.url.path)
            let ncmoeByPath = Dictionary(uniqueKeysWithValues: paths.map {
                ($0, Estimator.ncmoeForSelection(path: $0, models: models))
            })
            let ini = settings.routerPresetINI(modelPaths: paths, ncmoeByPath: ncmoeByPath)
            try? ini.write(to: ServerSettings.routerPresetPath(port: settings.port), atomically: true, encoding: .utf8)
        }

        prewarmActive = !settings.routerMode && settings.persistCache && settings.isTurboEngine
            && !settings.isMultimodal && !ServerSettings.modelHasMTP(at: settings.modelPath)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: settings.serverBinary)
        var args = settings.arguments
        if retryWithoutMmproj, let i = args.firstIndex(of: "--mmproj") {
            args.removeSubrange(i ..< min(i + 2, args.count))   // drop "--mmproj <path>"
        }
        p.arguments = args
        p.environment = settings.environment

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.consume(text) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                // A process we already replaced (stop → start) must not touch
                // the new engine's state, health watch or PID lockfile.
                guard self.process === proc else { return }
                self.healthTask?.cancel()
                self.stopDiscovery()
                EngineLock.remove(pid: proc.processIdentifier)
                if case .failed = self.state { return }
                if proc.terminationStatus == 0 || proc.terminationStatus == 15 {
                    self.state = .stopped
                } else {
                    // A projector that won't load fails the whole launch; retry
                    // once without it so the model still runs text-only.
                    let tail = self.log.suffix(6000).lowercased()
                    let clipFailed = tail.contains("failed to load clip")
                        || tail.contains("unknown projector type")
                        || tail.contains("failed to load multimodal model")
                    if clipFailed && !self.retryWithoutMmproj && args.contains("--mmproj") {
                        // Don't auto-attach this projector again for this model.
                        if let i = args.firstIndex(of: "--mmproj"), i + 1 < args.count {
                            ServerSettings.recordIncompatibleMmproj(model: settings.modelPath, projector: args[i + 1])
                        }
                        self.retryWithoutMmproj = true
                        EngineLock.remove(pid: proc.processIdentifier)
                        self.consume("\n[ToshLLM] el proyector (mmproj) no se pudo cargar — reintentando solo-texto (visión desactivada) / projector failed to load — retrying text-only (vision disabled)\n")
                        self.state = .starting
                        self.launch(settings)
                        return
                    }
                    AppLog.server.error("engine exited with status \(proc.terminationStatus)")
                    self.state = .failed(Self.diagnose(self.log, exitCode: proc.terminationStatus))
                }
            }
        }

        fileLog.startSession()   // new timestamped per-session file, prunes old ones
        consume(Self.startupBanner(settings: settings))
        do {
            try p.run()
            process = p
            EngineLock.add(pid: p.processIdentifier)
            // A fresh engine starts with empty KV slots; tell the chat so it
            // re-restores the active conversation's persisted cache on next turn.
            NotificationCenter.default.post(name: .engineDidStart, object: nil)
            watchHealth(port: settings.port)
        } catch {
            state = .failed("No se pudo lanzar: \(error.localizedDescription)")
        }
    }

    /// Maps known engine failure patterns to actionable, bilingual messages.
    static func diagnose(_ log: String, exitCode: Int32) -> String {
        let tail = log.suffix(6000).lowercased()
        if tail.contains("unknown model architecture") || tail.contains("unknown architecture") {
            return "Arquitectura no soportada por este motor / model architecture not supported by this engine"
        }
        if tail.contains("address already in use") || tail.contains("couldn't bind") {
            return "Puerto ocupado: cambia el puerto en Ajustes / port busy: change it in Settings"
        }
        if tail.contains("out of memory") || tail.contains("failed to allocate")
            || tail.contains("insufficient memory") || tail.contains("kiogpucommandbuffercallbackerroroutofmemory") {
            return "Memoria insuficiente: sube 'Expertos MoE en CPU' o reduce el contexto / out of memory: raise 'MoE experts on CPU' or reduce context"
        }
        if tail.contains("quantized v cache") {
            return "El KV cuantizado requiere Flash Attention: activa el kernel AMD o usa FA estándar / quantized KV requires Flash Attention: enable the AMD kernel or use standard FA"
        }
        if tail.contains("nextn") || tail.contains("draft-mtp") || tail.contains("mtp") {
            return "Este modelo no trae cabezal MTP: desactiva 'Aceleración MTP' o descarga la variante -MTP- / model has no MTP head: disable 'MTP acceleration' or download the -MTP- variant"
        }
        if tail.contains("invalid magic") || tail.contains("failed to load model")
            || tail.contains("error loading model") {
            return "Modelo dañado o incompleto: vuelve a descargarlo / model file damaged or incomplete: re-download it"
        }
        if exitCode == SIGILL {
            return AppInfo.isNoAVX2
                ? "Instrucción ilegal (SIGILL): este CPU no soporta el motor — reporta tu modelo de CPU en GitHub / illegal instruction (SIGILL): this CPU can't run the engine — report your CPU model on GitHub"
                : "Instrucción ilegal (SIGILL): este CPU no soporta AVX2 — instala la versión no-AVX2 del release / illegal instruction (SIGILL): this CPU lacks AVX2 — install the no-AVX2 build from the release"
        }
        return "El motor terminó con código \(exitCode) — revisa el registro en Ajustes / engine exited with code \(exitCode) — see the log in Settings"
    }

    func stop() {
        healthTask?.cancel()
        stopDiscovery()
        if let p = process {
            let pid = p.processIdentifier
            lastStoppedPID = pid
            // Drop this engine's PID now: once process is niled below, the termination
            // handler's guard skips its own removal.
            EngineLock.remove(pid: pid)
            let prewarm = prewarmActive
            let port = currentPort
            // SIGKILL fallback fires regardless of pid in case the (deferred)
            // terminate stalls — the engine's multi-GB working set must be freed.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6) {
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
            if prewarm {
                // Snapshot slot 0 to disk before killing the engine, so the next
                // launch can restore the fixed external-client prefix. Best-effort,
                // bounded; terminate runs even if the save fails or times out.
                Task.detached {
                    await ServerController.slotAction("save", port: port,
                                                      file: ServerController.externalSlotFile(port: port).lastPathComponent)
                    p.terminate()
                }
            } else {
                p.terminate()
            }
        } else if let pid = lastStoppedPID {
            EngineLock.remove(pid: pid)
        }
        process = nil
        state = .stopped
    }

    /// Restart with new settings, if currently up. Waits (bounded) for the old
    /// engine to exit so the relaunch doesn't race it for the port.
    func restart(_ settings: ServerSettings) {
        guard state == .running || state == .starting else { return }
        stop()
        Task { @MainActor in
            for _ in 0..<40 {
                guard let pid = lastStoppedPID, kill(pid, 0) == 0 else { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            start(settings)
        }
    }

    /// POST /slots/0?action=save|restore (best-effort, short timeout). Used to
    /// pre-warm the external-client prefix across engine restarts.
    nonisolated static func slotAction(_ action: String, port: Int, file: String) async {
        guard var comps = URLComponents(string: "http://127.0.0.1:\(port)/slots/0") else { return }
        comps.queryItems = [URLQueryItem(name: "action", value: action)]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = ServerSettings.activeAPIKey() { req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["filename": file])
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Restore the saved external-client prefix into slot 0 (only if a file exists).
    private func restoreExternalSlot(port: Int) async {
        guard prewarmActive,
              FileManager.default.fileExists(atPath: Self.externalSlotFile(port: port).path) else { return }
        await Self.slotAction("restore", port: port, file: Self.externalSlotFile(port: port).lastPathComponent)
    }

    private var isFailed: Bool { if case .failed = state { return true }; return false }

    private func watchHealth(port: Int) {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            let url = URL(string: "http://127.0.0.1:\(port)/health")!
            for _ in 0..<150 {   // up to ~5 min for large models
                if Task.isCancelled { return }
                if let (data, _) = try? await URLSession.shared.data(from: url),
                   String(data: data, encoding: .utf8)?.contains("ok") == true {
                    await MainActor.run {
                        self?.state = .running
                        self?.startDiscoveryIfNeeded(port: port)
                    }
                    // Pre-warm slot 0 with the last session's prefix so an external
                    // client's first request skips the multi-minute cold prefill.
                    await self?.restoreExternalSlot(port: port)
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
            await MainActor.run {
                self?.state = .failed("El servidor no respondió al health check")
                self?.stopDiscovery()
                self?.process?.terminate()
            }
        }
    }

    private func startDiscoveryIfNeeded(port: Int) {
        guard discoveryEnabled else { return }
        stopDiscovery()
        let service = NetService(domain: "local.", type: "_http._tcp.", name: "ToshLLM API", port: Int32(port))
        let txt: [String: Data] = [
            "path": Data("/v1".utf8),
            "protocol": Data("openai-compatible".utf8),
            "auth": Data((UserDefaults.standard.bool(forKey: SettingsKeys.apiKeyEnabled) ? "bearer" : "none").utf8),
        ]
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        discoveryService = service
    }

    private func stopDiscovery() {
        discoveryService?.stop()
        discoveryService = nil
    }

    private func consume(_ text: String) {
        log += text
        if log.count > 120_000 { log = String(log.suffix(80_000)) }
        fileLog.append(text)

        for line in text.split(separator: "\n") {
            guard line.contains("tokens per second"), line.contains("eval time") else { continue }
            guard let match = line.range(of: #"([0-9]+\.[0-9]+) tokens per second"#, options: .regularExpression) else { continue }
            let value = Double(line[match].split(separator: " ")[0]) ?? 0
            if line.contains("prompt eval") {
                promptSpeed = value
            } else {
                genSpeed = value
                genHistory.append(value)
                if genHistory.count > 60 { genHistory.removeFirst() }
                requestCount += 1
            }
        }
    }
}
