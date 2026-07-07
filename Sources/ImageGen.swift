import SwiftUI
import Metal
import Combine

// Local text-to-image via a bundled stable-diffusion.cpp engine. A model is one
// or more files (a full checkpoint, or a diffusion transformer plus its VAE and
// text encoders), kept in an `imagen/` subfolder so they stay out of the LLM
// model list. The catalog spans GPU sizes: tiny models for small cards, heavier
// ones for large VRAM.

/// One downloadable piece of an image model, tagged with the sd-cli flag it maps to.
struct ImageGenComponent: Identifiable {
    enum Kind { case checkpoint, diffusion, vae, textEncoder, t5, clipL }
    let kind: Kind
    let urlString: String
    let fileName: String
    let sizeGB: Double
    var id: String { fileName }

    /// The sd-cli argument this file is passed as.
    var flag: String {
        switch kind {
        case .checkpoint:  return "--model"
        case .diffusion:   return "--diffusion-model"
        case .vae:         return "--vae"
        case .textEncoder: return "--llm"
        case .t5:          return "--t5xxl"
        case .clipL:       return "--clip_l"
        }
    }

    func label(_ spanish: Bool) -> String {
        switch kind {
        case .checkpoint:  return spanish ? "Modelo" : "Model"
        case .diffusion:   return spanish ? "Modelo de difusión" : "Diffusion model"
        case .vae:         return "VAE"
        case .textEncoder, .t5, .clipL: return spanish ? "Codificador de texto" : "Text encoder"
        }
    }

    /// Absolute path: a catalog file lives under `dir`; a custom file carries its
    /// own absolute path in `fileName`.
    func path(in dir: URL) -> URL {
        fileName.hasPrefix("/") ? URL(fileURLWithPath: fileName) : dir.appendingPathComponent(fileName)
    }
}

/// An image-generation model the app can install and run.
struct ImageGenModel: Identifiable {
    let name: String
    let detailES: String
    let detailEN: String
    let components: [ImageGenComponent]
    /// Steps the model is tuned for (Turbo/distilled models need very few).
    let defaultSteps: Int
    /// Guidance scale the model expects (Turbo models run at 1.0).
    let cfgScale: Double
    /// Rough usable VRAM (GB) below which it won't fit well. Drives the pick.
    let minVRAMGB: Double
    /// Extra sd-cli flags this model needs (e.g. Flux 2 samples with euler).
    var extraArgs: [String] = []

    var id: String { name }
    var totalGB: Double { components.reduce(0) { $0 + $1.sizeGB } }

    /// The model that stays resident in VRAM during sampling (checkpoint or
    /// diffusion transformer); VAE and text encoders are transient. Drives the
    /// per-model VRAM budget, so a heavier model correctly allows smaller images.
    var residentGB: Double {
        components.filter { $0.kind == .checkpoint || $0.kind == .diffusion }
            .map(\.sizeGB).max() ?? totalGB
    }

    func detail(_ spanish: Bool) -> String { spanish ? detailES : detailEN }
}

enum ImageGenCatalog {
    /// Non-gated FLUX autoencoder mirror, shared by Z-Image and Flux.
    private static func fluxVAE(_ name: String) -> ImageGenComponent {
        ImageGenComponent(kind: .vae,
            urlString: "https://huggingface.co/wbruna/Z-Image-Turbo-sdcpp-GGUF/resolve/main/ae_bf16.safetensors",
            fileName: name, sizeGB: 0.16)
    }

    /// Stable Diffusion 1.5 (0.9B, single checkpoint). Tiny and fast for small GPUs.
    static let sd15 = ImageGenModel(
        name: "SD 1.5",
        detailES: "Diminuto y veloz. Para GPUs pequeñas; enorme ecosistema de estilos.",
        detailEN: "Tiny and fast. For small GPUs; huge ecosystem of styles.",
        components: [ImageGenComponent(kind: .checkpoint,
            urlString: "https://huggingface.co/second-state/stable-diffusion-v1-5-GGUF/resolve/main/stable-diffusion-v1-5-pruned-emaonly-Q8_0.gguf",
            fileName: "sd-v1-5-Q8_0.gguf", sizeGB: 1.68)],
        defaultSteps: 20, cfgScale: 7.0, minVRAMGB: 3)

    /// SDXL Turbo (3.5B, single checkpoint). Few steps, opens the LoRA/style world.
    static let sdxlTurbo = ImageGenModel(
        name: "SDXL Turbo",
        detailES: "3.5B, pocos pasos. Buena calidad y compatible con LoRAs/estilos SDXL.",
        detailEN: "3.5B, few steps. Strong quality and compatible with SDXL LoRAs/styles.",
        components: [ImageGenComponent(kind: .checkpoint,
            urlString: "https://huggingface.co/stabilityai/sdxl-turbo/resolve/main/sd_xl_turbo_1.0_fp16.safetensors",
            fileName: "sd_xl_turbo_1.0_fp16.safetensors", sizeGB: 6.6)],
        defaultSteps: 6, cfgScale: 1.0, minVRAMGB: 8)

    /// Z-Image Turbo (6B DiT, 8 steps, Apache). Diffusion + VAE + Qwen3-4B encoder.
    static let zImageTurbo = ImageGenModel(
        name: "Z-Image Turbo",
        detailES: "6B, 8 pasos, Apache. Rápido y fotorrealista; el mejor equilibrio para 8-12 GB.",
        detailEN: "6B, 8 steps, Apache. Fast and photorealistic; the best fit for 8-12 GB.",
        components: [
            ImageGenComponent(kind: .diffusion,
                urlString: "https://huggingface.co/leejet/Z-Image-Turbo-GGUF/resolve/main/z_image_turbo-Q4_0.gguf",
                fileName: "z_image_turbo-Q4_0.gguf", sizeGB: 3.5),
            fluxVAE("z_image_ae.safetensors"),
            ImageGenComponent(kind: .textEncoder,
                urlString: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
                fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf", sizeGB: 2.4),
        ],
        defaultSteps: 8, cfgScale: 1.0, minVRAMGB: 8)

    /// Flux.1 schnell (12B, 4 steps, Apache). Top prompt adherence for large GPUs.
    static let fluxSchnell = ImageGenModel(
        name: "Flux.1 schnell",
        detailES: "12B, 4 pasos, Apache. Máxima adherencia al prompt; para GPUs de 16 GB+.",
        detailEN: "12B, 4 steps, Apache. Top prompt adherence; for 16 GB+ GPUs.",
        components: [
            ImageGenComponent(kind: .diffusion,
                urlString: "https://huggingface.co/city96/FLUX.1-schnell-gguf/resolve/main/flux1-schnell-Q4_0.gguf",
                fileName: "flux1-schnell-Q4_0.gguf", sizeGB: 6.4),
            fluxVAE("flux_ae.safetensors"),
            ImageGenComponent(kind: .t5,
                urlString: "https://huggingface.co/city96/t5-v1_1-xxl-encoder-gguf/resolve/main/t5-v1_1-xxl-encoder-Q4_K_M.gguf",
                fileName: "t5-v1_1-xxl-encoder-Q4_K_M.gguf", sizeGB: 2.76),
            ImageGenComponent(kind: .clipL,
                urlString: "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors",
                fileName: "clip_l.safetensors", sizeGB: 0.23),
        ],
        defaultSteps: 4, cfgScale: 1.0, minVRAMGB: 16)

    /// Non-gated FLUX.2 autoencoder (full encoder + small decoder), shared by the
    /// Flux 2 family; the reference `ae.safetensors` lives in a gated BFL repo.
    private static let flux2VAE = ImageGenComponent(kind: .vae,
        urlString: "https://huggingface.co/black-forest-labs/FLUX.2-small-decoder/resolve/main/full_encoder_small_decoder.safetensors",
        fileName: "flux2_full_encoder_small_decoder.safetensors", sizeGB: 0.25)

    /// Flux.2 klein 9B (step-distilled, Apache). Flux 2 quality for 16 GB GPUs.
    static let flux2Klein9B = ImageGenModel(
        name: "Flux.2 klein 9B",
        detailES: "9B, 4 pasos, Apache. La calidad Flux 2 en GPUs de 16 GB.",
        detailEN: "9B, 4 steps, Apache. Flux 2 quality on 16 GB GPUs.",
        components: [
            ImageGenComponent(kind: .diffusion,
                urlString: "https://huggingface.co/leejet/FLUX.2-klein-9B-GGUF/resolve/main/flux-2-klein-9b-Q4_0.gguf",
                fileName: "flux-2-klein-9b-Q4_0.gguf", sizeGB: 5.6),
            flux2VAE,
            ImageGenComponent(kind: .textEncoder,
                urlString: "https://huggingface.co/unsloth/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q4_K_M.gguf",
                fileName: "Qwen3-8B-Q4_K_M.gguf", sizeGB: 5.0),
        ],
        defaultSteps: 4, cfgScale: 1.0, minVRAMGB: 16,
        extraArgs: ["--sampling-method", "euler"])

    /// Flux.2 dev (32B). The quality reference; enormous, non-commercial license.
    /// The 24B text encoder forces --offload-to-cpu so only the sampling model
    /// holds VRAM at a time.
    static let flux2Dev = ImageGenModel(
        name: "Flux.2 dev",
        detailES: "32B, la referencia de calidad. Muy pesado (34 GB de descarga); GPUs de 24 GB+. Licencia no comercial.",
        detailEN: "32B, the quality reference. Very heavy (34 GB download); 24 GB+ GPUs. Non-commercial license.",
        components: [
            ImageGenComponent(kind: .diffusion,
                urlString: "https://huggingface.co/city96/FLUX.2-dev-gguf/resolve/main/flux2-dev-Q4_K_S.gguf",
                fileName: "flux2-dev-Q4_K_S.gguf", sizeGB: 19.3),
            flux2VAE,
            ImageGenComponent(kind: .textEncoder,
                urlString: "https://huggingface.co/unsloth/Mistral-Small-3.2-24B-Instruct-2506-GGUF/resolve/main/Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf",
                fileName: "Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf", sizeGB: 14.3),
        ],
        defaultSteps: 20, cfgScale: 1.0, minVRAMGB: 24,
        extraArgs: ["--sampling-method", "euler", "--offload-to-cpu"])

    /// Qwen-Image (20B MMDiT). The one that renders legible text inside images.
    /// Heavy: for 24 GB+ GPUs. Text encoder is Qwen2.5-VL.
    static let qwenImage = ImageGenModel(
        name: "Qwen-Image",
        detailES: "20B. Escribe texto legible dentro de la imagen. Muy pesado; para GPUs de 24 GB+.",
        detailEN: "20B. Renders legible text inside images. Heavy; for 24 GB+ GPUs.",
        components: [
            ImageGenComponent(kind: .diffusion,
                urlString: "https://huggingface.co/city96/Qwen-Image-gguf/resolve/main/qwen-image-Q4_0.gguf",
                fileName: "qwen-image-Q4_0.gguf", sizeGB: 11.3),
            ImageGenComponent(kind: .vae,
                urlString: "https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors",
                fileName: "qwen_image_vae.safetensors", sizeGB: 0.24),
            ImageGenComponent(kind: .textEncoder,
                urlString: "https://huggingface.co/unsloth/Qwen2.5-VL-7B-Instruct-GGUF/resolve/main/Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf",
                fileName: "Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf", sizeGB: 4.5),
        ],
        // Its 3D VAE needs IM2COL_3D, which Metal doesn't implement (issue #19):
        // run the VAE on CPU until we ship a kernel.
        defaultSteps: 20, cfgScale: 2.5, minVRAMGB: 24,
        extraArgs: ["--backend", "vae=cpu"])

    /// Curated order (small to large). Z-Image sits before SDXL so it wins the
    /// 8-12 GB tie as the recommended pick (validated for photorealism on AMD);
    /// klein 9B sits before schnell to win the 16 GB tie the same way.
    static let models: [ImageGenModel] = [sd15, zImageTurbo, sdxlTurbo,
                                          flux2Klein9B, fluxSchnell, qwenImage, flux2Dev]

    /// The best model this GPU can run: the highest min-VRAM tier that fits, and
    /// within a tie the earliest listed (curated preference).
    static func recommended(for hw: HardwareInfo) -> ImageGenModel? {
        let fitting = models.filter { hw.vramGB >= $0.minVRAMGB }
        guard let top = fitting.map(\.minVRAMGB).max() else { return nil }
        return fitting.first { $0.minVRAMGB == top }
    }

    static func model(id: String) -> ImageGenModel? { models.first { $0.id == id } }

    /// Sentinel id for the user's own model (files picked from disk).
    static let customID = "__custom__"

    /// Build a model from user-picked files: a checkpoint (or diffusion model) and
    /// an optional VAE. Passed as a full checkpoint via --model, which covers most
    /// community SD/SDXL finetunes; minVRAMGB 0 so it's never blocked.
    static func custom(modelPath: String, vaePath: String, steps: Int, cfg: Double) -> ImageGenModel {
        func gb(_ p: String) -> Double {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? Int ?? 0
            return Double(bytes) / 1_073_741_824
        }
        var comps = [ImageGenComponent(kind: .checkpoint, urlString: "",
                                       fileName: modelPath, sizeGB: gb(modelPath))]
        if !vaePath.isEmpty {
            comps.append(ImageGenComponent(kind: .vae, urlString: "", fileName: vaePath, sizeGB: gb(vaePath)))
        }
        return ImageGenModel(name: "Custom",
            detailES: "Tu propio modelo. Ajusta pasos y CFG según su ficha.",
            detailEN: "Your own model. Set steps and CFG to match its card.",
            components: comps, defaultSteps: steps, cfgScale: cfg, minVRAMGB: 0)
    }
}

/// Resolution and command-buffer limits derived from the detected GPU. Large
/// diffusion runs hit two ceilings on AMD: VRAM (the compute buffer grows with
/// pixels) and the macOS GPU watchdog (a single command buffer that runs too long
/// is killed). These pick sizes that clear both.
enum ImageGenLimits {
    /// Largest width*height that fits VRAM. ~4.5e-6 GB per output pixel on top of
    /// the resident model, with headroom (empirical: Z-Image on 12 GB fits
    /// 1600x900, OOMs at 1600x1600). `residentGB` makes it model-aware, so a
    /// heavier model correctly allows smaller images.
    static func maxPixels(vramGB: Double, residentGB: Double) -> Int {
        let budget = max(0.4, vramGB - residentGB - 1.0)
        return Int(budget / 4.5e-6)
    }

    /// Base (long-edge) sizes to offer: a 16:9 frame at that base must fit VRAM,
    /// so the list scales with the card and the model.
    static func baseSizes(vramGB: Double, residentGB: Double) -> [Int] {
        let maxPx = maxPixels(vramGB: vramGB, residentGB: residentGB)
        let candidates = [512, 640, 768, 896, 1024, 1152, 1280, 1440,
                          1600, 1792, 2048, 2304, 2560, 3072]
        return candidates.filter { base in
            let short = max(256, Int((Double(base) * 9 / 16 / 64).rounded()) * 64)
            return base * short <= maxPx
        }
    }

    /// True when a specific frame fits VRAM (a square at a large base may not).
    static func fits(width: Int, height: Int, vramGB: Double, residentGB: Double) -> Bool {
        width * height <= maxPixels(vramGB: vramGB, residentGB: residentGB)
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
    /// Persist the engine output so the Logs tab can show image runs too.
    private let fileLog = RotatingFileLog(name: "imagegen")

    /// Newest image-gen log file, for the Logs tab to read (this generator lives in
    /// another window, so the file is the shared handoff).
    static var latestLogURL: URL? {
        let dir = AppSupport.directory.appendingPathComponent("logs", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("imagegen") }
            .max { a, b in (mtime(a) ?? .distantPast) < (mtime(b) ?? .distantPast) }
    }
    private static func mtime(_ u: URL) -> Date? {
        try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

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

    /// True when every component file for `model` is present (and named).
    static func installed(_ model: ImageGenModel, in models: ModelStore) -> Bool {
        !model.components.isEmpty && model.components.allSatisfy {
            !$0.fileName.isEmpty
                && FileManager.default.fileExists(atPath: $0.path(in: models.imagenDirectory).path)
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
                  format: ImageFormat, offloadToCPU: Bool, gpuIndex: Int,
                  initImagePath: String = "", strength: Double = 0.75) {
        guard !isBusy else { return }
        let dir = models.imagenDirectory
        // Timestamped name so each generation keeps its own file.
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH.mm.ss"
        let out = dir.appendingPathComponent("toshllm_\(fmt.string(from: Date())).\(format.ext)")

        // Each component maps to its own sd-cli flag (a full checkpoint via --model,
        // or a diffusion model plus its VAE and text encoders).
        var args: [String] = []
        for comp in model.components {
            args += [comp.flag, comp.path(in: dir).path]
        }
        args += [
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
        // img2img: seed the run with an existing image. Strength is how much to
        // change it (0 keeps it, 1 regenerates from scratch).
        if !initImagePath.isEmpty {
            args += ["-i", initImagePath, "--strength", String(format: "%.2f", strength)]
        }
        // Offloading the diffusion model to CPU trades speed for VRAM; measured to
        // make no difference here, so it's off by default and only a fallback.
        args += model.extraArgs
        if offloadToCPU && !model.extraArgs.contains("--offload-to-cpu") {
            args.append("--offload-to-cpu")
        }

        var env = ProcessInfo.processInfo.environment
        // AMD discrete GPUs corrupt output without disabling Metal concurrency;
        // Apple Silicon keeps it on. Mirrors the LLM engine defaults.
        if !ServerSettings.isAppleSilicon { env["GGML_METAL_CONCURRENCY_DISABLE"] = "1" }
        // Split each step into enough command buffers to clear the GPU watchdog.
        env["GGML_METAL_NCB"] = String(ImageGenLimits.nCB(width: width, height: height))
        // Pin the chosen GPU (slot maps to MTLCopyAllDevices order, as in the picker).
        // Index 0 must also be exported: without it Metal falls back to the system
        // default, which on multi-GPU Macs may be a different card than picked.
        if gpuIndex >= 0 && MTLCopyAllDevices().count > 1 {
            env["GGML_METAL_DEVICE_INDEX"] = String(gpuIndex)
        }

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

        fileLog.startSession()
        fileLog.append("$ sd-cli " + args.joined(separator: " ") + "\n\n")

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
        fileLog.append(text)
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

// MARK: - Parallel instances

/// Full configuration of one generation slot: every control the sidebar exposes,
/// so each instance can run its own model, prompt and size on its own GPU.
/// Decoding is field-tolerant so older payloads never wipe the user's setup.
struct ImageInstanceConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var modelID = ""
    var customModelPath = ""
    var customVAEPath = ""
    var customCfg = 7.0
    var prompt = ""
    var initImagePath = ""
    var strength = 0.6
    var aspect = ImageAspect.square.rawValue
    var baseSize = 1024
    var gpuIndex = 0
    var steps = 8
    var seed = -1
    var format = ImageFormat.png.rawValue
    var offloadCPU = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        modelID = (try? c.decode(String.self, forKey: .modelID)) ?? ""
        customModelPath = (try? c.decode(String.self, forKey: .customModelPath)) ?? ""
        customVAEPath = (try? c.decode(String.self, forKey: .customVAEPath)) ?? ""
        customCfg = (try? c.decode(Double.self, forKey: .customCfg)) ?? 7.0
        prompt = (try? c.decode(String.self, forKey: .prompt)) ?? ""
        initImagePath = (try? c.decode(String.self, forKey: .initImagePath)) ?? ""
        strength = (try? c.decode(Double.self, forKey: .strength)) ?? 0.6
        aspect = (try? c.decode(String.self, forKey: .aspect)) ?? ImageAspect.square.rawValue
        baseSize = (try? c.decode(Int.self, forKey: .baseSize)) ?? 1024
        gpuIndex = (try? c.decode(Int.self, forKey: .gpuIndex)) ?? 0
        steps = (try? c.decode(Int.self, forKey: .steps)) ?? 8
        seed = (try? c.decode(Int.self, forKey: .seed)) ?? -1
        format = (try? c.decode(String.self, forKey: .format)) ?? ImageFormat.png.rawValue
        offloadCPU = (try? c.decode(Bool.self, forKey: .offloadCPU)) ?? false
    }

    var isCustom: Bool { modelID == ImageGenCatalog.customID }
    var aspectValue: ImageAspect { ImageAspect(rawValue: aspect) ?? .square }
    var formatValue: ImageFormat { ImageFormat(rawValue: format) ?? .png }
    var dimensions: (Int, Int) { aspectValue.dimensions(base: baseSize) }

    /// The model this instance runs: a catalog entry, the user's own files, or
    /// the best pick for the hardware.
    func resolvedModel(for hw: HardwareInfo) -> ImageGenModel {
        if isCustom {
            return ImageGenCatalog.custom(modelPath: customModelPath, vaePath: customVAEPath,
                                          steps: steps, cfg: customCfg)
        }
        return ImageGenCatalog.model(id: modelID)
            ?? ImageGenCatalog.recommended(for: hw)
            ?? ImageGenCatalog.zImageTurbo
    }
}

/// Owns the generation instances and one generator per slot; the sidebar
/// (controls) and the canvas (tiles) share it so both see the same state.
/// There is always at least one instance.
@MainActor
final class ImageGenPool: ObservableObject {
    @Published var configs: [ImageInstanceConfig] { didSet { save() } }
    private var generators: [UUID: ImageGenerator] = [:]
    private var forwards: [UUID: AnyCancellable] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: SettingsKeys.imagenInstances),
           let c = try? JSONDecoder().decode([ImageInstanceConfig].self, from: data),
           !c.isEmpty {
            configs = c
        } else {
            configs = [Self.legacyConfig()]
        }
    }

    /// Seed instance 1 from the pre-multi-instance per-key settings, so an
    /// updated app keeps the user's prompt and choices.
    private static func legacyConfig() -> ImageInstanceConfig {
        let d = UserDefaults.standard
        func int(_ key: String, _ def: Int) -> Int { d.object(forKey: key) == nil ? def : d.integer(forKey: key) }
        func dbl(_ key: String, _ def: Double) -> Double { d.object(forKey: key) == nil ? def : d.double(forKey: key) }
        var c = ImageInstanceConfig()
        c.modelID = d.string(forKey: SettingsKeys.imagenModel) ?? ""
        c.customModelPath = d.string(forKey: SettingsKeys.imagenCustomModel) ?? ""
        c.customVAEPath = d.string(forKey: SettingsKeys.imagenCustomVAE) ?? ""
        c.customCfg = dbl(SettingsKeys.imagenCustomCfg, 7.0)
        c.prompt = d.string(forKey: SettingsKeys.imagenPrompt) ?? ""
        c.initImagePath = d.string(forKey: SettingsKeys.imagenInitImage) ?? ""
        c.strength = dbl(SettingsKeys.imagenStrength, 0.6)
        c.aspect = d.string(forKey: SettingsKeys.imagenAspect) ?? ImageAspect.square.rawValue
        c.baseSize = int(SettingsKeys.imagenBaseSize, 1024)
        c.gpuIndex = int(SettingsKeys.imagenGPU, 0)
        c.steps = int(SettingsKeys.imagenSteps, 8)
        c.seed = int(SettingsKeys.imagenSeed, -1)
        c.format = d.string(forKey: SettingsKeys.imagenFormat) ?? ImageFormat.png.rawValue
        c.offloadCPU = d.bool(forKey: SettingsKeys.imagenOffloadCPU)
        return c
    }

    /// Stable generator per slot, created lazily. Its changes are forwarded so
    /// views observing the pool re-render on per-instance progress.
    func generator(for id: UUID) -> ImageGenerator {
        if let g = generators[id] { return g }
        let g = ImageGenerator()
        generators[id] = g
        forwards[id] = g.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return g
    }

    var anyBusy: Bool { configs.contains { generator(for: $0.id).isBusy } }
    var anyResult: Bool { configs.contains { generator(for: $0.id).resultImage != nil } }

    /// New instance as a copy of the last one, landing on a free GPU when there
    /// is one. The prompt is not copied: empty means "inherit instance 1's".
    func add() {
        var c = configs.last ?? ImageInstanceConfig()
        c.id = UUID()
        c.prompt = ""
        let used = Set(configs.map(\.gpuIndex))
        if let free = (0 ..< max(hardware.gpus.count, 1)).first(where: { !used.contains($0) }) {
            c.gpuIndex = free
        }
        configs.append(c)
    }

    /// The prompt an instance will actually run: its own, or instance 1's when
    /// left empty (shared prompt with per-instance override).
    func effectivePrompt(for c: ImageInstanceConfig) -> String {
        let own = c.prompt.trimmingCharacters(in: .whitespaces)
        if !own.isEmpty || c.id == configs.first?.id { return own }
        return (configs.first?.prompt ?? "").trimmingCharacters(in: .whitespaces)
    }

    func remove(_ id: UUID) {
        guard configs.count > 1 else { return }
        generator(for: id).cancel()
        configs.removeAll { $0.id == id }
        generators[id] = nil
        forwards[id] = nil
    }

    func cancelAll() { for c in configs { generator(for: c.id).cancel() } }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(configs),
                                  forKey: SettingsKeys.imagenInstances)
    }
}
