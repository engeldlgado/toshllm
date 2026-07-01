import SwiftUI

// Local text-to-image via a bundled stable-diffusion.cpp engine. A model is three
// files (diffusion transformer, VAE, text encoder), kept in an `imagen/` subfolder
// so they stay out of the LLM model list.

/// One downloadable piece of an image model.
struct ImageGenComponent: Identifiable {
    enum Kind { case diffusion, vae, textEncoder }
    let kind: Kind
    let urlString: String
    let fileName: String
    let sizeGB: Double
    var id: String { fileName }

    func labelES() -> String {
        switch kind {
        case .diffusion: return "Modelo de difusión"
        case .vae: return "VAE"
        case .textEncoder: return "Codificador de texto"
        }
    }
    func labelEN() -> String {
        switch kind {
        case .diffusion: return "Diffusion model"
        case .vae: return "VAE"
        case .textEncoder: return "Text encoder"
        }
    }
}

/// An image-generation model the app can install and run.
struct ImageGenModel: Identifiable {
    let name: String
    let detailES: String
    let detailEN: String
    let diffusion: ImageGenComponent
    let vae: ImageGenComponent
    let textEncoder: ImageGenComponent
    /// Steps the model is tuned for (Turbo/distilled models need very few).
    let defaultSteps: Int
    /// Guidance scale the model expects (Turbo models run at 1.0).
    let cfgScale: Double
    /// Rough usable VRAM (GB) below which it won't fit well. Drives the pick.
    let minVRAMGB: Double

    var id: String { name }
    var components: [ImageGenComponent] { [diffusion, vae, textEncoder] }
    var totalGB: Double { components.reduce(0) { $0 + $1.sizeGB } }

    func detail(_ spanish: Bool) -> String { spanish ? detailES : detailEN }
}

enum ImageGenCatalog {
    /// Z-Image Turbo (6B DiT, 8 steps, Apache). The VAE comes from a non-gated
    /// mirror because the official FLUX autoencoder repo is gated.
    static let zImageTurbo = ImageGenModel(
        name: "Z-Image Turbo",
        detailES: "6B, 8 pasos, Apache. Rápido y fotorrealista; el mejor equilibrio para GPUs AMD de 12 GB.",
        detailEN: "6B, 8 steps, Apache. Fast and photorealistic; the best fit for 12 GB AMD GPUs.",
        diffusion: ImageGenComponent(
            kind: .diffusion,
            urlString: "https://huggingface.co/leejet/Z-Image-Turbo-GGUF/resolve/main/z_image_turbo-Q4_0.gguf",
            fileName: "z_image_turbo-Q4_0.gguf", sizeGB: 3.5),
        vae: ImageGenComponent(
            kind: .vae,
            urlString: "https://huggingface.co/wbruna/Z-Image-Turbo-sdcpp-GGUF/resolve/main/ae_bf16.safetensors",
            fileName: "z_image_ae.safetensors", sizeGB: 0.16),
        textEncoder: ImageGenComponent(
            kind: .textEncoder,
            urlString: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
            fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf", sizeGB: 2.4),
        defaultSteps: 8, cfgScale: 1.0, minVRAMGB: 8)

    static let models: [ImageGenModel] = [zImageTurbo]

    /// The model to suggest for this machine, or nil when no GPU can hold one.
    /// A single model today, gated on usable VRAM so we don't recommend it on
    /// cards that would swap.
    static func recommended(for hw: HardwareInfo) -> ImageGenModel? {
        models.first { hw.vramGB >= $0.minVRAMGB }
    }
}

/// Resolution and command-buffer limits derived from the detected GPU. Large
/// diffusion runs hit two ceilings on AMD: VRAM (the compute buffer grows with
/// pixels) and the macOS GPU watchdog (a single command buffer that runs too long
/// is killed). These pick sizes that clear both.
enum ImageGenLimits {
    /// Largest width*height that fits VRAM. Empirical on a 12 GB RX 6700 XT:
    /// 1600x900 (1.44M px) fits, 1600x1600 (2.56M, ~11.5 GB buffer) OOMs. Roughly
    /// 4.5e-6 GB per output pixel on top of the resident model, with headroom.
    static func maxPixels(vramGB: Double) -> Int {
        let budget = max(0.4, vramGB - 3.7 - 1.0)
        return Int(budget / 4.5e-6)
    }

    /// Base (long-edge) sizes to offer: a 16:9 frame at that base must fit VRAM.
    /// Capped at 1440, the safe ceiling measured for a 12 GB card.
    static func baseSizes(vramGB: Double) -> [Int] {
        let maxPx = maxPixels(vramGB: vramGB)
        return [512, 640, 768, 896, 1024, 1152, 1280, 1440].filter { base in
            let short = max(256, Int((Double(base) * 9 / 16 / 64).rounded()) * 64)
            return base * short <= maxPx
        }
    }

    /// True when a specific frame fits VRAM (a square at a large base may not).
    static func fits(width: Int, height: Int, vramGB: Double) -> Bool {
        width * height <= maxPixels(vramGB: vramGB)
    }

    /// Command buffers to split each diffusion step into so none exceeds the
    /// watchdog. 1024x1024 (~1.05M px) is safe as one buffer; scale up from there,
    /// capped at 4 (n_cb>4 crashes AMD).
    static func nCB(width: Int, height: Int) -> Int {
        let px = width * height
        if px <= 1_150_000 { return 1 }
        return min(4, Int((Double(px) / 550_000).rounded(.up)))
    }
}

/// Output framing. The base size is the LONG edge; the short edge scales down
/// from it, so no preset ever exceeds base x base pixels. That keeps a single
/// diffusion step under the AMD GPU watchdog (a larger step times out). Rounded
/// to multiples of 64 (the latent grid).
enum ImageAspect: String, CaseIterable, Identifiable {
    case square = "1:1"
    case landscape = "16:9"
    case portrait = "9:16"
    case photo = "4:3"
    case photoTall = "3:4"
    var id: String { rawValue }

    /// (width, height) with `base` as the longer edge, rounded to the latent grid.
    func dimensions(base: Int) -> (Int, Int) {
        func g(_ v: Double) -> Int { max(256, Int((v / 64).rounded()) * 64) }
        let short9x16 = g(Double(base) * 9 / 16)
        let short3x4  = g(Double(base) * 3 / 4)
        switch self {
        case .square:    return (base, base)
        case .landscape: return (base, short9x16)
        case .portrait:  return (short9x16, base)
        case .photo:     return (base, short3x4)
        case .photoTall: return (short3x4, base)
        }
    }
}

/// Output file format. JPG is much lighter for photographic results; PNG stays
/// lossless for line art or when the user wants to re-edit.
enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpg
    var id: String { rawValue }
    var ext: String { rawValue }
}

/// Drives one text-to-image run: resolves the bundled engine and the installed
/// model, launches sd-cli with the AMD-validated flags, and surfaces progress.
@MainActor
final class ImageGenerator: ObservableObject {
    enum State: Equatable { case idle, generating, done, failed(String) }

    /// Coarse stage so the UI can explain what the long wait is doing.
    enum Stage { case loading, sampling, decoding }

    @Published var state: State = .idle
    @Published var stage: Stage = .loading
    /// 0...1 across the sampling steps, parsed from the engine's progress line.
    @Published var progress: Double = 0
    @Published var stepText: String = ""
    @Published var resultImage: NSImage?
    @Published var resultURL: URL?
    /// Wall-clock seconds of the last completed run, for the "generated in" caption.
    @Published var lastDuration: Int = 0

    private var process: Process?
    private var startedAt: Date?
    private var firstStepAt: Date?
    /// Tail of the engine output, kept so a failure can be diagnosed (e.g. a GPU
    /// watchdog timeout) into a helpful message.
    private var logTail = ""

    var isBusy: Bool { if case .generating = state { return true }; return false }

    /// Seconds elapsed since the run started (for the status line).
    var elapsed: Int { startedAt.map { Int(-$0.timeIntervalSinceNow) } ?? 0 }

    /// Estimated seconds left, extrapolated from the pace of completed steps plus
    /// a flat allowance for the VAE decode that follows. Nil until a step lands.
    var etaSeconds: Int? {
        guard let first = firstStepAt, progress > 0.001, progress < 1 else { return nil }
        let spent = -first.timeIntervalSinceNow
        let remainingSampling = spent / progress * (1 - progress)
        return max(0, Int(remainingSampling + spent * 0.2))   // ~20% tail for the decode
    }

    /// The bundled engine, with a dev fallback to the reproducible vendor build.
    static var binary: String {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin-image/sd-cli").path,
           FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        return NSString(string: "~/dev/repositorios/toshllm/vendor/stable-diffusion.cpp/build-static/bin/sd-cli")
            .expandingTildeInPath
    }

    static var engineInstalled: Bool { FileManager.default.fileExists(atPath: binary) }

    /// True when all three component files for `model` are present.
    static func installed(_ model: ImageGenModel, in models: ModelStore) -> Bool {
        model.components.allSatisfy {
            FileManager.default.fileExists(atPath: models.imagenDirectory.appendingPathComponent($0.fileName).path)
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
        if isBusy { state = .idle }
    }

    /// Generate an image. `prompt` is required; the rest are the tuned defaults
    /// unless the caller overrides them.
    func generate(model: ImageGenModel, models: ModelStore, prompt: String,
                  width: Int, height: Int, steps: Int, seed: Int,
                  format: ImageFormat, offloadToCPU: Bool, gpuIndex: Int) {
        guard !isBusy else { return }
        let dir = models.imagenDirectory
        let diffusion = dir.appendingPathComponent(model.diffusion.fileName)
        let vae = dir.appendingPathComponent(model.vae.fileName)
        let llm = dir.appendingPathComponent(model.textEncoder.fileName)
        let out = dir.appendingPathComponent("toshllm_out.\(format.ext)")

        var args: [String] = [
            "--diffusion-model", diffusion.path,
            "--vae", vae.path,
            "--llm", llm.path,
            "-p", prompt,
            "--cfg-scale", String(format: "%.1f", model.cfgScale),
            "--steps", String(steps),
            "-W", String(width), "-H", String(height),
            "--seed", String(seed),
            // Tiled VAE decode keeps each Metal command buffer under the AMD GPU
            // watchdog; without it the decode times out and the colors corrupt.
            "--vae-tiling",
            // The output format follows the file extension (PNG lossless, JPG lighter).
            "-o", out.path,
        ]
        // Offloading the diffusion model to CPU trades speed for VRAM; measured to
        // make no difference here, so it's off by default and only a fallback.
        if offloadToCPU { args.append("--offload-to-cpu") }

        var env = ProcessInfo.processInfo.environment
        // AMD discrete GPUs corrupt output without disabling Metal concurrency;
        // Apple Silicon keeps it on. Mirrors the LLM engine defaults.
        if !ServerSettings.isAppleSilicon { env["GGML_METAL_CONCURRENCY_DISABLE"] = "1" }
        // Split each step into enough command buffers to clear the GPU watchdog.
        env["GGML_METAL_NCB"] = String(ImageGenLimits.nCB(width: width, height: height))
        // Pin the chosen GPU (slot maps to MTLCopyAllDevices order, as in the picker).
        if gpuIndex > 0 { env["GGML_METAL_DEVICE_INDEX"] = String(gpuIndex) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.binary)
        p.arguments = args
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.consume(text, steps: steps) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.finish(status: proc.terminationStatus, output: out) }
        }

        resultImage = nil
        resultURL = nil
        progress = 0
        stepText = ""
        stage = .loading
        state = .generating
        startedAt = Date()
        firstStepAt = nil
        do {
            try p.run()
            process = p
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Parse the engine's per-step progress. Only the sampler prints a line ending
    /// in `- X.Xs/it`; other `N/M` output (image count, saved files) must not move
    /// the bar. Also note the decode stage so the UI can name the wait.
    private func consume(_ text: String, steps: Int) {
        logTail = String((logTail + text).suffix(4000))
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.lowercased().contains("decod") { stage = .decoding }
            guard line.contains("s/it"),
                  let r = line.range(of: #"(\d+)/(\d+)"#, options: .regularExpression) else { continue }
            let parts = line[r].split(separator: "/")
            if parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), b > 0 {
                if firstStepAt == nil { firstStepAt = Date() }
                stage = .sampling
                progress = Double(a) / Double(b)
                stepText = "\(a)/\(b)"
            }
        }
    }

    private func finish(status: Int32, output: URL) {
        process = nil
        guard status == 0, let img = NSImage(contentsOf: output) else {
            // 15/SIGTERM and 2/SIGINT are user cancels, not errors.
            if status == 15 || status == 2 { state = .failed(""); return }
            // Map the two size-related failures to actionable messages instead of a
            // raw exit code: VRAM exhaustion and the GPU watchdog timeout.
            if logTail.contains("failed to allocate") { state = .failed("OOM"); return }
            let timedOut = logTail.contains("Timeout") || logTail.contains("status 5")
            state = .failed(timedOut ? "TIMEOUT" : "exit \(status)")
            return
        }
        resultImage = img
        resultURL = output
        progress = 1
        lastDuration = elapsed
        state = .done
    }
}
