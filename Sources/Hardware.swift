import Foundation
import Metal

// MARK: - Hardware detection

struct HardwareInfo {
    let cpuBrand: String
    let physicalCores: Int
    let logicalCores: Int
    let ramGB: Double
    let arch: String
    let model: String        // e.g. "Mac Pro (MacPro7,1)"
    let osVersion: String    // e.g. "macOS 15.5 Sequoia"
    let gpus: [GPUDevice]

    var bestGPU: GPUDevice? { gpus.max(by: { $0.vramMB < $1.vramMB }) }
    var vramGB: Double { Double(bestGPU?.vramMB ?? 0) / 1024 }
    /// Total VRAM across the split-eligible GPUs (iGPUs are never auto-selected).
    /// Only meaningful for a multi-GPU layer split.
    var combinedVramGB: Double {
        let eligible = gpus.filter { !$0.isIntegrated }
        return Double((eligible.isEmpty ? gpus : eligible).reduce(0) { $0 + $1.vramMB }) / 1024
    }

    static func detect() -> HardwareInfo {
        func sysctlString(_ name: String) -> String {
            var size = 0
            sysctlbyname(name, nil, &size, nil, 0)
            guard size > 0 else { return "" }
            var buf = [CChar](repeating: 0, count: size)
            sysctlbyname(name, &buf, &size, nil, 0)
            return String(cString: buf)
        }
        func sysctlInt(_ name: String) -> Int64 {
            var value: Int64 = 0
            var size = MemoryLayout<Int64>.size
            sysctlbyname(name, &value, &size, nil, 0)
            return value
        }

        return HardwareInfo(
            cpuBrand: sysctlString("machdep.cpu.brand_string"),
            physicalCores: Int(sysctlInt("hw.physicalcpu")),
            logicalCores: Int(sysctlInt("hw.ncpu")),
            ramGB: Double(sysctlInt("hw.memsize")) / 1_073_741_824,
            arch: sysctlString("hw.machine").isEmpty
                ? (sysctlInt("hw.optional.arm64") == 1 ? "arm64" : "x86_64")
                : sysctlString("hw.machine"),
            model: modelName(sysctlString("hw.model")),
            osVersion: osVersionName(),
            gpus: ServerController.availableGPUs()
        )
    }

    /// A friendly Mac model from the `hw.model` SMBIOS identifier (e.g. MacPro7,1).
    private static func modelName(_ id: String) -> String {
        guard !id.isEmpty else { return "" }
        let lower = id.lowercased()
        let pairs: [(String, String)] = [
            ("macpro", "Mac Pro"), ("macmini", "Mac mini"), ("imacpro", "iMac Pro"),
            ("imac", "iMac"), ("macbookpro", "MacBook Pro"), ("macbookair", "MacBook Air"),
            ("macbook", "MacBook"), ("mac", "Mac"),
        ]
        guard let friendly = pairs.first(where: { lower.hasPrefix($0.0) })?.1 else { return id }
        return "\(friendly) (\(id))"
    }

    /// e.g. "macOS 15.5 Sequoia".
    private static func osVersionName() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let names = [11: "Big Sur", 12: "Monterey", 13: "Ventura", 14: "Sonoma",
                     15: "Sequoia", 26: "Tahoe"]
        let num = v.patchVersion == 0
            ? "\(v.majorVersion).\(v.minorVersion)"
            : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        if let name = names[v.majorVersion] { return "macOS \(num) \(name)" }
        return "macOS \(num)"
    }
}

// MARK: - Per-model memory estimation

struct ModelSpec {
    let fileGB: Double
    let paramsB: Double
    let layers: Int
    let isMoE: Bool
    /// MoE active parameters (billions); 0 = derive from total.
    var activeParamsB: Double = 0

    /// For local models without catalog metadata
    static func estimated(fileBytes: Int64, isMoE: Bool, name: String = "") -> ModelSpec {
        let gb = Double(fileBytes) / 1_073_741_824
        // Q4 is roughly 0.57 GB per billion parameters
        let params = gb / 0.57
        let active = isMoE ? (ModelName.activeParamsB(name) ?? params * 0.11) : 0
        return ModelSpec(fileGB: gb, paramsB: params, layers: isMoE ? 48 : 40,
                         isMoE: isMoE, activeParamsB: active)
    }
}

enum FitLevel: Int, Comparable {
    case ideal = 3      // fully on GPU
    case good = 2       // hybrid GPU+CPU MoE, good performance
    case slow = 1       // heavily CPU-bound, slow
    case no = 0         // does not fit

    static func < (a: FitLevel, b: FitLevel) -> Bool { a.rawValue < b.rawValue }
}

struct MemoryEstimate {
    let vramGB: Double
    let ramGB: Double
    let suggestedNcmoe: Int
    let level: FitLevel
    let expectedSpeed: String   // estimated t/s range
}

enum Estimator {
    /// ncmoe to apply when a model is picked: dense → 0; MoE → the value the
    /// user last set for that file, or the hardware recommendation.
    static func ncmoeForSelection(path: String, models: [LocalModel]) -> Int {
        guard !path.isEmpty, ServerSettings.modelIsMoE(at: path) else { return 0 }
        if let saved = ServerSettings.recalledNcmoe(forModel: path) { return saved }
        guard let lm = models.first(where: { $0.url.path == path }) else { return 0 }
        return estimateCurrent(spec: Catalog.spec(forLocal: lm), hw: hardware).suggestedNcmoe
    }

    /// Estimate using the user's current context size and KV quantization.
    static func estimateCurrent(spec: ModelSpec, hw: HardwareInfo) -> MemoryEstimate {
        let d = UserDefaults.standard
        let ctx = d.object(forKey: SettingsKeys.ctx) == nil ? 16384 : d.integer(forKey: SettingsKeys.ctx)
        let scale = (kvTypeScale(d.string(forKey: SettingsKeys.cacheTypeK) ?? "f16")
                   + kvTypeScale(d.string(forKey: SettingsKeys.cacheTypeV) ?? "f16")) / 2
        return estimate(spec: spec, hw: hw, ctx: ctx, kvScale: scale,
                        multiGPU: d.bool(forKey: SettingsKeys.multiGPU))
    }

    /// KV cache size of a quantization type relative to f16.
    static func kvTypeScale(_ type: String) -> Double {
        switch type {
        case "f16": return 1.0
        case "q8_0": return 0.53
        case "q5_1": return 0.38
        case "q5_0": return 0.36
        case "q4_1": return 0.32
        default: return 0.30      // q4_0, iq4_nl and turbo* sub-byte types
        }
    }

    /// Estimates required VRAM/RAM and suggested configuration for a model on this machine.
    static func estimate(spec: ModelSpec, hw: HardwareInfo, ctx: Int = 16384, kvScale: Double = 1.0,
                         multiGPU: Bool = false) -> MemoryEstimate {
        // A layer split is sequential (pipeline): combined VRAM raises capacity,
        // not per-token speed. Use summed VRAM (driver reserve per device) when
        // the user enabled the split and there are 2+ GPUs; otherwise one card.
        let splitGPUs = hw.gpus.filter { !$0.isIntegrated }.count
        let splitting = multiGPU && splitGPUs >= 2
        let vramBudget = (splitting ? hw.combinedVramGB : hw.vramGB) - Double(splitting ? splitGPUs : 1)
        let kvGB = kvCache(spec: spec, ctx: ctx) * kvScale
        let computeGB = 0.9 + spec.paramsB * 0.012

        if !spec.isMoE {
            let need = spec.fileGB * 1.03 + kvGB + computeGB
            if need <= vramBudget {
                // Decode is bandwidth-bound: t/s ≈ VRAM bandwidth / bytes read per
                // token, and a full-GPU dense model reads its whole file each token.
                let tg = clampSpeed(bwVRAM * denseEff / max(0.5, spec.fileGB))
                return MemoryEstimate(vramGB: need, ramGB: 0.7, suggestedNcmoe: 0,
                                      level: .ideal, expectedSpeed: speedRange(tg))
            }
            // Dense model that does not fit: partial CPU layers are very slow
            if spec.fileGB * 0.5 <= vramBudget && spec.fileGB < hw.ramGB * 0.6 {
                return MemoryEstimate(vramGB: vramBudget, ramGB: spec.fileGB - vramBudget + 2,
                                      suggestedNcmoe: 0, level: .slow, expectedSpeed: "~3-6 t/s")
            }
            return MemoryEstimate(vramGB: need, ramGB: 0, suggestedNcmoe: 0, level: .no, expectedSpeed: "—")
        }

        // MoE: attention and shared layers in VRAM, experts split between VRAM and RAM
        let overheadGB = 1.4 + kvGB + computeGB     // attention + KV + compute
        let expertsGB = max(0, spec.fileGB - 1.3)
        let vramForExperts = vramBudget - overheadGB
        let gpuExpertsGB = min(expertsGB, max(0, vramForExperts))
        let cpuExpertsGB = expertsGB - gpuExpertsGB
        let ramNeed = cpuExpertsGB + 1.0

        if ramNeed > hw.ramGB * 0.72 {
            return MemoryEstimate(vramGB: vramBudget, ramGB: ramNeed, suggestedNcmoe: spec.layers,
                                  level: .no, expectedSpeed: "—")
        }

        let ncmoe = expertsGB > 0
            ? min(spec.layers, Int((Double(spec.layers) * (cpuExpertsGB / expertsGB)).rounded(.up)))
            : 0

        // Only the active experts are read per token; a fraction sits in RAM
        // (slow) and the rest in VRAM, so more offload means fewer t/s. The quant
        // shows up as bytes-per-param = fileGB / total params.
        let active = spec.activeParamsB > 0 ? spec.activeParamsB : spec.paramsB * 0.11
        let bytesPerParam = spec.fileGB / max(1, spec.paramsB)
        let activeGB = active * bytesPerParam
        let fracRAM = min(1, Double(ncmoe) / Double(max(1, spec.layers)))
        let perToken = activeGB * ((1 - fracRAM) / bwVRAM + fracRAM / bwRAM)
        let tg = clampSpeed(moeEff / max(0.0001, perToken))

        if ncmoe == 0 {
            return MemoryEstimate(vramGB: spec.fileGB + overheadGB, ramGB: 0.7, suggestedNcmoe: 0,
                                  level: .ideal, expectedSpeed: speedRange(tg))
        }
        let level: FitLevel = cpuExpertsGB / expertsGB > 0.85 ? .slow : .good
        return MemoryEstimate(vramGB: overheadGB + gpuExpertsGB, ramGB: ramNeed,
                              suggestedNcmoe: ncmoe, level: level, expectedSpeed: speedRange(tg))
    }

    // Decode-speed model constants, calibrated to measured truths (Qwen3-8B Q4
    // ≈ 58 tg full-GPU; Qwen3.6-35B-A3B ≈ 24.5 tg at ncmoe 24). GB/s.
    private static let bwVRAM = 380.0
    private static let bwRAM = 48.0
    private static let denseEff = 0.72
    private static let moeEff = 0.48

    private static func clampSpeed(_ tg: Double) -> Double { min(60, max(4, tg)) }

    /// "~lo-hi t/s" band; the estimate is deliberately approximate.
    private static func speedRange(_ tg: Double) -> String {
        "~\(Int((tg * 0.8).rounded()))-\(Int(tg.rounded())) t/s"
    }

    private static func kvCache(spec: ModelSpec, ctx: Int) -> Double {
        // GQA f16 heuristic: grows with model size and context length
        let perK = spec.paramsB >= 25 ? 0.10 : spec.paramsB >= 12 ? 0.08 : 0.05
        return perK * Double(ctx) / 1024
    }
}
