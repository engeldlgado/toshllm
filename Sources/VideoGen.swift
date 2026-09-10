import Foundation
import SwiftUI
import Metal
import Combine
import AVFoundation
import ImageIO

/// A model-supported video size.
struct VideoGenSize: Identifiable, Hashable {
    let width: Int
    let height: Int
    var id: String { label }
    var label: String { "\(width)x\(height)" }
    var isPortrait: Bool { height > width }
}

struct VideoGenModel: Identifiable {
    let name: String
    let detailES: String
    let detailEN: String
    let components: [ImageGenComponent]
    let defaultSteps: Int
    let cfgScale: Double
    let flowShift: Double
    let minVRAMGB: Double
    let sizes: [VideoGenSize]
    let fps: Int
    var maxLongEdge: Int { sizes.map(\.width).max() ?? 0 }
    /// Native frame count, or zero when the model does not state one.
    var nativeFrames: Int = 81
    /// Accepts an init image as the first frame (`-i`).
    var supportsI2V: Bool = false
    var recommendable: Bool = true
    var extraArgs: [String] = []
    var negativePrompt: String = ""
    var samplingWorkspaceBaseMB: Double = 8
    var samplingWorkspaceCoefficient: Double = 1.84e-4
    var decodeWorkspaceAdjustmentGB: Double = 0

    var id: String { name }
    var totalGB: Double { components.reduce(0) { $0 + $1.sizeGB } }

    /// GPU-resident weights during sampling.
    var diffusionResidentGB: Double {
        components.reduce(0) { total, component in
            switch component.kind {
            case .checkpoint, .diffusion: return total + component.sizeGB
            default: return total
            }
        }
    }

    var decodeResidentGB: Double {
        components.reduce(0) { total, component in
            switch component.kind {
            case .vae, .audioVAE: return total + component.sizeGB
            default: return total
            }
        }
    }

    var vramResidentGB: Double {
        diffusionResidentGB + decodeResidentGB
    }

    func fitsVRAMClass(_ vramGB: Double) -> Bool { vramGB >= minVRAMGB * 0.9 }

    func detail(_ spanish: Bool) -> String { spanish ? detailES : detailEN }
}

enum VideoGenCatalog {
    /// Shared by every Wan model, so switching between them is a free download.
    private static let umt5 = ImageGenComponent(kind: .t5,
        urlString: "https://huggingface.co/city96/umt5-xxl-encoder-gguf/resolve/main/umt5-xxl-encoder-Q4_K_M.gguf",
        fileName: "umt5-xxl-encoder-Q4_K_M.gguf", sizeGB: 3.66)

    private static let wan21VAE = ImageGenComponent(kind: .vae,
        urlString: "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors",
        fileName: "wan_2.1_vae.safetensors", sizeGB: 0.25)

    private static let wan22VAE = ImageGenComponent(kind: .vae,
        urlString: "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan2.2_vae.safetensors",
        fileName: "wan2.2_vae.safetensors", sizeGB: 1.41)

    /// Wan's recommended negative prompt.
    static let defaultNegative =
        "色调艳丽，过曝，静态，细节模糊不清，字幕，风格，作品，画作，画面，静止，整体发灰，最差质量，低质量，"
        + "JPEG压缩残留，丑陋的，残缺的，多余的手指，画得不好的手部，画得不好的脸部，畸形的，毁容的，"
        + "形态畸形的肢体，手指融合，静止不动的画面，杂乱的背景，三条腿，背景人很多，倒着走"

    static let wan21T2V13B = VideoGenModel(
        name: "Wan 2.1 T2V 1.3B",
        detailES: "1.3B, texto a vídeo a 480p y 16 fps. Receta oficial: 50 pasos, CFG 5 y shift 5. El más ligero y rápido.",
        detailEN: "1.3B text-to-video at 480p and 16 fps. Official recipe: 50 steps, CFG 5 and shift 5. The lightest and fastest.",
        components: [
            ImageGenComponent(kind: .diffusion,
                urlString: "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_1.3B_fp16.safetensors",
                fileName: "wan2.1_t2v_1.3B_fp16.safetensors", sizeGB: 2.84),
            wan21VAE, umt5,
        ],
        defaultSteps: 50, cfgScale: 5.0, flowShift: 5.0, minVRAMGB: 8,
        sizes: [VideoGenSize(width: 832, height: 480), VideoGenSize(width: 480, height: 832)],
        fps: 16,
        negativePrompt: defaultNegative)

    /// Wan 2.2 TI2V in its supported safetensors format.
    static let wan22TI2V5B = VideoGenModel(
        name: "Wan 2.2 TI2V 5B",
        detailES: "5B, texto o imagen a vídeo, 1280×704 a 24 fps. Alta calidad, pero lento y con VAE pesado.",
        detailEN: "5B text- or image-to-video, 1280×704 at 24 fps. High quality, but slow with a heavy VAE.",
        components: [
            ImageGenComponent(kind: .diffusion,
                urlString: "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_ti2v_5B_fp16.safetensors",
                fileName: "wan2.2_ti2v_5B_fp16.safetensors", sizeGB: 10.0),
            wan22VAE, umt5,
        ],
        defaultSteps: 50, cfgScale: 5.0, flowShift: 5.0, minVRAMGB: 12,
        sizes: [VideoGenSize(width: 1280, height: 704), VideoGenSize(width: 704, height: 1280)],
        fps: 24,
        nativeFrames: 121, supportsI2V: true, recommendable: false,
        extraArgs: ["--vae-conv-direct", "--vae-tile-size", "16",
                    "--scheduler", "smoothstep"],
        negativePrompt: defaultNegative,
        samplingWorkspaceBaseMB: 64,
        samplingWorkspaceCoefficient: 8.2e-5,
        decodeWorkspaceAdjustmentGB: 0.35)

    static let wan21I2V14B = VideoGenModel(
        name: "Wan 2.1 I2V 14B",
        detailES: "14B, imagen a vídeo a 480p y 16 fps. Receta oficial 480p: 40 pasos, CFG 5 y shift 3. Checkpoint FP8 grande.",
        detailEN: "14B image-to-video at 480p and 16 fps. Official 480p recipe: 40 steps, CFG 5 and shift 3. Large FP8 checkpoint.",
        components: [
            ImageGenComponent(kind: .diffusion,
                urlString: "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_480p_14B_fp8_scaled.safetensors",
                fileName: "wan2.1_i2v_480p_14B_fp8_scaled.safetensors", sizeGB: 16.40),
            wan21VAE, umt5,
        ],
        defaultSteps: 40, cfgScale: 5.0, flowShift: 3.0, minVRAMGB: 24,
        sizes: [VideoGenSize(width: 832, height: 480), VideoGenSize(width: 480, height: 832)],
        fps: 16, supportsI2V: true,
        extraArgs: ["--vae-conv-direct"],
        negativePrompt: defaultNegative)

    /// LTX-2.3 distilled video model.
    static let ltx23Distilled = VideoGenModel(
        name: "LTX-2.3 distilled",
        detailES: "22B destilado, 8 pasos. Los tamaños son menores que los del modelo porque por encima de ellos los primeros fotogramas salen corruptos. Incluye audio sincronizado; esta vista exporta solo vídeo.",
        detailEN: "22B distilled, 8 steps. The sizes are smaller than the model allows because past them the opening frames come back corrupted. It includes synchronized audio; this view exports video only.",
        components: [
            ImageGenComponent(kind: .diffusion,
                urlString: "https://huggingface.co/unsloth/LTX-2.3-GGUF/resolve/main/distilled/ltx-2.3-22b-distilled-Q4_K_M.gguf",
                fileName: "ltx-2.3-22b-distilled-Q4_K_M.gguf", sizeGB: 14.33),
            ImageGenComponent(kind: .vae,
                urlString: "https://huggingface.co/unsloth/LTX-2.3-GGUF/resolve/main/vae/ltx-2.3-22b-distilled_video_vae.safetensors",
                fileName: "ltx-2.3-22b-distilled_video_vae.safetensors", sizeGB: 1.45),
            ImageGenComponent(kind: .audioVAE,
                urlString: "https://huggingface.co/unsloth/LTX-2.3-GGUF/resolve/main/vae/ltx-2.3-22b-distilled_audio_vae.safetensors",
                fileName: "ltx-2.3-22b-distilled_audio_vae.safetensors", sizeGB: 0.36),
            ImageGenComponent(kind: .connectors,
                urlString: "https://huggingface.co/unsloth/LTX-2.3-GGUF/resolve/main/text_encoders/ltx-2.3-22b-distilled_embeddings_connectors.safetensors",
                fileName: "ltx-2.3-22b-distilled_embeddings_connectors.safetensors", sizeGB: 2.31),
            ImageGenComponent(kind: .textEncoder,
                urlString: "https://huggingface.co/unsloth/gemma-3-12b-it-GGUF/resolve/main/gemma-3-12b-it-Q4_K_M.gguf",
                fileName: "gemma-3-12b-it-Q4_K_M.gguf", sizeGB: 7.30),
        ],
        // 2.37 is the engine's own default for LTX; 3.0 is the generic one for a
        // different prediction branch. Steps and CFG follow the model card.
        defaultSteps: 8, cfgScale: 1.0, flowShift: 2.37, minVRAMGB: 24,
        sizes: [VideoGenSize(width: 704, height: 384), VideoGenSize(width: 640, height: 352),
                VideoGenSize(width: 512, height: 288), VideoGenSize(width: 384, height: 704)],
        fps: 24,
        nativeFrames: 0, supportsI2V: true, recommendable: false,
        extraArgs: ["--offload-to-cpu"],
        negativePrompt: "worst quality, low quality, blurry, distorted, artifacts")

    /// HunyuanVideo 1.5, 720p. Qwen2.5-VL 7B does the conditioning, so it is heavy.
    static let hunyuanVideo15 = VideoGenModel(
        name: "HunyuanVideo 1.5",
        detailES: "8.3B, texto a vídeo a 720p y 24 fps. Receta oficial: 50 pasos, CFG 6 y shift 7; 24 GB de descarga.",
        detailEN: "8.3B text-to-video at 720p and 24 fps. Official recipe: 50 steps, CFG 6 and shift 7; a 24 GB download.",
        components: [
            ImageGenComponent(kind: .diffusion,
                urlString: "https://huggingface.co/Comfy-Org/HunyuanVideo_1.5_repackaged/resolve/main/split_files/diffusion_models/hunyuanvideo1.5_720p_t2v_fp16.safetensors",
                fileName: "hunyuanvideo1.5_720p_t2v_fp16.safetensors", sizeGB: 16.65),
            ImageGenComponent(kind: .vae,
                urlString: "https://huggingface.co/Comfy-Org/HunyuanVideo_1.5_repackaged/resolve/main/split_files/vae/hunyuanvideo15_vae_fp16.safetensors",
                fileName: "hunyuanvideo15_vae_fp16.safetensors", sizeGB: 2.52),
            ImageGenComponent(kind: .textEncoder,
                urlString: "https://huggingface.co/mradermacher/Qwen2.5-VL-7B-Instruct-GGUF/resolve/main/Qwen2.5-VL-7B-Instruct.Q4_K_M.gguf",
                fileName: "Qwen2.5-VL-7B-Instruct.Q4_K_M.gguf", sizeGB: 4.68),
            ImageGenComponent(kind: .t5,
                urlString: "https://huggingface.co/Comfy-Org/HunyuanVideo_1.5_repackaged/resolve/main/split_files/text_encoders/byt5_small_glyphxl_fp16.safetensors",
                fileName: "byt5_small_glyphxl_fp16.safetensors", sizeGB: 0.439),
        ],
        defaultSteps: 50, cfgScale: 6.0, flowShift: 7.0, minVRAMGB: 24,
        sizes: [VideoGenSize(width: 1280, height: 720), VideoGenSize(width: 960, height: 960),
                VideoGenSize(width: 720, height: 1280)],
        fps: 24,
        nativeFrames: 121, recommendable: false,
        extraArgs: ["--offload-to-cpu", "--vae-tiling"])

    static let all: [VideoGenModel] = [wan21T2V13B, wan22TI2V5B, wan21I2V14B,
                                       ltx23Distilled, hunyuanVideo15]

    /// Still some model's untouched default, so a model switch may reseed it.
    /// An emptied field is a deliberate choice and does not count.
    static func isDefaultNegative(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && all.contains { $0.negativePrompt == t }
    }

    /// Largest model the card can hold, falling back to the lightest.
    static func recommended(vramGB: Double) -> VideoGenModel {
        all.filter { $0.recommendable && $0.fitsVRAMClass(vramGB) }
            .max(by: { $0.minVRAMGB < $1.minVRAMGB }) ?? wan21T2V13B
    }
}

enum VideoGenLimits {
    /// Wan's VAE compresses time 4x, so the frame count has to be 4n+1 or the
    /// last chunk is dropped.
    static let frameCounts = [17, 33, 49, 65, 81]

    static func nearestFrameCount(_ n: Int) -> Int {
        frameCounts.min(by: { abs($0 - n) < abs($1 - n) }) ?? 33
    }

    /// Recommended capacity when the measured fit leaves little system headroom.
    static func recommendedVRAMGB(model: VideoGenModel, frames: Int) -> Double? {
        model.id == VideoGenCatalog.wan22TI2V5B.id && frames >= 49 ? 16 : nil
    }

    static func seconds(frames: Int, fps: Int) -> Double {
        Double(frames) / Double(max(1, fps))
    }

    /// Peak VRAM is the larger of the non-overlapping sampling and decode stages.
    static func estVRAMGB(px: Int, frames: Int, samplingResidentGB: Double,
                          decodeResidentGB: Double,
                          decodeWorkspaceAdjustmentGB: Double = 0,
                          samplingWorkspaceBaseMB: Double = 8,
                          samplingWorkspaceCoefficient: Double = 1.84e-4,
                          tiledDecode: Bool = true) -> Double {
        let lat = Double(latentFrames(frames))
        let samplingMB = samplingWorkspaceBaseMB
            + samplingWorkspaceCoefficient * Double(px) * lat
        let decodeMB = tiledDecode ? 3320 + 10 * lat : 6700 + 3.35e-2 * Double(px)
        let samplingPeak = samplingResidentGB + samplingMB / 1024
        let decodePeak = decodeResidentGB + decodeMB / 1024 + decodeWorkspaceAdjustmentGB
        return max(samplingPeak, decodePeak)
    }

    static func vramFraction(width: Int, height: Int, frames: Int,
                             vramGB: Double, model: VideoGenModel) -> Double {
        estVRAMGB(px: width * height, frames: frames,
                  samplingResidentGB: model.diffusionResidentGB,
                  decodeResidentGB: model.decodeResidentGB,
                  decodeWorkspaceAdjustmentGB: model.decodeWorkspaceAdjustmentGB,
                  samplingWorkspaceBaseMB: model.samplingWorkspaceBaseMB,
                  samplingWorkspaceCoefficient: model.samplingWorkspaceCoefficient,
                  tiledDecode: vaeTilingEnabled) / max(0.1, vramGB)
    }

    /// Latent frames: Wan's VAE compresses time 4x and the decoder walks them one
    /// at a time, so this is how many times the decode graph repeats itself.
    static func latentFrames(_ frames: Int) -> Int { (frames - 1) / 4 + 1 }

    static let nCB = 32

    static var vaeTilingEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.videoVAETiling) as? Bool ?? true
    }
}

@MainActor
final class VideoGenerator: ObservableObject {
    enum State: Equatable { case idle, generating, done, failed(String) }
    enum Stage { case loading, sampling, decoding }

    @Published var state: State = .idle
    @Published var stage: Stage = .loading
    @Published var progress: Double = 0
    @Published var stepText: String = ""
    /// Decoded frames in order, ready for the player.
    @Published var frames: [NSImage] = []
    @Published var frameURLs: [URL] = []
    @Published var lastDuration: Int = 0

    private(set) var lastPrompt = ""
    private(set) var lastSeed = -1
    private(set) var lastFPS = 16
    private(set) var lastWidth = 0
    private(set) var lastHeight = 0
    private(set) var lastFrameCount = 0
    private(set) var lastModelName = ""
    var onFinish: (() -> Void)?

    private var process: Process?
    private var startedAt: Date?
    private var firstStepAt: Date?
    private var logTail = ""
    private let fileLog = RotatingFileLog(name: "videogen")

    /// Newest video-gen log file, for the Logs tab to read (this generator lives in
    /// another window, so the file is the shared handoff).
    static var latestLogURL: URL? {
        let dir = AppSupport.directory.appendingPathComponent("logs", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("videogen") }
            .max { a, b in (mtime(a) ?? .distantPast) < (mtime(b) ?? .distantPast) }
    }
    private static func mtime(_ u: URL) -> Date? {
        try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    var isBusy: Bool { if case .generating = state { return true }; return false }
    var elapsed: Int { startedAt.map { Int(-$0.timeIntervalSinceNow) } ?? 0 }

    /// The VAE decode is a much bigger share of a video run than of an image one,
    /// so the tail allowance is larger here.
    var etaSeconds: Int? {
        guard let first = firstStepAt, progress > 0.001, progress < 1 else { return nil }
        let spent = -first.timeIntervalSinceNow
        return max(0, Int(spent / progress * (1 - progress) + spent * 0.35))
    }

    static var binary: String { ImageGenerator.binary }
    static var engineInstalled: Bool { ImageGenerator.engineInstalled }

    static func installed(_ model: VideoGenModel, in models: ModelStore) -> Bool {
        model.components.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path(in: models.imagenDirectory).path)
        }
    }

    func generate(model: VideoGenModel, models: ModelStore, prompt: String,
                  negativePrompt: String,
                  width: Int, height: Int, frames frameCount: Int, steps: Int,
                  seed: Int, fps: Int, gpuIndex: Int,
                  initImagePath: String = "") {
        guard !isBusy else { return }
        lastPrompt = prompt; lastSeed = seed; lastFPS = fps
        lastWidth = width; lastHeight = height; lastFrameCount = frameCount
        lastModelName = model.name
        let dir = models.imagenDirectory

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH.mm.ss"
        let token = String(UUID().uuidString.prefix(4)).lowercased()
        let runDir = dir.appendingPathComponent("video/toshllm_\(fmt.string(from: Date()))_\(token)",
                                                isDirectory: true)
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)

        var args: [String] = ["-M", "vid_gen"]
        for comp in model.components {
            args += [comp.flag, comp.path(in: dir).path]
        }
        args += [
            "-p", prompt,
            "--cfg-scale", String(format: "%.1f", model.cfgScale),
            "--flow-shift", String(format: "%.1f", model.flowShift),
            "--sampling-method", "euler",
            "--steps", String(steps),
            "-W", String(width), "-H", String(height),
            "--video-frames", String(frameCount),
            "--fps", String(fps),
            "--seed", String(seed),
            // measured 6% faster sampling on RDNA2 with byte-identical output
            "--diffusion-fa",
            // umt5 is 6.66 GB and does nothing after the first 20 s; in RAM it costs
            // 12 s of encode once and frees the VRAM that caps resolution
            "--params-backend", "te=cpu",
            // a PNG sequence, not a container: the app animates the frames
            "-o", runDir.appendingPathComponent("frame_%03d.png").path,
        ]
        let negative = negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !negative.isEmpty { args += ["-n", negative] }
        if !initImagePath.isEmpty && model.supportsI2V {
            args += ["-i", initImagePath]
        }
        if VideoGenLimits.vaeTilingEnabled && !model.extraArgs.contains("--vae-tiling") {
            args.append("--vae-tiling")
        }
        args += model.extraArgs

        var env = ProcessInfo.processInfo.environment
        // The wide matmul tile is tuned for LLM prefill shapes; on diffusion it costs
        // 1.7% on SDXL and 3% on Wan, with byte-identical output. Measured 08-14.
        env["TOSH_MM_WIDE_DISABLE"] = "1"
        // Split each graph into enough command buffers to clear the GPU watchdog.
        env["GGML_METAL_NCB"] = String(VideoGenLimits.nCB)
        env["TOSH_VAE_TILE_YIELD_MS"] = "100"
        env["TOSH_FA_AMD"] = "1"
        let devices = MTLCopyAllDevices()
        if gpuIndex >= 0 && devices.count > 1 {
            env["GGML_METAL_DEVICE_INDEX"] = String(gpuIndex)
        }
        let external = gpuIndex >= 0 && gpuIndex < devices.count && devices[gpuIndex].location == .external
        if UserDefaults.standard.bool(forKey: SettingsKeys.forcePrivateBuffers) || external {
            env["GGML_METAL_SHARED_BUFFERS_DISABLE"] = "1"
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
            Task { @MainActor in self?.consume(text) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.finish(status: proc.terminationStatus, runDir: runDir) }
        }

        fileLog.startSession()
        fileLog.append("$ sd-cli " + args.joined(separator: " ") + "\n\n")

        frames = []
        frameURLs = []
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
            onFinish?()
        }
    }

    func cancel() { process?.terminate() }

    /// Playback copy: full frames are only needed for the mp4, which reads the PNGs.
    nonisolated static func displayFrame(_ url: URL) -> NSImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 960,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { return NSImage(contentsOf: url) }
        return NSImage(cgImage: cg, size: .zero)
    }

    private func consume(_ text: String) {
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

    private func finish(status: Int32, runDir: URL) {
        process = nil
        let urls = ((try? FileManager.default.contentsOfDirectory(at: runDir,
                                                                  includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard status == 0, !urls.isEmpty else {
            if status == 15 || status == 2 { state = .failed(""); onFinish?(); return }
            if logTail.contains("failed to allocate") { state = .failed("OOM"); onFinish?(); return }
            let timedOut = logTail.contains("Timeout") || logTail.contains("status 5")
            state = .failed(timedOut ? "TIMEOUT" : "exit \(status)")
            onFinish?()
            return
        }
        frameURLs = urls
        progress = 1
        lastDuration = elapsed
        Task.detached(priority: .userInitiated) {
            let decoded = urls.compactMap { Self.displayFrame($0) }
            await MainActor.run {
                self.frames = decoded
                self.state = .done
                self.onFinish?()
            }
        }
    }
}

// MARK: - Video studio session and batch queue

struct VideoGenerationRequest: Identifiable {
    let id: UUID
    var modelName: String
    var prompt: String
    var negativePrompt: String
    var width: Int
    var height: Int
    var frameCount: Int
    var steps: Int
    var seed: Int
    var fps: Int
    var gpuIndex: Int
    var initImagePath: String

    init(id: UUID = UUID(), modelName: String, prompt: String, negativePrompt: String,
         width: Int, height: Int, frameCount: Int, steps: Int, seed: Int,
         fps: Int, gpuIndex: Int, initImagePath: String) {
        self.id = id
        self.modelName = modelName
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.steps = steps
        self.seed = seed
        self.fps = fps
        self.gpuIndex = gpuIndex
        self.initImagePath = initImagePath
    }

    var model: VideoGenModel {
        VideoGenCatalog.all.first { $0.name == modelName } ?? VideoGenCatalog.all[0]
    }
}

struct GeneratedVideo: Identifiable {
    let id = UUID()
    let frameURLs: [URL]
    let preview: NSImage?
    let prompt: String
    let modelName: String
    let width: Int
    let height: Int
    let frameCount: Int
    let fps: Int
    let seed: Int
    let duration: Int

    var folderURL: URL? { frameURLs.first?.deletingLastPathComponent() }
}

enum VideoStudioSection { case videos, queue }

@MainActor
final class VideoGenPool: ObservableObject {
    let generator = VideoGenerator()
    @Published var queue: [VideoGenerationRequest] = []
    @Published var gallery: [GeneratedVideo] = []
    @Published var queueActive = false
    @Published var section: VideoStudioSection = .videos

    weak var modelStore: ModelStore?
    private var currentRequest: VideoGenerationRequest?
    private var forward: AnyCancellable?

    init() {
        forward = generator.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        generator.onFinish = { [weak self] in self?.finishedCurrentRun() }
    }

    var isBusy: Bool { generator.isBusy }

    func generate(_ request: VideoGenerationRequest) {
        guard !generator.isBusy, let models = modelStore else { return }
        currentRequest = request
        generator.generate(model: request.model, models: models, prompt: request.prompt,
                           negativePrompt: request.negativePrompt,
                           width: request.width, height: request.height,
                           frames: request.frameCount, steps: request.steps,
                           seed: request.seed, fps: request.fps,
                           gpuIndex: request.gpuIndex,
                           initImagePath: request.initImagePath)
    }

    func enqueue(_ request: VideoGenerationRequest) {
        queue.append(request)
        section = .queue
        if queueActive { pump() }
    }

    func remove(_ id: UUID) { queue.removeAll { $0.id == id } }

    func startQueue() {
        queueActive = true
        section = .queue
        pump()
    }

    func stopQueue() { queueActive = false }

    func cancelCurrent() { generator.cancel() }

    private func pump() {
        guard queueActive, modelStore != nil, !generator.isBusy, !queue.isEmpty else {
            if queue.isEmpty && !generator.isBusy { queueActive = false }
            return
        }
        generate(queue.removeFirst())
    }

    private func finishedCurrentRun() {
        defer {
            currentRequest = nil
            pump()
        }
        guard case .done = generator.state,
              !generator.frameURLs.isEmpty,
              let request = currentRequest else { return }
        gallery.insert(GeneratedVideo(frameURLs: generator.frameURLs,
                                      preview: generator.frames.first
                                          ?? generator.frameURLs.first.flatMap(VideoGenerator.displayFrame),
                                      prompt: request.prompt,
                                      modelName: request.modelName,
                                      width: request.width,
                                      height: request.height,
                                      frameCount: request.frameCount,
                                      fps: request.fps,
                                      seed: request.seed,
                                      duration: generator.lastDuration), at: 0)
        if gallery.count > 30 { gallery.removeLast() }
    }
}

/// Writes the frame sequence as an H.264 mp4. AVFoundation can encode it natively,
/// which is the whole reason the engine's own .webm is not what we hand the user.
enum VideoExporter {
    enum ExportError: Error { case noFrames, writerFailed(String) }

    static func writeMP4(frames: [NSImage], fps: Int, to url: URL) throws {
        guard let first = frames.first else { throw ExportError.noFrames }
        // H.264 needs even dimensions.
        let w = Int(first.size.width) & ~1
        let h = Int(first.size.height) & ~1
        guard w > 0, h > 0 else { throw ExportError.noFrames }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for (i, image) in frames.enumerated() {
            guard let buffer = pixelBuffer(from: image, width: w, height: h) else { continue }
            // the input drains asynchronously; spin instead of dropping frames
            while !input.isReadyForMoreMediaData { usleep(2000) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i),
                                                                timescale: CMTimeScale(max(1, fps))))
        }
        input.markAsFinished()

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
    }

    private static func pixelBuffer(from image: NSImage, width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                  width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
