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
    var extraArgs: String
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
    /// MTP self-speculative decoding (+30% generation). Only applied when the
    /// selected GGUF actually ships the MTP head; silently skipped otherwise.
    var specMTP: Bool = false
    /// Experimental: route decode attention through the dedicated AMD Metal
    /// Flash-Attention kernel (gated by the TOSH_FA_AMD env var in the engine).
    /// Forces `-fa 1`; prefill falls back to CPU, so prompt processing is slower.
    var faAmd: Bool = false
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
    /// Reuse shifted KV chunks across mid-prompt divergences (agent edits, a
    /// stripped <think> block). Fast but approximate — the KV shift is not a
    /// bit-exact reconstruction — so the user can turn it off for exact results.
    /// Force-disabled for turbo2/3/4 KV (crashes on a shift). On by default.
    var cacheReuse: Bool = true

    /// True when the selected binary is the bundled or dev turbo engine.
    static func isTurbo(_ binary: String) -> Bool {
        binary.contains("bin-turbo") || binary == turboBinary
    }
    var isTurboEngine: Bool { Self.isTurbo(serverBinary) }

    /// Directory where per-conversation KV slot files live.
    static var slotCacheDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ToshLLM/slots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static let kvCacheTypes = ["f16", "q8_0", "q5_1", "q5_0", "q4_1", "q4_0", "iq4_nl"]

    var arguments: [String] {
        var args = [
            "-m", modelPath,
            "-ngl", String(ngl),
            "-c", String(ctx),
            "-t", String(threads),
            "-fa", effectiveFaAmd ? "1" : flashAttn,
            "--host", "127.0.0.1",
            "--port", String(port),
        ]
        if ncmoe > 0 { args += ["--n-cpu-moe", String(ncmoe)] }
        if noMmap { args.append("--no-mmap") }
        if jinja { args.append("--jinja") }
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
        if cacheReuse && !turboKV {
            args += ["--cache-reuse", "256"]
        }
        if parallelSlots > 0 { args += ["--parallel", String(parallelSlots)] }
        // EXPERIMENTAL multi-GPU: split layers across all detected Metal devices.
        // Leaves device selection to llama.cpp (we also skip the single-device env
        // below). Unvalidated on AMD — see the multiGPU doc comment.
        if multiGPU { args += ["--split-mode", "layer"] }
        // Persist KV slots to disk so reopening a chat skips re-prefill. Only on
        // the turbo engine, where the AMD FA kernel keeps the V cache contiguous
        // (the official engine's transposed-V save/restore is unusably slow on AMD).
        if persistCache && isTurboEngine {
            args += ["--slot-save-path", Self.slotCacheDir.path]
        }
        if reasoningInline { args += ["--reasoning-format", "none"] }
        if apiKeyEnabled { args += ["--api-key", Keychain.apiKey()] }
        if specMTP && Self.modelHasMTP(at: modelPath) {
            args += ["--spec-type", "draft-mtp"]
        }
        if let ui = Self.chatUIPath { args += ["--path", ui] }
        args += ShellWords.split(extraArgs)
        return args
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
        // Multi-GPU needs all devices visible, so don't pin to a single index.
        if gpuIndex >= 0 && !multiGPU { env["GGML_METAL_DEVICE_INDEX"] = String(gpuIndex) }
        if effectiveFaAmd { env["TOSH_FA_AMD"] = "1" }
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
            extraArgs: d.string(forKey: SettingsKeys.extraArgs) ?? "",
            cacheTypeK: d.string(forKey: SettingsKeys.cacheTypeK) ?? "f16",
            cacheTypeV: d.string(forKey: SettingsKeys.cacheTypeV) ?? "f16",
            mlock: bool(SettingsKeys.mlock, false),
            cacheRAM: int(SettingsKeys.cacheRAM, 2048),
            reasoningInline: bool(SettingsKeys.reasoningInline, false),
            parallelSlots: int(SettingsKeys.parallelSlots, 1),
            apiKeyEnabled: bool(SettingsKeys.apiKeyEnabled, false),
            specMTP: bool(SettingsKeys.specMTP, false),
            faAmd: bool(SettingsKeys.faAmd, false),
            persistCache: bool(SettingsKeys.persistCache, false),
            multiGPU: bool(SettingsKeys.multiGPU, false),
            cacheReuse: bool(SettingsKeys.cacheReuse, true))
    }

    /// Whether a GGUF ships the MTP (multi-token prediction) head. Detected by
    /// scanning the header for the `nextn` marker — it appears both in the
    /// `nextn_predict_layers` metadata key and in the MTP tensor names, so this
    /// catches models that keep the tensors but drop/rename the metadata key
    /// (a common cause of missed detection). We deliberately do NOT match "mtp"
    /// or "MTP": that word lives in the model's `general.name` (these repos are
    /// named "…-MTP-GGUF"), which would make every model a false positive.
    /// Cached per path+size so repeated calls are free.
    /// True when the model's attention head dim exceeds 256 (Gemma 4's global
    /// layers use key_length 512). The AMD Flash-Attention kernel only covers
    /// head dims 128/256/512, and on the bundled official engine only 128/256 —
    /// so this drives auto-enabling the kernel on the turbo engine, where
    /// otherwise those layers fall back to CPU. Reads the real uint32 value from
    /// the GGUF header (`<arch>.attention.key_length`), skipping the `_swa`
    /// sibling. Cached per path+size.
    nonisolated static func modelHasBigHeadDim(at path: String) -> Bool {
        struct Cache { nonisolated(unsafe) static var store: [String: Bool] = [:] }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let key = path + ":" + String((attrs?[.size] as? Int64) ?? 0)
        if let cached = Cache.store[key] { return cached }

        var big = false
        if let handle = FileHandle(forReadingAtPath: path),
           let head = try? handle.read(upToCount: 4 * 1024 * 1024) {
            try? handle.close()
            let marker = Data("attention.key_length".utf8)
            var from = head.startIndex
            while let r = head.range(of: marker, in: from ..< head.endIndex) {
                from = head.index(after: r.lowerBound)
                guard let valEnd = head.index(r.upperBound, offsetBy: 8, limitedBy: head.endIndex)
                else { break }
                let b = [UInt8](head[r.upperBound ..< valEnd])   // value_type (u32) + value (u32), LE
                let vt = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
                guard vt == 4 else { continue }   // GGUF_TYPE_UINT32; else this was key_length_swa
                let val = UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24
                if val > 256 { big = true; break }
            }
        }
        Cache.store[key] = big
        return big
    }

    /// faAmd as the user set it, OR auto-enabled for big-head-dim models (Gemma
    /// 4) when running the turbo engine — without the AMD kernel their global
    /// layers (head_dim 512) fall back to CPU during prompt processing. Gated to
    /// `bin-turbo` because only that engine ships the dk512 kernel; forcing it on
    /// the official engine (which lacks it) would push those layers to CPU under
    /// `-fa 1`, worse than its `-fa 0` GPU path.
    var effectiveFaAmd: Bool {
        faAmd || (serverBinary.contains("bin-turbo") && Self.modelHasBigHeadDim(at: modelPath))
    }

    nonisolated static func modelHasMTP(at path: String) -> Bool {
        struct Cache { nonisolated(unsafe) static var store: [String: Bool] = [:] }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let key = path + ":" + String((attrs?[.size] as? Int64) ?? 0)
        if let cached = Cache.store[key] { return cached }

        var found = false
        if let handle = FileHandle(forReadingAtPath: path),
           let head = try? handle.read(upToCount: 32 * 1024 * 1024) {
            found = head.range(of: Data("nextn".utf8)) != nil
            try? handle.close()
        }
        Cache.store[key] = found
        return found
    }

    /// The API key the chat must send, when protection is enabled in Settings.
    static func activeAPIKey() -> String? {
        UserDefaults.standard.bool(forKey: SettingsKeys.apiKeyEnabled) ? Keychain.apiKey() : nil
    }
}

@MainActor
final class ServerController: ObservableObject {
    static let shared = ServerController()

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
    private var currentPort = 8080
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
    static var externalSlotFile: URL { ServerSettings.slotCacheDir.appendingPathComponent("external.bin") }

    var logFileURL: URL { fileLog.fileURL }

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
                      vramMB: Int(dev.recommendedMaxWorkingSetSize / 1_048_576))
        }
    }

    func start(_ settings: ServerSettings) {
        guard state == .stopped || isFailed else { return }
        guard FileManager.default.fileExists(atPath: settings.serverBinary) else {
            state = .failed("No existe el binario llama-server en la ruta configurada")
            return
        }
        guard FileManager.default.fileExists(atPath: settings.modelPath) else {
            state = .failed("Selecciona un modelo en la pestaña Modelos")
            return
        }

        log = ""
        promptSpeed = nil
        genSpeed = nil
        genHistory = []
        requestCount = 0
        currentPort = settings.port
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

    private func launch(_ settings: ServerSettings) {
        guard state == .starting else { return }   // user hit Stop meanwhile

        prewarmActive = settings.persistCache && settings.isTurboEngine
            && !ServerSettings.modelHasMTP(at: settings.modelPath)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: settings.serverBinary)
        p.arguments = settings.arguments
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
                EngineLock.clear()
                if case .failed = self.state { return }
                if proc.terminationStatus == 0 || proc.terminationStatus == 15 {
                    self.state = .stopped
                } else {
                    AppLog.server.error("engine exited with status \(proc.terminationStatus)")
                    self.state = .failed(Self.diagnose(self.log, exitCode: proc.terminationStatus))
                }
            }
        }

        do {
            try p.run()
            process = p
            EngineLock.write(pid: p.processIdentifier)
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
            return "Valores KV cuantizados requieren Flash Attention 'on' / quantized V cache requires Flash Attention 'on'"
        }
        if tail.contains("nextn") || tail.contains("draft-mtp") || tail.contains("mtp") {
            return "Este modelo no trae cabezal MTP: desactiva 'Aceleración MTP' o descarga la variante -MTP- / model has no MTP head: disable 'MTP acceleration' or download the -MTP- variant"
        }
        if tail.contains("invalid magic") || tail.contains("failed to load model")
            || tail.contains("error loading model") {
            return "Modelo dañado o incompleto: vuelve a descargarlo / model file damaged or incomplete: re-download it"
        }
        return "El motor terminó con código \(exitCode) — revisa el registro en Ajustes / engine exited with code \(exitCode) — see the log in Settings"
    }

    func stop() {
        healthTask?.cancel()
        if let p = process {
            let pid = p.processIdentifier
            lastStoppedPID = pid
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
                                                      file: ServerController.externalSlotFile.lastPathComponent)
                    p.terminate()
                }
            } else {
                p.terminate()
            }
        } else {
            EngineLock.clear()
        }
        process = nil
        state = .stopped
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
              FileManager.default.fileExists(atPath: Self.externalSlotFile.path) else { return }
        await Self.slotAction("restore", port: port, file: Self.externalSlotFile.lastPathComponent)
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
                    await MainActor.run { self?.state = .running }
                    // Pre-warm slot 0 with the last session's prefix so an external
                    // client's first request skips the multi-minute cold prefill.
                    await self?.restoreExternalSlot(port: port)
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
            await MainActor.run {
                self?.state = .failed("El servidor no respondió al health check")
                self?.process?.terminate()
            }
        }
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
