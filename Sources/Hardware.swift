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

    /// For local models without catalog metadata
    static func estimated(fileBytes: Int64, isMoE: Bool) -> ModelSpec {
        let gb = Double(fileBytes) / 1_073_741_824
        // Q4 is roughly 0.57 GB per billion parameters
        let params = gb / 0.57
        return ModelSpec(fileGB: gb, paramsB: params, layers: isMoE ? 48 : 40, isMoE: isMoE)
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
    /// Estimate using the user's current context size and KV quantization.
    static func estimateCurrent(spec: ModelSpec, hw: HardwareInfo) -> MemoryEstimate {
        let d = UserDefaults.standard
        let ctx = d.object(forKey: SettingsKeys.ctx) == nil ? 16384 : d.integer(forKey: SettingsKeys.ctx)
        let scale = (kvTypeScale(d.string(forKey: SettingsKeys.cacheTypeK) ?? "f16")
                   + kvTypeScale(d.string(forKey: SettingsKeys.cacheTypeV) ?? "f16")) / 2
        return estimate(spec: spec, hw: hw, ctx: ctx, kvScale: scale)
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
    static func estimate(spec: ModelSpec, hw: HardwareInfo, ctx: Int = 16384, kvScale: Double = 1.0) -> MemoryEstimate {
        let vramBudget = hw.vramGB - 1.0          // driver reserve
        let kvGB = kvCache(spec: spec, ctx: ctx) * kvScale
        let computeGB = 0.9 + spec.paramsB * 0.012

        if !spec.isMoE {
            let need = spec.fileGB * 1.03 + kvGB + computeGB
            if need <= vramBudget {
                let speed = max(8, 240 / spec.paramsB)
                return MemoryEstimate(vramGB: need, ramGB: 0.7, suggestedNcmoe: 0,
                                      level: .ideal,
                                      expectedSpeed: String(format: "~%.0f t/s", speed))
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
        if ncmoe == 0 {
            return MemoryEstimate(vramGB: spec.fileGB + overheadGB, ramGB: 0.7, suggestedNcmoe: 0,
                                  level: .ideal, expectedSpeed: "~40-60 t/s")
        }
        let level: FitLevel = cpuExpertsGB / expertsGB > 0.85 ? .slow : .good
        let speed = level == .good ? "~18-25 t/s" : "~8-12 t/s"
        return MemoryEstimate(vramGB: overheadGB + gpuExpertsGB, ramGB: ramNeed,
                              suggestedNcmoe: ncmoe, level: level, expectedSpeed: speed)
    }

    private static func kvCache(spec: ModelSpec, ctx: Int) -> Double {
        // GQA f16 heuristic: grows with model size and context length
        let perK = spec.paramsB >= 25 ? 0.10 : spec.paramsB >= 12 ? 0.08 : 0.05
        return perK * Double(ctx) / 1024
    }
}
