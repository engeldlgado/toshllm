// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

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
    var gpus: [GPUDevice]

    var bestGPU: GPUDevice? { gpus.max(by: { $0.vramMB < $1.vramMB }) }
    var vramGB: Double { Double(bestGPU?.vramMB ?? 0) / 1024 }
    /// Total VRAM across the split-eligible GPUs (iGPUs are never auto-selected).
    /// Only meaningful for a multi-GPU layer split.
    var combinedVramGB: Double {
        Double(splitEligibleGPUs.reduce(0) { $0 + $1.vramMB }) / 1024
    }

    var splitEligibleGPUs: [GPUDevice] {
        let eligible = gpus.filter { !$0.isIntegrated }
        return eligible.isEmpty ? gpus : eligible
    }

    /// GPUs joined by an Infinity Fabric link, internal to a Duo or across a bridge.
    /// A card with no link reports group 0, so a group is the only evidence of one.
    var peerGroups: [[GPUDevice]] { Self.peerGroups(of: gpus) }

    static func peerGroups(of gpus: [GPUDevice]) -> [[GPUDevice]] {
        let members = Dictionary(grouping: gpus.filter { $0.peerGroupID != 0 }, by: \.peerGroupID)
        return GPUPeerTopology.groupIDs(gpus.map { ($0.index, $0.peerGroupID) })
            .compactMap { members[$0]?.sorted { $0.index < $1.index } }
    }

    /// One entry per GPU model present, with how many physical cards it took.
    static func modelGroups(of gpus: [GPUDevice]) -> [GPUModelGroup] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var vram: [String: Int] = [:]
        for gpu in gpus {
            if counts[gpu.name] == nil { order.append(gpu.name) }
            counts[gpu.name, default: 0] += 1
            vram[gpu.name] = gpu.vramGB
        }
        return order.map { name in
            let dies = GPUModelGroup.diesPerCard(name)
            let count = counts[name] ?? 1
            return GPUModelGroup(name: name, cards: (count + dies - 1) / dies,
                                 gpus: count, vramGB: vram[name] ?? 0)
        }
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
    /// Exact f16 KV bytes per token from the GGUF geometry; 0 = fall back to the heuristic.
    var kvBytesPerToken: Double = 0

    /// Reads the real KV geometry: multi-head models (llama-2, OLMo) cache eight times
    /// what the by-size heuristic assumes, enough to overflow VRAM and hang the driver.
    static func kvBytesPerToken(atPath path: String) -> Double {
        guard let md = GGUFMetadataCache.metadata(at: path) else { return 0 }
        func u(_ suffix: String) -> Int? { md.uint32(forSuffix: suffix).map(Int.init) }
        guard let layers = u("block_count"), layers > 0,
              let headsKV = u("attention.head_count_kv"), headsKV > 0 else { return 0 }
        let keyLen = u("attention.key_length") ?? {
            guard let embd = u("embedding_length"), let heads = u("attention.head_count"), heads > 0
            else { return nil }
            return embd / heads
        }()
        guard let keyLen, keyLen > 0 else { return 0 }
        let valueLen = u("attention.value_length") ?? keyLen
        // hybrid architectures put full attention on one layer in N; the rest are recurrent
        let interval = u("full_attention_interval") ?? 1
        let attnLayers = interval > 1 ? (layers + interval - 1) / interval : layers
        return Double(attnLayers * headsKV * (keyLen + valueLen) * 2)
    }

    /// For local models without catalog metadata
    static func estimated(fileBytes: Int64, isMoE: Bool, name: String = "", path: String = "") -> ModelSpec {
        let gb = Double(fileBytes) / 1_073_741_824
        // Q4 is roughly 0.57 GB per billion parameters
        let params = gb / 0.57
        let active = isMoE ? (ModelName.activeParamsB(name) ?? params * 0.11) : 0
        return ModelSpec(fileGB: gb, paramsB: params, layers: isMoE ? 48 : 40,
                         isMoE: isMoE, activeParamsB: active,
                         kvBytesPerToken: path.isEmpty ? 0 : kvBytesPerToken(atPath: path))
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

/// Conservative preflight for DFlash. llama.cpp cannot currently measure a
/// DFlash context before the target context exists (`ctx_other`), so leaving
/// `-ngld auto` alone can overcommit a discrete GPU. This planner budgets the
/// target model, both KV caches, compute buffers and the user's VRAM reserve,
/// then emits an explicit number of draft layers or rejects the draft.
struct DflashMemoryPlan: Equatable {
    let gpuLayers: Int?
    let estimatedVRAMGB: Double
    let budgetGB: Double

    var enabled: Bool { gpuLayers != nil }
}

enum DflashMemoryPlanner {
    /// DFlash uses a large target-linked compute graph that is not represented by
    /// its small GGUF file. 1.9 GiB is the observed worst case on the supported
    /// mainline engine; keeping it explicit is safer than pretending file size is
    /// the whole draft cost.
    private static let draftComputeGB = 1.9

    static func plan(vramGB: Double, reserveGB: Double,
                     baseFileGB: Double, baseLayers: Int, ncmoe: Int,
                     ctx: Int, mainKVScale: Double,
                     draftFileGB: Double, draftLayers: Int,
                     draftKVBytesPerToken: Double) -> DflashMemoryPlan {
        let budget = max(0, vramGB - reserveGB)
        guard budget > 0, baseFileGB > 0, baseLayers > 0,
              draftFileGB > 0, draftLayers > 0 else {
            return DflashMemoryPlan(gpuLayers: nil, estimatedVRAMGB: .infinity, budgetGB: budget)
        }

        // Q4 MoE files are dominated by expert weights. Attention, embeddings and
        // shared tensors account for roughly 1.3 GiB and always stay on the GPU;
        // `ncmoe` moves the proportional expert-layer share to host RAM.
        let residentBaseGB = min(baseFileGB, 1.3)
        let expertGB = max(0, baseFileGB - residentBaseGB)
        let cpuFraction = min(1, max(0, Double(ncmoe) / Double(baseLayers)))
        let baseWeightsGB = residentBaseGB + expertGB * (1 - cpuFraction)
        let paramsB = baseFileGB / 0.57
        let baseComputeGB = 0.9 + paramsB * 0.012
        // Hybrid Qwen KV grows much more slowly than a dense full-attention cache
        // because most layers use a sliding window. This coefficient is calibrated
        // against the engine's 8K/16K/32K allocations and scales with KV quantization.
        let baseKVGB = 0.021 * Double(max(0, ctx)) / 1024 * mainKVScale
        let baseNeedGB = baseWeightsGB + baseComputeGB + baseKVGB

        let draftKVGB = draftKVBytesPerToken * Double(max(0, ctx)) / 1_073_741_824
        let draftFixedGB = draftComputeGB + draftKVGB
        let weightPerLayerGB = draftFileGB * 1.05 / Double(draftLayers)
        let roomForWeightsGB = budget - baseNeedGB - draftFixedGB
        let layers = min(draftLayers, Int(floor(max(0, roomForWeightsGB) / weightPerLayerGB)))

        // CPU-only draft weights still require the target-linked GPU graph and KV.
        // If those fixed allocations do not fit, DFlash must stay off.
        guard roomForWeightsGB >= 0 else {
            return DflashMemoryPlan(gpuLayers: nil,
                                    estimatedVRAMGB: baseNeedGB + draftFixedGB,
                                    budgetGB: budget)
        }
        return DflashMemoryPlan(gpuLayers: layers,
                                estimatedVRAMGB: baseNeedGB + draftFixedGB + Double(layers) * weightPerLayerGB,
                                budgetGB: budget)
    }
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
    /// `ncmoeOverride` reflects a user-set expert-offload for a MoE model, so the
    /// shown speed/fit match what will actually run instead of the recommendation.
    static func estimateCurrent(spec: ModelSpec, hw: HardwareInfo,
                                ncmoeOverride: Int? = nil) -> MemoryEstimate {
        let d = UserDefaults.standard
        let ctx = d.object(forKey: SettingsKeys.ctx) == nil ? 16384 : d.integer(forKey: SettingsKeys.ctx)
        let scale = (kvTypeScale(d.string(forKey: SettingsKeys.cacheTypeK) ?? "f16")
                   + kvTypeScale(d.string(forKey: SettingsKeys.cacheTypeV) ?? "f16")) / 2
        return estimate(spec: spec, hw: hw, ctx: ctx, kvScale: scale,
                        multiGPU: d.bool(forKey: SettingsKeys.multiGPU),
                        tensorSplit: (d.string(forKey: SettingsKeys.splitMode) ?? "layer") == "tensor",
                        ncmoeOverride: ncmoeOverride)
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
    /// Tensor split allocates one reduction scratch buffer per device AND per
    /// butterfly step (ggml-metal.cpp), each holding a layer output at the current
    /// batch. Layer split has no allreduce, so it pays none of this.
    static func tensorSplitScratchGB(spec: ModelSpec, devices: Int) -> Double {
        guard devices >= 2 else { return 0 }
        var offsetMax = devices / 2
        while offsetMax > 0 && (offsetMax & (offsetMax - 1)) != 0 { offsetMax -= 1 }
        var steps = devices > 2 * offsetMax ? 1 : 0
        var offset = offsetMax
        while offset >= 1 { steps += 1; offset /= 2 }
        // params ~= 12 * layers * d^2 gives the hidden size within a few percent
        let d = (spec.paramsB * 1e9 / (12 * Double(max(1, spec.layers)))).squareRoot()
        let bytes = Double(devices * steps) * 512 * d * 4
        return bytes / 1e9
    }

    static func estimate(spec: ModelSpec, hw: HardwareInfo, ctx: Int = 16384, kvScale: Double = 1.0,
                         multiGPU: Bool = false, tensorSplit: Bool = false,
                         ncmoeOverride: Int? = nil) -> MemoryEstimate {
        // A layer split is sequential (pipeline): combined VRAM raises capacity,
        // not per-token speed. Use summed VRAM (driver reserve per device) when
        // the user enabled the split and there are 2+ GPUs; otherwise one card.
        let splitGPUs = hw.gpus.filter { !$0.isIntegrated }.count
        let splitting = multiGPU && splitGPUs >= 2
        let bwVRAM = bandwidthGBs(of: hw.bestGPU)
        let denseEff = decodeEfficiency(of: hw.bestGPU)
        let effectiveBW = bwVRAM * denseEff
        let vramBudget = (splitting ? hw.combinedVramGB : hw.vramGB) - Double(splitting ? splitGPUs : 1)
        let kvGB = kvCache(spec: spec, ctx: ctx) * kvScale
        let scratchGB = (splitting && tensorSplit)
            ? tensorSplitScratchGB(spec: spec, devices: splitGPUs) : 0
        let computeGB = 0.9 + spec.paramsB * 0.012 + scratchGB

        if !spec.isMoE {
            let need = spec.fileGB * 1.03 + kvGB + computeGB
            if need <= vramBudget {
                // Decode is bandwidth-bound: t/s ≈ VRAM bandwidth / bytes read per
                // token, and a full-GPU dense model reads its whole file each token.
                let tg = clampSpeed(effectiveBW / max(0.5, spec.fileGB), effective: effectiveBW)
                return MemoryEstimate(vramGB: need, ramGB: 0.7, suggestedNcmoe: 0,
                                      level: .ideal, expectedSpeed: speedRange(tg))
            }
            // Partly on the CPU: every token still reads the whole model, so the
            // share left in RAM is read at RAM speed and sets the pace.
            if spec.fileGB * 0.5 <= vramBudget && spec.fileGB < hw.ramGB * 0.6 {
                let onGPU = max(0, vramBudget - kvGB - computeGB)
                let fracRAM = max(0, min(1, (spec.fileGB - onGPU) / max(0.5, spec.fileGB)))
                let perToken = spec.fileGB * ((1 - fracRAM) / effectiveBW + fracRAM / bwRAM)
                let tg = clampSpeed(1 / max(0.0001, perToken), effective: effectiveBW)
                return MemoryEstimate(vramGB: vramBudget, ramGB: spec.fileGB - vramBudget + 2,
                                      suggestedNcmoe: 0, level: .slow, expectedSpeed: speedRange(tg))
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

        let autoNcmoe = expertsGB > 0
            ? min(spec.layers, Int((Double(spec.layers) * (cpuExpertsGB / expertsGB)).rounded(.up)))
            : 0
        // A user-set offload wins over the recommendation; experts split by that fraction.
        let ncmoe = ncmoeOverride.map { max(0, min(spec.layers, $0)) } ?? autoNcmoe
        let fracRAM = min(1, Double(ncmoe) / Double(max(1, spec.layers)))
        let cpuExperts = expertsGB * fracRAM
        let gpuExperts = expertsGB - cpuExperts

        // Only the active experts are read per token; a fraction sits in RAM
        // (slow) and the rest in VRAM, so more offload means fewer t/s. The quant
        // shows up as bytes-per-param = fileGB / total params.
        let active = spec.activeParamsB > 0 ? spec.activeParamsB : spec.paramsB * 0.11
        let bytesPerParam = spec.fileGB / max(1, spec.paramsB)
        let activeGB = active * bytesPerParam
        let perToken = activeGB * ((1 - fracRAM) / bwVRAM + fracRAM / bwRAM)
        let tg = clampSpeed(moeEff * (denseEff / 0.72) / max(0.0001, perToken), effective: effectiveBW)

        if ncmoe == 0 {
            return MemoryEstimate(vramGB: spec.fileGB + overheadGB, ramGB: 0.7, suggestedNcmoe: 0,
                                  level: .ideal, expectedSpeed: speedRange(tg))
        }
        let level: FitLevel = fracRAM > 0.85 ? .slow : .good
        return MemoryEstimate(vramGB: overheadGB + gpuExperts, ramGB: cpuExperts + 1.0,
                              suggestedNcmoe: ncmoe, level: level, expectedSpeed: speedRange(tg))
    }

    // Decode-speed model constants, calibrated to measured truths (Qwen3-8B Q4
    // ≈ 58 tg full-GPU on a 384 GB/s card; Qwen3.6-35B-A3B ≈ 24.5 tg at ncmoe 24).
    private static let bwRAM = 48.0
    private static let moeEff = 0.48
    private static let defaultBandwidth = 384.0

    /// Share of the card's bandwidth decode actually reaches. A 64-lane card gets
    /// nowhere near its own figure: measured 58.78 tg on a Vega II Duo against
    /// 61 on an RX 6700 XT with the same Qwen3-8B Q4_K_M, despite 2.7x the
    /// bandwidth, so both land near 280 GB/s of real throughput.
    static func decodeEfficiency(of gpu: GPUDevice?) -> Double {
        guard let name = gpu?.name.lowercased() else { return 0.72 }
        let wide = ["vega", "radeon vii", "rx 580", "rx 570", "rx 590", "rx 560",
                    "pro 580", "pro 575", "pro 570", "pro 560"]
        return wide.contains(where: name.contains) ? 0.27 : 0.72
    }

    /// Memory bandwidth in GB/s of the card that will run the model. Decode is
    /// bandwidth-bound, so an estimate made on another card's figure is wrong by
    /// the ratio between them.
    static func bandwidthGBs(of gpu: GPUDevice?) -> Double {
        guard let name = gpu?.name.lowercased() else { return defaultBandwidth }
        // Longest match first: "vega ii" must win over "vega".
        let table: [(String, Double)] = [
            ("vega ii", 1024), ("radeon vii", 1024),
            ("vega 64", 484), ("vega 56", 410), ("vega frontier", 484), ("vega", 484),
            ("w6900x", 512), ("w6800x", 512), ("w6800", 512),
            ("6950 xt", 576), ("6900 xt", 512), ("6800 xt", 512), ("rx 6800", 512),
            ("6750 xt", 432), ("6700 xt", 384), ("rx 6700", 384),
            ("6650 xt", 280), ("6600 xt", 256), ("rx 6600", 224),
            ("6500 xt", 144), ("6400", 128),
            ("w5700", 448), ("5700 xt", 448), ("rx 5700", 448),
            ("5600 xt", 288), ("5500 xt", 224), ("rx 5500", 224), ("5300", 168),
            ("vii", 1024),
            ("rx 590", 256), ("rx 580", 256), ("rx 570", 224), ("rx 560", 112),
            ("pro 580", 256), ("pro 575", 224), ("pro 570", 224), ("pro 560", 112),
            ("w5500", 224), ("w5100", 96),
            ("7900 xtx", 960), ("7900 xt", 800), ("7800 xt", 624), ("7700 xt", 432),
            ("m4 max", 546), ("m3 max", 400), ("m2 max", 400), ("m1 max", 400),
            ("m4 pro", 273), ("m3 pro", 150), ("m2 pro", 200), ("m1 pro", 200),
            ("m4", 120), ("m3", 100), ("m2", 100), ("m1", 68)
        ]
        for (key, value) in table where name.contains(key) { return value }
        return defaultBandwidth
    }

    /// A tiny model never reaches its bandwidth ceiling: sampling and the graph
    /// itself dominate, so the band is capped relative to what decode reaches.
    private static func clampSpeed(_ tg: Double, effective: Double) -> Double {
        min(max(60, effective / 4), max(4, tg))
    }

    /// "~lo-hi t/s" band; the estimate is deliberately approximate.
    private static func speedRange(_ tg: Double) -> String {
        "~\(Int((tg * 0.8).rounded()))-\(Int(tg.rounded())) t/s"
    }

    private static func kvCache(spec: ModelSpec, ctx: Int) -> Double {
        if spec.kvBytesPerToken > 0 {
            return spec.kvBytesPerToken * Double(ctx) / 1_073_741_824
        }
        // GQA f16 heuristic when the geometry is unreadable
        let perK = spec.paramsB >= 25 ? 0.10 : spec.paramsB >= 12 ? 0.08 : 0.05
        return perK * Double(ctx) / 1024
    }
}

/// A model row of the GPU listing: how many cards, and how many GPUs they expose.
struct GPUModelGroup {
    let name: String
    let cards: Int
    let gpus: Int
    let vramGB: Int

    /// A Duo holds two GPUs behind one name, so counting Metal devices doubles the
    /// cards. The name is the only thing that tells them apart.
    static func diesPerCard(_ name: String) -> Int {
        name.range(of: "duo", options: .caseInsensitive) != nil ? 2 : 1
    }
}

/// Shared so a row's letter in the GPU list matches the machine card beside it.
enum GPUPeerTopology {
    static func groupIDs(_ items: [(index: Int, groupID: UInt64)]) -> [UInt64] {
        let linked = items.filter { $0.groupID != 0 }
        let byGroup = Dictionary(grouping: linked, by: \.groupID).filter { $0.value.count > 1 }
        return byGroup.keys.sorted { left, right in
            let a = byGroup[left]!, b = byGroup[right]!
            let firstA = a.map(\.index).min() ?? 0, firstB = b.map(\.index).min() ?? 0
            return a.count == b.count ? firstA < firstB : a.count > b.count
        }
    }

    static func labels(_ items: [(index: Int, groupID: UInt64)]) -> [UInt64: String] {
        groupIDs(items).enumerated().reduce(into: [:]) { out, pair in
            out[pair.element] = letter(pair.offset)
        }
    }

    /// Cards behind one bridge are the pairing worth selecting together.
    static func groups(of gpus: [GPUDevice]) -> [(label: String, indices: [Int])] {
        let items = gpus.map { (index: $0.index, groupID: $0.peerGroupID) }
        return labels(items).sorted { $0.value < $1.value }.map { id, label in
            (label, gpus.filter { $0.peerGroupID == id }.map(\.index).sorted())
        }
    }

    private static func letter(_ position: Int) -> String {
        position < 26
            ? String(UnicodeScalar(UInt8(65 + position)))
            : String(position + 1)
    }
}
