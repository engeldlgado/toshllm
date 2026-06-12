import Foundation
import Metal

// MARK: - Hardware detection

struct HardwareInfo {
    let cpuBrand: String
    let physicalCores: Int
    let logicalCores: Int
    let ramGB: Double
    let arch: String
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
            gpus: ServerController.availableGPUs()
        )
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
    /// Estimates required VRAM/RAM and suggested configuration for a model on this machine.
    static func estimate(spec: ModelSpec, hw: HardwareInfo, ctx: Int = 16384) -> MemoryEstimate {
        let vramBudget = hw.vramGB - 1.0          // driver reserve
        let kvGB = kvCache(spec: spec, ctx: ctx)
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
