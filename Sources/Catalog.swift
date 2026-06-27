import Foundation

struct CatalogModel: Identifiable {
    let name: String
    let detailES: String
    let detailEN: String
    let urlString: String
    let spec: ModelSpec
    var isVision: Bool = false   // multimodal: reads images (ships an mmproj projector)

    var id: String { name }
    var fileName: String { URL(string: urlString)!.lastPathComponent }
    var isMoE: Bool { spec.isMoE }
    var isCoder: Bool { name.localizedCaseInsensitiveContains("coder") }

    func detail(_ spanish: Bool) -> String { spanish ? detailES : detailEN }
}

enum Catalog {
    static let models: [CatalogModel] = [
        CatalogModel(
            name: "Qwen3-4B",
            detailES: "Ultrarrápido, ideal para tareas simples y borradores",
            detailEN: "Blazing fast, great for simple tasks and drafts",
            urlString: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf",
            spec: ModelSpec(fileGB: 2.4, paramsB: 4.0, layers: 36, isMoE: false)),
        CatalogModel(
            name: "Gemma-3-4B Vision",
            detailES: "Pareja de visión oficial de llama.cpp, compacta y multilingüe",
            detailEN: "Official llama.cpp vision pair, compact and multilingual",
            urlString: "https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf",
            spec: ModelSpec(fileGB: 2.3, paramsB: 4.0, layers: 34, isMoE: false),
            isVision: true),
        CatalogModel(
            name: "Qwen3-VL-2B Vision",
            detailES: "Visión diminuta y veloz (ggml-org): describe y lee texto en imágenes. Puede ser impredecible en respuestas largas",
            detailEN: "Tiny, fast vision model (ggml-org): captions and reads text in images. Can be unpredictable on long replies",
            urlString: "https://huggingface.co/ggml-org/Qwen3-VL-2B-Instruct-GGUF/resolve/main/Qwen3-VL-2B-Instruct-Q8_0.gguf",
            spec: ModelSpec(fileGB: 1.83, paramsB: 2.0, layers: 28, isMoE: false),
            isVision: true),
        CatalogModel(
            name: "Llama-3.1-8B",
            detailES: "Clásico de Meta: sólido y muy compatible",
            detailEN: "Meta's classic: solid and widely compatible",
            urlString: "https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf",
            spec: ModelSpec(fileGB: 4.9, paramsB: 8.0, layers: 32, isMoE: false)),
        CatalogModel(
            name: "Qwen3-8B",
            detailES: "Equilibrio velocidad/calidad, con modo razonamiento",
            detailEN: "Speed/quality balance, with thinking mode",
            urlString: "https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q4_K_M.gguf",
            spec: ModelSpec(fileGB: 4.7, paramsB: 8.2, layers: 36, isMoE: false)),
        CatalogModel(
            name: "GLM-4-9B",
            detailES: "9B potente de Zhipu: gran calidad para su tamaño",
            detailEN: "Zhipu's strong 9B: great quality for its size",
            urlString: "https://huggingface.co/unsloth/GLM-4-9B-0414-GGUF/resolve/main/GLM-4-9B-0414-Q4_K_M.gguf",
            spec: ModelSpec(fileGB: 6.2, paramsB: 9.4, layers: 40, isMoE: false)),
        CatalogModel(
            name: "Gemma-4-12B",
            detailES: "Gemma 4 de Google: multimodal y muy bueno en español",
            detailEN: "Google's Gemma 4: multimodal, strong multilingual",
            urlString: "https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-Q4_K_M.gguf",
            spec: ModelSpec(fileGB: 7.1, paramsB: 12.0, layers: 48, isMoE: false), isVision: true),
        CatalogModel(
            name: "Pixtral-12B Vision",
            detailES: "Visión de Mistral (ggml-org): fuerte en lectura de imágenes y OCR",
            detailEN: "Mistral's vision model (ggml-org): strong image understanding and OCR",
            urlString: "https://huggingface.co/ggml-org/pixtral-12b-GGUF/resolve/main/pixtral-12b-Q4_K_M.gguf",
            spec: ModelSpec(fileGB: 7.48, paramsB: 12.0, layers: 40, isMoE: false), isVision: true),
        CatalogModel(
            name: "Qwen3-14B",
            detailES: "Denso grande; cabe justo en 12 GB de VRAM",
            detailEN: "Large dense model; barely fits in 12 GB VRAM",
            urlString: "https://huggingface.co/Qwen/Qwen3-14B-GGUF/resolve/main/Qwen3-14B-Q4_K_M.gguf",
            spec: ModelSpec(fileGB: 8.4, paramsB: 14.8, layers: 40, isMoE: false)),
        CatalogModel(
            name: "GPT-OSS-20B",
            detailES: "MoE de OpenAI (3.6B activos), razonamiento sólido",
            detailEN: "OpenAI's MoE (3.6B active), solid reasoning",
            urlString: "https://huggingface.co/ggml-org/gpt-oss-20b-GGUF/resolve/main/gpt-oss-20b-mxfp4.gguf",
            spec: ModelSpec(fileGB: 12.1, paramsB: 20.9, layers: 24, isMoE: true)),
        CatalogModel(
            name: "Gemma-4-26B-A4B",
            detailES: "MoE de Gemma 4 (4B activos): calidad alta en híbrido",
            detailEN: "Gemma 4 MoE (4B active): high quality in hybrid",
            urlString: "https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf",
            spec: ModelSpec(fileGB: 17.0, paramsB: 26.0, layers: 48, isMoE: true), isVision: true),
        CatalogModel(
            name: "Qwen3-30B-A3B Instruct",
            detailES: "MoE (3B activos): la mejor calidad para este equipo",
            detailEN: "MoE (3B active): best quality for this machine",
            urlString: "https://huggingface.co/unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF/resolve/main/Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf",
            spec: ModelSpec(fileGB: 17.3, paramsB: 30.5, layers: 48, isMoE: true)),
        CatalogModel(
            name: "Qwen3.6-35B-A3B",
            detailES: "La nueva generación MoE de Qwen — calidad de frontera local",
            detailEN: "Qwen's newest MoE generation — frontier-class local quality",
            urlString: "https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-Q4_K_S.gguf",
            spec: ModelSpec(fileGB: 19.5, paramsB: 35.4, layers: 40, isMoE: true)),
        CatalogModel(
            name: "Qwen3-Coder-30B-A3B",
            detailES: "MoE especializado en programación y agentes",
            detailEN: "MoE specialized in coding and agentic tasks",
            urlString: "https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf",
            spec: ModelSpec(fileGB: 17.3, paramsB: 30.5, layers: 48, isMoE: true)),
    ]

    /// Spec for a local file: reuses catalog metadata when the filename matches.
    static func spec(forLocal model: LocalModel) -> ModelSpec {
        if let match = models.first(where: { $0.fileName == model.name }) { return match.spec }
        return ModelSpec.estimated(fileBytes: model.sizeBytes, isMoE: model.isMoE)
    }

    /// A recommended model tailored to a use case.
    struct Recommendation: Identifiable {
        enum Role { case fast, balanced, quality, coding }
        let role: Role
        let model: CatalogModel
        let est: MemoryEstimate
        var id: String { model.id }
    }

    /// Up to four distinct picks tailored to the user's machine.
    ///
    /// Grounded in the AMD GPUs these machines actually run (Metal-on-AMD) —
    /// both official Intel Macs and Hackintoshes (the core audience; modern
    /// RDNA2 cards run via the NootRX patch). Usable VRAM falls into tiers, so
    /// the picks aren't blind:
    ///   2 GB     — Radeon Pro 450/455/555/560
    ///   4 GB     — RX 460/550/560/570, RX 5500 XT; Pro 555X/560X/5300/570X/575X, Vega 16/20
    ///   6 GB     — RX 5600 XT
    ///   8 GB     — RX 470/480/580/590, RX 5700(XT), RX 6600(XT), Vega 56/64; Pro 5500M/5600M/5700/580X/W5500X
    ///   10–12 GB — RX 6700/6700 XT (typical Hackintosh sweet spot)
    ///   16 GB    — Radeon VII, RX 6800(XT)/6900 XT; Pro 5700 XT/W5700X, Vega 64
    ///   32 GB    — Pro Vega II/W6800X/W6900X (Mac Pro 2019)
    /// The Estimator turns the *detected* VRAM/RAM into a FitLevel per model;
    /// the roles below select across that so every tier gets a sensible set.
    /// A tier with no fully-GPU model collapses gracefully (dedup drops repeats),
    /// e.g. a 4 GB card returns just the 4B; a 12 GB card returns 4B + a 8–9B
    /// daily driver + a large MoE + a coder.
    static func recommendations(for hw: HardwareInfo) -> [Recommendation] {
        let usable = models
            .map { ($0, Estimator.estimateCurrent(spec: $0.spec, hw: hw)) }
            .filter { $0.1.level >= .good }
        guard !usable.isEmpty else { return [] }

        let fullGPU = usable.filter { $0.1.level == .ideal }
        // The everyday driver: the largest 7–10B model that runs fully on the
        // GPU (the 8B/9B sweet spot). Falls back to the largest fully-GPU model
        // when the card is too small to hold one (e.g. 2–4 GB tiers).
        let daily = fullGPU.filter { $0.0.spec.paramsB <= 10 }

        let candidates: [(Recommendation.Role, (CatalogModel, MemoryEstimate)?)] = [
            // Fastest tokens/s: smallest fully-GPU model.
            (.fast,     fullGPU.min { $0.0.spec.paramsB < $1.0.spec.paramsB }),
            // Balanced everyday driver: best 8–9B (or largest fully-GPU model).
            (.balanced, (daily.isEmpty ? fullGPU : daily).max { $0.0.spec.paramsB < $1.0.spec.paramsB }),
            // Most capable that still runs well: largest dense or hybrid MoE.
            (.quality,  usable.max  { $0.0.spec.paramsB < $1.0.spec.paramsB }),
            // Best coding model that runs well.
            (.coding,   usable.filter { $0.0.name.localizedCaseInsensitiveContains("coder") }
                              .max { $0.0.spec.paramsB < $1.0.spec.paramsB }),
        ]

        var picks: [Recommendation] = []
        for (role, pair) in candidates {
            guard let (model, est) = pair,
                  !picks.contains(where: { $0.model.id == model.id }) else { continue }
            picks.append(Recommendation(role: role, model: model, est: est))
        }
        return picks
    }
}
