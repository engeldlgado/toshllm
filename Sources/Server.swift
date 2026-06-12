import Foundation
import Metal

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

    static let kvCacheTypes = ["f16", "q8_0", "q5_1", "q5_0", "q4_1", "q4_0", "iq4_nl"]

    var arguments: [String] {
        var args = [
            "-m", modelPath,
            "-ngl", String(ngl),
            "-c", String(ctx),
            "-t", String(threads),
            "-fa", flashAttn,
            "--host", "127.0.0.1",
            "--port", String(port),
        ]
        if ncmoe > 0 { args += ["--n-cpu-moe", String(ncmoe)] }
        if noMmap { args.append("--no-mmap") }
        if jinja { args.append("--jinja") }
        if cacheTypeK != "f16" { args += ["-ctk", cacheTypeK] }
        if cacheTypeV != "f16" { args += ["-ctv", cacheTypeV] }
        if mlock { args.append("--mlock") }
        if let ui = Self.chatUIPath { args += ["--path", ui] }
        let extra = extraArgs.split(separator: " ").map(String.init)
        args += extra
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
        if gpuIndex >= 0 { env["GGML_METAL_DEVICE_INDEX"] = String(gpuIndex) }
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

    /// Kills engine processes left behind by a previous app instance that did
    /// not shut down cleanly (e.g. force quit), so their VRAM is released.
    nonisolated static func reapOrphanedEngines() {
        guard let resources = Bundle.main.resourceURL?.path else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", resources + "/bin"]
        try? p.run()
        p.waitUntilExit()
    }

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
            serverBinary: d.string(forKey: "serverBinary") ?? defaultBinary,
            modelPath: d.string(forKey: "modelPath") ?? "",
            port: int("port", 8080),
            ngl: int("ngl", 99),
            ncmoe: int("ncmoe", 0),
            ctx: int("ctx", 16384),
            threads: int("threads", 6),
            flashAttn: d.string(forKey: "flashAttn") ?? "auto",
            noMmap: bool("noMmap", true),
            jinja: bool("jinja", true),
            concurrencyDisable: bool("concurrencyDisable", defaultConcurrencyDisable),
            vramReserveMB: int("vramReserve", 1024),
            gpuIndex: int("gpuIndex", -1),
            extraArgs: d.string(forKey: "extraArgs") ?? "",
            cacheTypeK: d.string(forKey: "cacheTypeK") ?? "f16",
            cacheTypeV: d.string(forKey: "cacheTypeV") ?? "f16",
            mlock: bool("mlock", false))
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
    private var currentPort = 8080

    var serverURL: URL { URL(string: "http://127.0.0.1:\(currentPort)/")! }

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
                self.healthTask?.cancel()
                if case .failed = self.state { return }
                self.state = proc.terminationStatus == 0 || proc.terminationStatus == 15
                    ? .stopped
                    : .failed("El servidor terminó con código \(proc.terminationStatus)")
            }
        }

        do {
            try p.run()
            process = p
            state = .starting
            watchHealth(port: settings.port)
        } catch {
            state = .failed("No se pudo lanzar: \(error.localizedDescription)")
        }
    }

    func stop() {
        healthTask?.cancel()
        process?.terminate()
        process = nil
        state = .stopped
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
