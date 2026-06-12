import Foundation

struct CatalogModel: Identifiable {
    let name: String
    let detailES: String
    let detailEN: String
    let urlString: String
    let spec: ModelSpec

    var id: String { name }
    var fileName: String { URL(string: urlString)!.lastPathComponent }

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
            name: "Qwen3-8B",
            detailES: "Equilibrio velocidad/calidad, con modo razonamiento",
            detailEN: "Speed/quality balance, with thinking mode",
            urlString: "https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/main/Qwen3-8B-Q4_K_M.gguf",
            spec: ModelSpec(fileGB: 4.7, paramsB: 8.2, layers: 36, isMoE: false)),
        CatalogModel(
            name: "Gemma-3-12B",
            detailES: "Multimodal de Google, muy bueno en español",
            detailEN: "Google's multimodal model, strong multilingual",
            urlString: "https://huggingface.co/ggml-org/gemma-3-12b-it-GGUF/resolve/main/gemma-3-12b-it-Q4_K_M.gguf",
            spec: ModelSpec(fileGB: 7.3, paramsB: 12.2, layers: 48, isMoE: false)),
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

    /// Best catalog model that runs well on this hardware.
    static func recommended(for hw: HardwareInfo) -> (CatalogModel, MemoryEstimate)? {
        models
            .map { ($0, Estimator.estimate(spec: $0.spec, hw: hw)) }
            .filter { $0.1.level >= .good }
            .max { a, b in
                a.0.spec.paramsB == b.0.spec.paramsB
                    ? a.1.level < b.1.level
                    : a.0.spec.paramsB < b.0.spec.paramsB
            }
    }
}
