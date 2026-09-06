// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Metal
import Combine
import ImageIO
import UniformTypeIdentifiers

// Local text-to-image via a bundled stable-diffusion.cpp engine. A model is one
// or more files (a full checkpoint, or a diffusion transformer plus its VAE and
// text encoders), kept in an `imagen/` subfolder so they stay out of the LLM
// model list. The catalog spans GPU sizes: tiny models for small cards, heavier
// ones for large VRAM.

/// One downloadable piece of an image model, tagged with the sd-cli flag it maps to.
struct ImageGenComponent: Identifiable {
    enum Kind { case checkpoint, diffusion, vae, audioVAE, connectors, textEncoder, t5, clipL }
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
        case .audioVAE:    return "--audio-vae"
        case .connectors:  return "--embeddings-connectors"
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
        case .audioVAE:    return spanish ? "VAE de audio" : "Audio VAE"
        case .connectors:  return spanish ? "Conectores" : "Connectors"
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
    /// Rough usable VRAM (GB) below which it won't fit well. Drives the pick. Measured for
    /// SD 1.5, SDXL Turbo and Z-Image (resident weights plus the graph at 1024x1024, 08-19);
    /// derived from the same formula for the rest, cross-checked against what each model
    /// publishes for a comparable quantisation with the text encoder off the card.
    let minVRAMGB: Double
    /// False = shown and usable, but never the auto-recommended pick.
    var recommendable: Bool = true
    /// Largest long-edge (px) to offer as a quality guard: UNet models blur past
    /// their native size. VRAM is handled separately by attnVRAMSq.
    var maxLongEdge: Int = 2048
    /// Long edge (px) this model is known to hold up to. Past it the composition
    /// starts to repeat (two horizons, duplicated subjects), which is the model's
    /// limit and not the app's, so the UI says so instead of leaving the user
    /// guessing. 0 means no note: only set it where there is a published figure or
    /// a measurement, never a guess, or the warning cries wolf.
    var nativeLongEdge: Int = 0
    /// Trained on square frames only, so any other shape comes out with colour blotches
    /// however many steps it takes. The newer models saw many aspect ratios and are fine.
    var trainedSquareOnly: Bool = false
    /// Extra VRAM (GB) per pixel² from self-attention built in full, which grows
    /// quadratically with resolution (issue #25: SD1.5 OOMs far below the linear
    /// budget). Only for models the AMD attention kernels do not cover: they take
    /// head sizes of 64, 128, 256 and 512, so SD 1.5 (40, 80, 160) still pays it
    /// while SDXL and every DiT no longer do. 0 means the attention is streamed.
    var attnVRAMSq: Double = 0

    /// Metal reports the working-set limit, not physical VRAM (a 16 GB card
    /// shows ~15 GB), so the class check tolerates a small shortfall.
    func fitsVRAMClass(_ vramGB: Double) -> Bool { vramGB >= minVRAMGB * 0.9 }

    /// Fit check aware of the encoder/VAE split: minVRAMGB assumes everything on
    /// one card, so with an aux GPU gate on the diffusion-resident budget instead,
    /// plus the aux card holding the moved components.
    func fitsGPU(mainVRAM: Double, auxVRAM: Double?) -> Bool {
        guard let auxVRAM else { return fitsVRAMClass(mainVRAM) }
        return auxVRAM >= totalGB - residentGB
            && !ImageGenLimits.baseSizes(vramGB: mainVRAM, residentGB: residentGB,
                                         attnVRAMSq: attnVRAMSq, maxLongEdge: maxLongEdge).isEmpty
    }

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
    /// Non-gated FLUX autoencoder mirror, shared by Z-Image and Flux. The f16 copy: a GPU
    /// without bfloat cannot run any op on bf16 weights and generation stops on the first.
    private static func fluxVAE(_ name: String) -> ImageGenComponent {
        ImageGenComponent(kind: .vae,
            urlString: "https://huggingface.co/wbruna/Z-Image-Turbo-sdcpp-GGUF/resolve/main/ae-f16.gguf",
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
        // square only: measured 08-19, 512x288 and 768x432 come back with magenta blotches
        // in the background at the same steps that give a clean 512x512
        defaultSteps: 20, cfgScale: 7.0, minVRAMGB: 3, maxLongEdge: 768,
        nativeLongEdge: 512, trainedSquareOnly: true, attnVRAMSq: 3.4e-12)

    /// SDXL Turbo (3.5B, single checkpoint). Few steps, opens the LoRA/style world.
    static let sdxlTurbo = ImageGenModel(
        name: "SDXL Turbo",
        detailES: "3.5B, pocos pasos. Buena calidad y compatible con LoRAs/estilos SDXL.",
        detailEN: "3.5B, few steps. Strong quality and compatible with SDXL LoRAs/styles.",
        components: [ImageGenComponent(kind: .checkpoint,
            urlString: "https://huggingface.co/stabilityai/sdxl-turbo/resolve/main/sd_xl_turbo_1.0_fp16.safetensors",
            fileName: "sd_xl_turbo_1.0_fp16.safetensors", sizeGB: 6.6)],
        // measured 08-19: 5060 MB resident (its encoder goes to RAM) + 492 MB of graph.
        // attnVRAMSq only applies on cards without the attention kernels (safe mode).
        defaultSteps: 6, cfgScale: 1.0, minVRAMGB: 6, maxLongEdge: 1280,
        nativeLongEdge: 512, attnVRAMSq: 5e-13)

    /// Z-Image Turbo (6B DiT, 8 steps, Apache). Diffusion + VAE + Qwen3-4B encoder.
    static let zImageTurbo = ImageGenModel(
        name: "Z-Image Turbo",
        detailES: "6B, 8 pasos, Apache. Rápido y fotorrealista; el mejor equilibrio en tarjetas AMD.",
        detailEN: "6B, 8 steps, Apache. Fast and photorealistic; the best balance on AMD cards.",
        components: [
            ImageGenComponent(kind: .diffusion,
                urlString: "https://huggingface.co/leejet/Z-Image-Turbo-GGUF/resolve/main/z_image_turbo-Q4_0.gguf",
                fileName: "z_image_turbo-Q4_0.gguf", sizeGB: 3.5),
            fluxVAE("z_image_ae-f16.gguf"),
            ImageGenComponent(kind: .textEncoder,
                urlString: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
                fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf", sizeGB: 2.4),
        ],
        // measured 08-19: 3673 MB resident + 690 MB of graph at 1024x1024, and holds up at
        // 2048x2048 and 2560x1440 with no repeated composition
        defaultSteps: 8, cfgScale: 1.0, minVRAMGB: 6, nativeLongEdge: 2048)

    /// Flux.1 schnell (12B, 4 steps, Apache). Top prompt adherence for large GPUs.
    static let fluxSchnell = ImageGenModel(
        name: "Flux.1 schnell",
        detailES: "12B, 4 pasos, Apache. Máxima adherencia al prompt.",
        detailEN: "12B, 4 steps, Apache. Top prompt adherence.",
        components: [
            ImageGenComponent(kind: .diffusion,
                urlString: "https://huggingface.co/city96/FLUX.1-schnell-gguf/resolve/main/flux1-schnell-Q4_0.gguf",
                fileName: "flux1-schnell-Q4_0.gguf", sizeGB: 6.4),
            fluxVAE("flux_ae-f16.gguf"),
            ImageGenComponent(kind: .t5,
                urlString: "https://huggingface.co/city96/t5-v1_1-xxl-encoder-gguf/resolve/main/t5-v1_1-xxl-encoder-Q4_K_M.gguf",
                fileName: "t5-v1_1-xxl-encoder-Q4_K_M.gguf", sizeGB: 2.76),
            ImageGenComponent(kind: .clipL,
                urlString: "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors",
                fileName: "clip_l.safetensors", sizeGB: 0.23),
        ],
        // lower minimum than before, but Z-Image stays the curated pick for these cards
        defaultSteps: 4, cfgScale: 1.0, minVRAMGB: 8, recommendable: false)

    /// Non-gated FLUX.2 autoencoder (full encoder + small decoder), shared by the
    /// Flux 2 family; the reference `ae.safetensors` lives in a gated BFL repo.
    private static let flux2VAE = ImageGenComponent(kind: .vae,
        urlString: "https://huggingface.co/black-forest-labs/FLUX.2-small-decoder/resolve/main/full_encoder_small_decoder.safetensors",
        fileName: "flux2_full_encoder_small_decoder.safetensors", sizeGB: 0.25)

    /// Flux.2 klein 4B: the lightest Flux 2 (4 steps). `recommendable:false` keeps Z-Image the curated AMD pick.
    static let flux2Klein4B = ImageGenModel(
        name: "Flux.2 klein 4B",
        detailES: "4B, 4 pasos, Apache. El Flux 2 más ligero: rápido y deja más VRAM para imágenes grandes.",
        detailEN: "4B, 4 steps, Apache. The lightest Flux 2: fast, and leaves more VRAM for larger images.",
        components: [
            ImageGenComponent(kind: .diffusion,
                urlString: "https://huggingface.co/leejet/FLUX.2-klein-4B-GGUF/resolve/main/flux-2-klein-4b-Q4_0.gguf",
                fileName: "flux-2-klein-4b-Q4_0.gguf", sizeGB: 2.46),
            flux2VAE,
            ImageGenComponent(kind: .textEncoder,
                urlString: "https://huggingface.co/unsloth/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf",
                fileName: "Qwen3-4B-Q4_K_M.gguf", sizeGB: 2.5),
        ],
        defaultSteps: 4, cfgScale: 1.0, minVRAMGB: 6, recommendable: false,
        extraArgs: ["--sampling-method", "euler"])

    /// Flux.2 klein 9B (step-distilled, Apache). Flux 2 quality for 16 GB GPUs.
    static let flux2Klein9B = ImageGenModel(
        name: "Flux.2 klein 9B",
        detailES: "9B, 4 pasos, Apache. La calidad de Flux 2 sin la descarga de 30 GB.",
        detailEN: "9B, 4 steps, Apache. Flux 2 quality without the 30 GB download.",
        components: [
            ImageGenComponent(kind: .diffusion,
                urlString: "https://huggingface.co/leejet/FLUX.2-klein-9B-GGUF/resolve/main/flux-2-klein-9b-Q4_0.gguf",
                fileName: "flux-2-klein-9b-Q4_0.gguf", sizeGB: 5.6),
            flux2VAE,
            ImageGenComponent(kind: .textEncoder,
                urlString: "https://huggingface.co/unsloth/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q4_K_M.gguf",
                fileName: "Qwen3-8B-Q4_K_M.gguf", sizeGB: 5.0),
        ],
        defaultSteps: 4, cfgScale: 1.0, minVRAMGB: 10, recommendable: false,
        extraArgs: ["--sampling-method", "euler"])

    /// Flux.2 dev (32B). The quality reference; enormous, non-commercial license.
    /// The 24B text encoder forces --offload-to-cpu so only the sampling model
    /// holds VRAM at a time.
    static let flux2Dev = ImageGenModel(
        name: "Flux.2 dev",
        detailES: "32B, la referencia de calidad. Muy pesado (34 GB de descarga). Licencia no comercial.",
        detailEN: "32B, the quality reference. Very heavy (34 GB download). Non-commercial license.",
        components: [
            ImageGenComponent(kind: .diffusion,
                urlString: "https://huggingface.co/city96/FLUX.2-dev-gguf/resolve/main/flux2-dev-Q4_K_S.gguf",
                fileName: "flux2-dev-Q4_K_S.gguf", sizeGB: 19.3),
            flux2VAE,
            ImageGenComponent(kind: .textEncoder,
                urlString: "https://huggingface.co/unsloth/Mistral-Small-3.2-24B-Instruct-2506-GGUF/resolve/main/Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf",
                fileName: "Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf", sizeGB: 14.3),
        ],
        defaultSteps: 20, cfgScale: 1.0, minVRAMGB: 24, recommendable: false,
        extraArgs: ["--sampling-method", "euler", "--offload-to-cpu"])

    /// Qwen-Image (20B MMDiT). The one that renders legible text inside images.
    /// Heavy: for 24 GB+ GPUs. Text encoder is Qwen2.5-VL.
    static let qwenImage = ImageGenModel(
        name: "Qwen-Image",
        detailES: "20B. Escribe texto legible dentro de la imagen. Muy pesado y lento.",
        detailEN: "20B. Renders legible text inside images. Heavy and slow.",
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
        defaultSteps: 20, cfgScale: 2.5, minVRAMGB: 16,
        extraArgs: ["--backend", "vae=cpu"])

    /// Curated order (small to large). Z-Image sits before SDXL so it wins the
    /// 8-12 GB tie as the recommended pick (validated for photorealism on AMD);
    /// klein 9B sits before schnell to win the 16 GB tie the same way.
    static let models: [ImageGenModel] = [sd15, zImageTurbo, sdxlTurbo,
                                          flux2Klein4B, flux2Klein9B, fluxSchnell, qwenImage, flux2Dev]

    /// The best model this GPU can run: the highest min-VRAM tier that fits, and
    /// within a tie the earliest listed (curated preference).
    static func recommended(for hw: HardwareInfo) -> ImageGenModel? {
        let fitting = models.filter { $0.recommendable && $0.fitsVRAMClass(hw.vramGB) }
        guard let top = fitting.map(\.minVRAMGB).max() else { return nil }
        return fitting.first { $0.minVRAMGB == top }
    }

    static func model(id: String) -> ImageGenModel? { models.first { $0.id == id } }

    /// Sentinel id for the user's own model (files picked from disk).
    static let customID = "__custom__"

    /// Build a model from user-picked files: a checkpoint (or diffusion model) and
    /// an optional VAE. Passed as a full checkpoint via --model, which covers most
    /// community SD/SDXL finetunes; minVRAMGB 0 so it's never blocked.
    static func custom(modelPath: String, vaePath: String, textEncoderPath: String = "",
                       isDiffusion: Bool = false, steps: Int, cfg: Double) -> ImageGenModel {
        func gb(_ p: String) -> Double {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? Int ?? 0
            return Double(bytes) / 1_073_741_824
        }
        var comps = [ImageGenComponent(kind: isDiffusion ? .diffusion : .checkpoint, urlString: "",
                                       fileName: modelPath, sizeGB: gb(modelPath))]
        if !vaePath.isEmpty {
            comps.append(ImageGenComponent(kind: .vae, urlString: "", fileName: vaePath, sizeGB: gb(vaePath)))
        }
        if !textEncoderPath.isEmpty {
            comps.append(ImageGenComponent(kind: .textEncoder, urlString: "",
                                           fileName: textEncoderPath, sizeGB: gb(textEncoderPath)))
        }
        // Assume the SD/SDXL UNet family (the common custom case) for the VRAM cap.
        return ImageGenModel(name: "Custom",
            detailES: "Tu propio modelo. Ajusta pasos y CFG según su ficha.",
            detailEN: "Your own model. Set steps and CFG to match its card.",
            components: comps, defaultSteps: steps, cfgScale: cfg, minVRAMGB: 0,
            attnVRAMSq: 3.4e-12)
    }
}

/// Resolution and command-buffer limits derived from the detected GPU. Large
/// diffusion runs hit two ceilings on AMD: VRAM (the compute buffer grows with
/// pixels) and the macOS GPU watchdog (a single command buffer that runs too long
/// is killed). These pick sizes that clear both.
enum ImageGenLimits {
    /// Estimated peak VRAM (GB): resident weights, half a gigabyte of runtime, and
    /// the larger of the two graphs, which never overlap (the model samples, then
    /// the VAE decodes). Recalibrated 08-19 against the sizes the engine reports,
    /// with the attention going through the AMD kernels: the diffusion graph is a
    /// straight line in pixels (690 MB at 1024x1024, 966 at 1600x900 and 2757 at
    /// 2048x2048 on Z-Image; SDXL is lower, so this is the conservative side) and
    /// the tiled VAE decode is flat at about 0.5 GB whatever the frame size. The
    /// quadratic term only survives for models those kernels do not cover.
    static func estVRAMGB(px: Int, residentGB: Double, attnVRAMSq: Double,
                          streamedAttention: Bool = true) -> Double {
        let p = Double(px)
        guard streamedAttention else {
            // A card the attention kernels do not cover builds the score matrix whole, and
            // then memory grows with the square of the frame again. This is the estimate as
            // it was calibrated for that case, kept for exactly those cards.
            return residentGB + 1.0 + 4.5e-6 * p + attnVRAMSq * p * p
        }
        let graphMB = max(6.6e-4 * p, 500)
        return residentGB + 0.5 + graphMB / 1024
    }

    /// Whether this GPU runs attention through the card's own kernels, which is what keeps
    /// the graph linear. Apple Silicon uses the upstream path and AMD ours; the 64-wide
    /// cards lose it in safe mode, which is the case the estimate must not get wrong.
    static func streamsAttention(gpuName: String, extraArgs: String) -> Bool {
        guard extraArgs.contains("GGML_METAL_WAVE64_SAFEMODE") else { return true }
        return GPUArchitectureClassifier.architecture(for: gpuName) != "GCN / Vega"
    }

    /// Base (long-edge) sizes to offer: a 16:9 frame at that base must fit VRAM,
    /// capped by the model's quality ceiling. Scales with the card and the model.
    /// Does this card stream attention? Read from the selected GPU and the engine's extra
    /// arguments, so a card in safe mode gets the estimate that matches what it really does.
    static func streamsAttention(gpuIndex: Int) -> Bool {
        let d = UserDefaults.standard
        let extra = d.string(forKey: SettingsKeys.extraArgs) ?? ""
        let devices = MTLCopyAllDevices()
        let name = (gpuIndex >= 0 && gpuIndex < devices.count)
            ? devices[gpuIndex].name
            : (MTLCreateSystemDefaultDevice()?.name ?? "")
        return streamsAttention(gpuName: name, extraArgs: extra)
    }

    static func baseSizes(vramGB: Double, residentGB: Double,
                          attnVRAMSq: Double = 0, maxLongEdge: Int = .max,
                          streamedAttention: Bool = true) -> [Int] {
        let candidates = [512, 640, 768, 896, 1024, 1152, 1280, 1440,
                          1600, 1792, 2048, 2304, 2560, 3072]
        return candidates.filter { base in
            guard base <= maxLongEdge else { return false }
            let short = max(256, Int((Double(base) * 9 / 16 / 64).rounded()) * 64)
            return fits(width: base, height: short, vramGB: vramGB,
                        residentGB: residentGB, attnVRAMSq: attnVRAMSq,
                        streamedAttention: streamedAttention)
        }
    }

    /// True when a specific frame's estimated VRAM fits (a square at a large base,
    /// or any UNet frame at high res, may not even when a 16:9 base does).
    static func fits(width: Int, height: Int, vramGB: Double,
                     residentGB: Double, attnVRAMSq: Double = 0,
                     streamedAttention: Bool = true) -> Bool {
        estVRAMGB(px: width * height, residentGB: residentGB, attnVRAMSq: attnVRAMSq,
                  streamedAttention: streamedAttention) <= vramGB
    }

    /// Fraction of VRAM the frame is estimated to use (drives the near-limit note).
    static func vramFraction(width: Int, height: Int, vramGB: Double,
                             residentGB: Double, attnVRAMSq: Double = 0,
                             streamedAttention: Bool = true) -> Double {
        estVRAMGB(px: width * height, residentGB: residentGB, attnVRAMSq: attnVRAMSq,
                  streamedAttention: streamedAttention) / max(0.1, vramGB)
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
    case cinema = "2.39:1"
    case custom = "custom"
    var id: String { rawValue }

    /// Snap to the latent grid (multiples of 64 px), min 256.
    static func gridSnap(_ v: Double) -> Int { max(256, Int((v / 64).rounded()) * 64) }

    /// (width, height) with `base` as the longer edge, rounded to the latent grid.
    func dimensions(base: Int) -> (Int, Int) {
        let short9x16 = Self.gridSnap(Double(base) * 9 / 16)
        let short3x4  = Self.gridSnap(Double(base) * 3 / 4)
        switch self {
        case .square:    return (base, base)
        case .landscape: return (base, short9x16)
        case .portrait:  return (short9x16, base)
        case .photo:     return (base, short3x4)
        case .photoTall: return (short3x4, base)
        case .cinema:    return (base, Self.gridSnap(Double(base) / 2.39))
        case .custom:    return (base, base)   // ratio comes from the config, see customDimensions
        }
    }

    /// Dimensions for a free "W:H" ratio with `base` as the long edge. `base` still
    /// caps the pixel count (VRAM stays safe); falls back to square if unparseable.
    static func customDimensions(ratio: String, base: Int) -> (Int, Int) {
        let parts = ratio.split(whereSeparator: { ":x/ ".contains($0) }).compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return (base, base) }
        let (rw, rh) = (parts[0], parts[1])
        return rw >= rh ? (base, gridSnap(Double(base) * rh / rw))
                        : (gridSnap(Double(base) * rw / rh), base)
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
    /// Latent preview refreshed by the engine every few steps, so the wait shows
    /// the image forming instead of a bare bar.
    @Published var previewImage: NSImage?
    /// Wall-clock seconds of the last completed run, for the "generated in" caption.
    @Published var lastDuration: Int = 0

    /// Called after a run settles (done, failed or cancelled). The pool uses it to
    /// dispatch the next queued prompt.
    var onFinish: (() -> Void)?
    /// The last run's inputs, so the session gallery can label the result.
    private(set) var lastPrompt = ""
    private(set) var lastSeed = -1
    private(set) var lastWidth = 0
    private(set) var lastHeight = 0

    private var process: Process?
    private var startedAt: Date?
    private var firstStepAt: Date?
    private var previewURL: URL?
    private var previewTimer: Timer?
    private var previewSeenAt: Date?
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

    /// sd-cli --backend spec for the encoder/VAE split: diffusion on Metal slot 0,
    /// text encoder and VAE on slot 1. Entries from the model's own spec win per
    /// module (keys normalized, since sd-cli accepts synonyms like clip/t5/tae).
    nonisolated static func splitBackendSpec(overriding overrides: String?) -> String {
        func canon(_ key: String) -> String {
            switch key {
            case "model", "unet", "dit": return "diffusion"
            case "clip", "text", "textencoder", "textencoders",
                 "conditioner", "cond", "llm", "t5", "t5xxl": return "te"
            case "firststage", "autoencoder", "tae": return "vae"
            default: return key
            }
        }
        var map = ["diffusion": "mtl0", "te": "mtl1", "vae": "mtl1"]
        for pair in (overrides ?? "").split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
            if kv.count == 2, !kv[0].isEmpty, !kv[1].isEmpty { map[canon(kv[0])] = kv[1] }
        }
        return map.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    /// Generate an image. `prompt` is required; the rest are the tuned defaults
    /// unless the caller overrides them.
    func generate(model: ImageGenModel, models: ModelStore, prompt: String,
                  negativePrompt: String = "",
                  width: Int, height: Int, steps: Int, seed: Int,
                  format: ImageFormat, offloadToCPU: Bool, gpuIndex: Int,
                  auxGPUIndex: Int = -1,
                  initImagePath: String = "", maskPath: String = "",
                  strength: Double = 0.75) {
        guard !isBusy else { return }
        lastPrompt = prompt; lastSeed = seed; lastWidth = width; lastHeight = height
        let dir = models.imagenDirectory
        // Timestamp plus a short token: a batch fired in the same second (one run
        // per instance) would otherwise share a name and overwrite a single file.
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH.mm.ss"
        let token = String(UUID().uuidString.prefix(4)).lowercased()
        let out = dir.appendingPathComponent("toshllm_\(fmt.string(from: Date()))_\(token).\(format.ext)")

        // Each component maps to its own sd-cli flag (a full checkpoint via --model,
        // or a diffusion model plus its VAE and text encoders).
        var args: [String] = []
        for comp in model.components {
            args += [comp.flag, comp.path(in: dir).path]
        }
        // sd-cli picks a LoRA up from the prompt, as <lora:file:weight>, but only when it knows
        // where to look. The folder is only passed when it holds something, so an empty one
        // does not make the engine scan on every run.
        if let lora = ImageGenPool.loraDirectory(), ImageGenPool.loraFiles(in: lora).isEmpty == false {
            args += ["--lora-model-dir", lora.path]
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
            // Attention through the card's own kernels instead of building the whole
            // table: 2379 to 690 MB at 1024x1024 on Z-Image and 8243 to 966 at
            // 1600x900, which is what used to run past the largest block the card
            // allows. Also 12 to 14% quicker, same image (45.8 to 50.6 dB).
            "--diffusion-fa",
            // The text encoder runs once and then sits in VRAM for the whole
            // sampling: measured 1.56 GB freed on SDXL for 0.4 s of encode.
            "--params-backend", "te=cpu",
            // The output format follows the file extension (PNG lossless, JPG lighter).
            "-o", out.path,
        ]
        let negative = negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !negative.isEmpty { args += ["-n", negative] }
        // `proj` needs no extra weights (it projects the latents), so the preview
        // costs a rescale per interval and never a second model download.
        let preview = FileManager.default.temporaryDirectory
            .appendingPathComponent("toshllm-preview-\(token).png")
        previewURL = preview
        args += ["--preview", "proj", "--preview-interval", "3", "--preview-path", preview.path]
        // img2img: seed the run with an existing image. Strength is how much to
        // change it (0 keeps it, 1 regenerates from scratch).
        if !initImagePath.isEmpty {
            args += ["-i", initImagePath, "--strength", String(format: "%.2f", strength)]
            if !maskPath.isEmpty { args += ["--mask", maskPath] }
        }
        let split = auxGPUIndex >= 0 && auxGPUIndex != gpuIndex && gpuIndex >= 0
            && MTLCopyAllDevices().count > 1
        var extra = model.extraArgs
        if split {
            // Merge the split assignment with the model's own --backend (e.g.
            // qwen-image forces vae=cpu), which wins per module.
            var overrides: String? = nil
            if let i = extra.firstIndex(of: "--backend"), i + 1 < extra.count {
                overrides = extra[i + 1]
                extra.removeSubrange(i...(i + 1))
            }
            args += ["--backend", Self.splitBackendSpec(overriding: overrides)]
        }
        // Offloading the diffusion model to CPU trades speed for VRAM; measured to
        // make no difference here, so it's off by default and only a fallback.
        args += extra
        if offloadToCPU && !extra.contains("--offload-to-cpu") {
            args.append("--offload-to-cpu")
        }

        var env = ProcessInfo.processInfo.environment
        // The wide matmul tile is tuned for LLM prefill shapes; on diffusion it costs
        // 1.7% on SDXL and 3% on Wan, with byte-identical output. Measured 08-14.
        env["TOSH_MM_WIDE_DISABLE"] = "1"
        // The flash-attention kernels for AMD are opt-in; without this the backend
        // turns --diffusion-fa down and the attention is materialized instead.
        env["TOSH_FA_AMD"] = "1"
        // AMD discrete GPUs corrupt output without disabling Metal concurrency;
        // Apple Silicon keeps it on. Mirrors the LLM engine defaults.
        // Split each step into enough command buffers to clear the GPU watchdog.
        env["GGML_METAL_NCB"] = String(ImageGenLimits.nCB(width: width, height: height))
        // Pin the chosen GPU (slot maps to MTLCopyAllDevices order, as in the picker).
        // Index 0 must also be exported: without it Metal falls back to the system
        // default, which on multi-GPU Macs may be a different card than picked.
        let devices = MTLCopyAllDevices()
        if split {
            // Two Metal slots: 0 = diffusion GPU, 1 = encoder/VAE GPU. The list
            // replaces DEVICE_INDEX (which would offset both slots).
            env["GGML_METAL_DEVICES"] = "2"
            env["GGML_METAL_DEVICE_LIST"] = "\(gpuIndex),\(auxGPUIndex)"
        } else if gpuIndex >= 0 && devices.count > 1 {
            env["GGML_METAL_DEVICE_INDEX"] = String(gpuIndex)
        }
        // Metal defaults eGPUs to shared buffers; force private VRAM like the LLM engine.
        let picked = split ? [gpuIndex, auxGPUIndex] : [gpuIndex]
        let anyExternal = picked.contains { $0 >= 0 && $0 < devices.count && devices[$0].location == .external }
            || (gpuIndex < 0 && MTLCreateSystemDefaultDevice()?.location == .external)
        if UserDefaults.standard.bool(forKey: SettingsKeys.forcePrivateBuffers) || anyExternal {
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
            Task { @MainActor in self?.consume(text, steps: steps) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.finish(status: proc.terminationStatus, output: out) }
        }

        fileLog.startSession()
        fileLog.append("$ sd-cli " + args.joined(separator: " ") + "\n\n")

        resultImage = nil
        resultURL = nil
        previewImage = nil
        progress = 0
        stepText = ""
        stage = .loading
        state = .generating
        startedAt = Date()
        firstStepAt = nil
        do {
            try p.run()
            process = p
            startPreviewWatch()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Poll the preview file while the run lasts. Reading it mid-write just yields
    /// nil, so a failed load is skipped rather than treated as an error.
    private func startPreviewWatch() {
        previewTimer?.invalidate()
        previewSeenAt = nil
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPreview() }
        }
    }

    private func refreshPreview() {
        guard isBusy, let url = previewURL,
              let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                                .contentModificationDate else { return }
        guard previewSeenAt != mod else { return }
        if let img = NSImage(contentsOf: url) {
            previewSeenAt = mod
            previewImage = img
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
        previewTimer?.invalidate()
        previewTimer = nil
        if let p = previewURL { try? FileManager.default.removeItem(at: p) }
        previewImage = nil
        defer { onFinish?() }
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
    /// Text encoder for custom models that ship the DiT alone (Z-Image, Flux 2,
    /// Qwen-Image): those need an LLM encoder, a full checkpoint does not.
    var customTextEncoderPath = ""
    /// The custom file is a bare diffusion model (--diffusion-model) instead of a
    /// full checkpoint (--model). The engine cannot tell them apart by extension.
    var customIsDiffusion = false
    var customCfg = 7.0
    var prompt = ""
    /// Ignored at CFG 1: the sampler never runs the unconditional branch there.
    var negativePrompt = ""
    var initImagePath = ""
    /// Inpainting mask for the init image: white repaints, black keeps.
    var maskPath = ""
    var strength = 0.6
    var aspect = ImageAspect.square.rawValue
    /// Free "W:H" ratio used only when `aspect` is `.custom` (e.g. "21:9").
    var customAspect = "21:9"
    var baseSize = 1024
    var gpuIndex = 0
    /// GPU that hosts the text encoder + VAE, freeing `gpuIndex` for the
    /// diffusion model; -1 = everything on the same GPU.
    var auxGPUIndex = -1
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
        customTextEncoderPath = (try? c.decode(String.self, forKey: .customTextEncoderPath)) ?? ""
        customIsDiffusion = (try? c.decode(Bool.self, forKey: .customIsDiffusion)) ?? false
        customCfg = (try? c.decode(Double.self, forKey: .customCfg)) ?? 7.0
        prompt = (try? c.decode(String.self, forKey: .prompt)) ?? ""
        negativePrompt = (try? c.decode(String.self, forKey: .negativePrompt)) ?? ""
        initImagePath = (try? c.decode(String.self, forKey: .initImagePath)) ?? ""
        maskPath = (try? c.decode(String.self, forKey: .maskPath)) ?? ""
        strength = (try? c.decode(Double.self, forKey: .strength)) ?? 0.6
        aspect = (try? c.decode(String.self, forKey: .aspect)) ?? ImageAspect.square.rawValue
        customAspect = (try? c.decode(String.self, forKey: .customAspect)) ?? "21:9"
        baseSize = (try? c.decode(Int.self, forKey: .baseSize)) ?? 1024
        gpuIndex = (try? c.decode(Int.self, forKey: .gpuIndex)) ?? 0
        auxGPUIndex = (try? c.decode(Int.self, forKey: .auxGPUIndex)) ?? -1
        steps = (try? c.decode(Int.self, forKey: .steps)) ?? 8
        seed = (try? c.decode(Int.self, forKey: .seed)) ?? -1
        format = (try? c.decode(String.self, forKey: .format)) ?? ImageFormat.png.rawValue
        offloadCPU = (try? c.decode(Bool.self, forKey: .offloadCPU)) ?? false
    }

    var isCustom: Bool { modelID == ImageGenCatalog.customID }

    /// Auxiliary GPU for the encoder/VAE split, or nil when the split is off,
    /// points at the main GPU, or the slot no longer exists.
    func auxGPU(gpuCount: Int) -> Int? {
        auxGPUIndex >= 0 && auxGPUIndex != gpuIndex && auxGPUIndex < gpuCount && gpuCount > 1
            ? auxGPUIndex : nil
    }

    var aspectValue: ImageAspect { ImageAspect(rawValue: aspect) ?? .square }
    var formatValue: ImageFormat { ImageFormat(rawValue: format) ?? .png }
    var dimensions: (Int, Int) {
        aspectValue == .custom
            ? ImageAspect.customDimensions(ratio: customAspect, base: baseSize)
            : aspectValue.dimensions(base: baseSize)
    }

    /// The model this instance runs: a catalog entry, the user's own files, or
    /// the best pick for the hardware.
    func resolvedModel(for hw: HardwareInfo) -> ImageGenModel {
        if isCustom {
            return ImageGenCatalog.custom(modelPath: customModelPath, vaePath: customVAEPath,
                                          textEncoderPath: customTextEncoderPath,
                                          isDiffusion: customIsDiffusion,
                                          steps: steps, cfg: customCfg)
        }
        return ImageGenCatalog.model(id: modelID)
            ?? ImageGenCatalog.recommended(for: hw)
            ?? ImageGenCatalog.zImageTurbo
    }
}

/// A prompt (with its own seed) waiting for the next free instance to render it.
struct QueuedPrompt: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var seed: Int = -1
    /// Instance this must run on, by config id; nil = any free instance. If the
    /// target instance is later removed, the scheduler treats it as untargeted.
    var targetInstanceID: UUID? = nil
    /// img2img source for this prompt only; nil = the instance's own init image.
    var initImagePath: String? = nil
}

/// A finished image kept in the session gallery, with the inputs that made it.
struct GeneratedImage: Identifiable {
    let id = UUID()
    let url: URL
    let image: NSImage
    let prompt: String
    let seed: Int
    let width: Int
    let height: Int
    let duration: Int
    /// "index · model" of the instance that rendered it; nil if it was removed
    /// from the pool before this result was recorded.
    let instanceLabel: String?
}

/// Owns the generation instances and one generator per slot; the sidebar
/// (controls) and the canvas (tiles) share it so both see the same state.
/// There is always at least one instance.
@MainActor
final class ImageGenPool: ObservableObject {
    @Published var configs: [ImageInstanceConfig] { didSet { save() } }
    /// Pending prompts; the scheduler feeds them to idle instances.
    @Published var queue: [QueuedPrompt] = []
    /// While true, finished instances pull the next queued prompt automatically.
    @Published var queueActive = false
    /// Completed results this session (newest first), shown in the Queue feed.
    @Published var gallery: [GeneratedImage] = []
    /// Set by the view so the scheduler can launch runs (generate() needs it).
    weak var modelStore: ModelStore?
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
        c.customTextEncoderPath = d.string(forKey: SettingsKeys.imagenCustomTextEncoder) ?? ""
        c.customIsDiffusion = d.bool(forKey: SettingsKeys.imagenCustomIsDiffusion)
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
        g.onFinish = { [weak self, weak g] in
            guard let self, let g else { return }
            self.recordResult(from: g, instanceID: id)
            self.pump()
        }
        generators[id] = g
        forwards[id] = g.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return g
    }

    /// "index · model" label matching the accordion title, for the queue target
    /// picker and the feed badges. Nil if the instance no longer exists.
    func instanceLabel(for id: UUID) -> String? {
        guard let idx = configs.firstIndex(where: { $0.id == id }) else { return nil }
        return "\(idx + 1) · \(configs[idx].resolvedModel(for: hardware).name)"
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
        let candidates = hardware.gpus.filter { !$0.isIntegrated }.map(\.index)
        if let free = (candidates.isEmpty ? Array(0 ..< max(hardware.gpus.count, 1)) : candidates)
            .first(where: { !used.contains($0) }) {
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

    /// Same inheritance as `effectivePrompt`, for the negative prompt.
    func effectiveNegativePrompt(for c: ImageInstanceConfig) -> String {
        let own = c.negativePrompt.trimmingCharacters(in: .whitespaces)
        if !own.isEmpty || c.id == configs.first?.id { return own }
        return (configs.first?.negativePrompt ?? "").trimmingCharacters(in: .whitespaces)
    }

    func remove(_ id: UUID) {
        guard configs.count > 1 else { return }
        generator(for: id).cancel()
        configs.removeAll { $0.id == id }
        generators[id] = nil
        forwards[id] = nil
    }

    func cancelAll() {
        queueActive = false
        for c in configs { generator(for: c.id).cancel() }
    }

    // MARK: prompt queue

    func enqueue(_ text: String, seed: Int = -1, targetInstanceID: UUID? = nil, initImagePath: String? = nil) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let img = initImagePath?.isEmpty == false ? initImagePath : nil
        queue.append(QueuedPrompt(text: t, seed: seed, targetInstanceID: targetInstanceID, initImagePath: img))
        if queueActive { pump() }
    }

    func removeFromQueue(_ id: UUID) { queue.removeAll { $0.id == id } }

    func startQueue() { queueActive = true; pump() }
    func stopQueue() { queueActive = false }   // in-flight runs finish; nothing new starts

    /// Append a generator's finished result to the session gallery (newest first),
    /// so every render stays visible even as instances move on to the next prompt.
    private func recordResult(from gen: ImageGenerator, instanceID: UUID) {
        guard let url = gen.resultURL, let img = gen.resultImage, gallery.first?.url != url else { return }
        gallery.insert(GeneratedImage(url: url, image: img, prompt: gen.lastPrompt, seed: gen.lastSeed,
                                      width: gen.lastWidth, height: gen.lastHeight, duration: gen.lastDuration,
                                      instanceLabel: instanceLabel(for: instanceID)), at: 0)
        if gallery.count > 60 { gallery.removeLast() }
    }

    /// True when `job` may run on `c`: untargeted, targeted at `c`, or its target
    /// was removed from the pool (falls back to "any free instance").
    nonisolated static func runnable(_ job: QueuedPrompt, on c: ImageInstanceConfig, existingIDs: Set<UUID>) -> Bool {
        guard let target = job.targetInstanceID else { return true }
        return target == c.id || !existingIDs.contains(target)
    }

    /// Assigns queued prompts to idle instances, at most one run per GPU (two
    /// Metal contexts on one AMD GPU can hang it). Each free instance takes its
    /// first *runnable* item, so a targeted prompt never blocks untargeted ones.
    func pump() {
        guard queueActive, let models = modelStore else { return }
        let gpuCount = hardware.gpus.count
        // A split instance occupies its encoder/VAE GPU too.
        var busyGPUs = Set<Int>()
        for c in configs where generator(for: c.id).isBusy {
            busyGPUs.insert(c.gpuIndex)
            if let aux = c.auxGPU(gpuCount: gpuCount) { busyGPUs.insert(aux) }
        }
        let existingIDs = Set(configs.map(\.id))
        for c in configs {
            guard !queue.isEmpty else { break }
            let gen = generator(for: c.id)
            let aux = c.auxGPU(gpuCount: gpuCount)
            guard !gen.isBusy, !busyGPUs.contains(c.gpuIndex),
                  aux.map({ !busyGPUs.contains($0) }) ?? true else { continue }
            guard let idx = queue.firstIndex(where: { Self.runnable($0, on: c, existingIDs: existingIDs) }) else { continue }
            let job = queue.remove(at: idx)
            busyGPUs.insert(c.gpuIndex)
            if let aux { busyGPUs.insert(aux) }
            let (w, h) = c.dimensions
            gen.generate(model: c.resolvedModel(for: hardware), models: models, prompt: job.text,
                         negativePrompt: effectiveNegativePrompt(for: c),
                         width: w, height: h, steps: c.steps, seed: job.seed, format: c.formatValue,
                         offloadToCPU: c.offloadCPU, gpuIndex: c.gpuIndex, auxGPUIndex: aux ?? -1,
                         initImagePath: job.initImagePath ?? c.initImagePath,
                         maskPath: c.maskPath, strength: c.strength)
        }
        if queue.isEmpty && !anyBusy { queueActive = false }
    }

    /// Deletes generated outputs (`toshllm_*`) from the imagen folder, when the
    /// user opts in. Upscales of those files are kept: they are the version the
    /// user asked to produce, not accumulated output.
    nonisolated static func cleanupOutputsIfEnabled() {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.imagenCleanupOnClose) else { return }
        let dir = ServerSettings.modelsDirectory.appendingPathComponent("imagen", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files {
            let name = f.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("toshllm_"), !name.contains("-x2"), !name.contains("-x4") else { continue }
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// Where LoRA files live: an `imagen/lora` folder next to the image models. Returns nil when
    /// it does not exist, so nothing is passed to the engine until the user creates it.
    nonisolated static func loraDirectory() -> URL? {
        let dir = ServerSettings.modelsDirectory
            .appendingPathComponent("imagen", isDirectory: true)
            .appendingPathComponent("lora", isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    nonisolated static func loraFiles(in dir: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["safetensors", "ckpt", "pt"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(configs),
                                  forKey: SettingsKeys.imagenInstances)
    }
}

/// ESRGAN upscaling of an already generated image. Separate from ImageGenerator:
/// it reuses the finished PNG as input, so it never re-runs the diffusion model.
/// One finished upscale. Only paths: keeping every pair decoded in memory would
/// cost hundreds of MB on a batch.
struct UpscaleResult: Identifiable, Equatable {
    let id = UUID()
    let source: URL
    let output: URL
}

@MainActor
final class ImageUpscaler: ObservableObject {
    enum State: Equatable { case idle, running, done, failed(String) }

    @Published var state: State = .idle
    @Published var resultImage: NSImage?
    @Published var resultURL: URL?
    /// Kept so the canvas can show a before/after and the sidebar the file name.
    @Published var sourceImage: NSImage?
    @Published var sourceURL: URL?
    /// Tile progress parsed from the engine, 0...1.
    @Published var progress: Double = 0
    /// Position in the batch, 1-based; total is 1 for a single file.
    @Published var index = 0
    @Published var total = 0
    /// Picked but not started: choosing a file must not launch a GPU run.
    @Published var queued: [URL] = []
    /// Everything finished this session, so a batch does not hide its own results.
    @Published var done: [UpscaleResult] = []
    @Published var selected: UpscaleResult.ID?

    private var pending: [URL] = []
    private var flavor: Flavor = .photo
    private var customPath = ""
    private var scale: Scale = .x4
    private var models: ModelStore?
    private var gpuIndex = -1
    private var startedAt: Date?

    var elapsed: Int { startedAt.map { Int(-$0.timeIntervalSinceNow) } ?? 0 }

    /// Both are ESRGAN-architecture and load in sd-cli; they are specialists, not
    /// ranks. Measured on the same crop: x4plus keeps gradients smooth, UltraSharp
    /// adds contrast and micro-detail, which flatters generated art and invents
    /// texture on a real photo.
    /// sd.cpp only loads plain 4x RRDBNet: RealESRGAN x2plus uses pixel-unshuffle
    /// (12-channel input) and is rejected, and the DAT models that top the 2026
    /// rankings are a different architecture entirely. So 4x native, 2x by
    /// downsampling the 4x result, which also beats a native 2x in practice.
    enum Scale: String, CaseIterable, Identifiable {
        case x2, x4
        var id: String { rawValue }
        var factor: Int { self == .x2 ? 2 : 4 }
        var label: String { self == .x2 ? "×2" : "×4" }
    }

    enum Flavor: String, CaseIterable, Identifiable {
        case photo, art, custom
        var id: String { rawValue }

        func component(customPath: String = "") -> ImageGenComponent? {
            switch self {
            case .photo:
                return ImageGenComponent(kind: .checkpoint,
                    urlString: "https://github.com/Phhofm/models/releases/download/4xNomosWebPhoto_esrgan/4xNomosWebPhoto_esrgan.pth",
                    fileName: "4xNomosWebPhoto_esrgan.pth", sizeGB: 0.032)
            case .art:
                return ImageGenComponent(kind: .checkpoint,
                    urlString: "https://huggingface.co/uwg/upscaler/resolve/main/ESRGAN/4x-UltraSharp.pth",
                    fileName: "4x-UltraSharp.pth", sizeGB: 0.064)
            case .custom:
                guard !customPath.isEmpty else { return nil }
                return ImageGenComponent(kind: .checkpoint, urlString: "",
                                         fileName: customPath, sizeGB: 0)
            }
        }

        func label(_ spanish: Bool) -> String {
            switch self {
            case .photo:  return spanish ? "Fotos" : "Photos"
            case .art:    return spanish ? "Generada" : "Generated"
            case .custom: return spanish ? "Otro" : "Custom"
            }
        }

        func detail(_ spanish: Bool) -> String {
            switch self {
            case .photo:  return spanish ? "4xNomosWebPhoto. Entrenado con ruido, desenfoque y recompresión reales."
                                         : "4xNomosWebPhoto. Trained on real noise, lens blur and re-compression."
            case .art:    return spanish ? "4x-UltraSharp. Más contraste y detalle fino; luce en arte generado."
                                         : "4x-UltraSharp. More contrast and fine detail; shines on generated art."
            case .custom: return spanish ? "Tu propio modelo ESRGAN ×4 (.pth o .safetensors)."
                                         : "Your own 4x ESRGAN model (.pth or .safetensors)."
            }
        }
    }

    static func installed(_ flavor: Flavor, customPath: String, in models: ModelStore) -> Bool {
        guard let c = flavor.component(customPath: customPath) else { return false }
        return FileManager.default.fileExists(atPath: c.path(in: models.imagenDirectory).path)
    }

    var isBusy: Bool { state == .running }

    private var process: Process?

    /// Upscales the queued files one at a time: two ESRGAN runs at once would
    /// contend for the same VRAM the tiles already stretch.
    func upscale(sources: [URL], flavor: Flavor, customPath: String = "", scale: Scale = .x4,
                 models: ModelStore, gpuIndex: Int) {
        guard !isBusy, !sources.isEmpty else { return }
        pending = sources
        queued = []
        self.customPath = customPath
        self.scale = scale
        self.flavor = flavor
        self.models = models
        self.gpuIndex = gpuIndex
        index = 0
        total = sources.count
        startedAt = Date()
        next()
    }

    private func next() {
        guard let models, !pending.isEmpty else {
            if total > 0 { state = .done }
            return
        }
        let source = pending.removeFirst()
        index += 1
        run(source: source, flavor: flavor, models: models, gpuIndex: gpuIndex)
    }

    /// Next to the original, so upscaling a photo doesn't drop the result among
    /// the model weights. Falls back to the imagen folder when that is read-only.
    private func outputURL(for source: URL, fallback: URL) -> URL {
        let folder = source.deletingLastPathComponent()
        let dir = FileManager.default.isWritableFile(atPath: folder.path) ? folder : fallback
        let base = source.deletingPathExtension().lastPathComponent + "-x\(scale.factor)"
        var candidate = dir.appendingPathComponent(base + ".png")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(n).png")
            n += 1
        }
        return candidate
    }

    private func run(source: URL, flavor: Flavor, models: ModelStore, gpuIndex: Int) {
        let dir = models.imagenDirectory
        let out = outputURL(for: source, fallback: dir)

        guard let component = flavor.component(customPath: customPath) else {
            state = .failed("no model"); return
        }
        let args = ["-M", "upscale",
                    "--upscale-model", component.path(in: dir).path,
                    // tiled so a single Metal dispatch stays under the GPU watchdog
                    "--upscale-tile-size", "128",
                    "-i", source.path,
                    "-o", out.path]

        var env = ProcessInfo.processInfo.environment
        let devices = MTLCopyAllDevices()
        if gpuIndex >= 0 && devices.count > 1 {
            env["GGML_METAL_DEVICE_INDEX"] = String(gpuIndex)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: ImageGenerator.binary)
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
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                guard proc.terminationStatus == 0, let img = NSImage(contentsOf: out) else {
                    if proc.terminationStatus == 15 || proc.terminationStatus == 2 {
                        self.state = .failed("")
                    } else {
                        self.state = .failed("exit \(proc.terminationStatus)")
                    }
                    self.pending = []
                    return
                }
                if self.scale == .x2 { Self.halve(out) }
                self.resultImage = NSImage(contentsOf: out) ?? img
                self.resultURL = out
                self.progress = 1
                if let src = self.sourceURL {
                    let entry = UpscaleResult(source: src, output: out)
                    self.done.append(entry)
                    self.selected = entry.id
                }
                self.next()
            }
        }
        state = .running
        progress = 0
        resultImage = nil
        resultURL = nil
        sourceURL = source
        sourceImage = NSImage(contentsOf: source)
        do {
            try p.run()
            process = p
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        pending = []
        process?.terminate()
    }

    /// x2 = the 4x result resampled to half. Done with ImageIO so the downsample
    /// is a proper Lanczos pass, not a display-time scale.
    nonisolated static func halve(_ url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int else { return }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, w / 2),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Same tile-progress line the generator prints: `N/M ... s/it`.
    private func consume(_ text: String) {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard line.contains("s/it"),
                  let r = line.range(of: #"(\d+)/(\d+)"#, options: .regularExpression) else { continue }
            let parts = line[r].split(separator: "/")
            if parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), b > 0 {
                progress = Double(a) / Double(b)
            }
        }
    }
}
