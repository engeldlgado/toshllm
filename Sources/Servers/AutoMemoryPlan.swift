// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The engine's context-first memory plan (TOSH_AUTO). The app previews it with the exact
/// launch arguments before starting the server, and the engine confirms what it really did
/// in `<plan>.runtime`; the runtime file is the authority.
struct AutoMemoryPlan: Decodable, Equatable {
    struct Candidate: Decodable, Equatable {
        let name: String
        let mode: String
        let kv: String
        let valid: Bool
        let reason: String
        let ubatch: Int
        let ncmoe: Int
        let privateMib: Double
        let freeMib: Double
        let arenaMib: Double
    }

    /// The engine's stable view of the plan (schema 1): codes and bytes, no sentences.
    struct Product: Decodable, Equatable {
        struct Memory: Decodable, Equatable {
            let physicalBytes: Int64
            let reclaimableBytes: Int64
            let projectedRssBytes: Int64
            let projectedVramBytes: Int64
        }
        struct DMoE: Decodable, Equatable {
            let expertBankBytes: Int64
            let hotBytes: Int64
            let warmBytes: Int64
            let coverage: Double
            let coverageState: String
        }
        struct Runtime: Decodable, Equatable {
            let context: Int
            let kvType: String
            let kvBytes: Int64
            let ubatch: Int
            let ncmoeLayers: Int
        }
        struct Unsupported: Decodable, Equatable {
            let requiredHostBytes: Int64
            let availableHostBytes: Int64
            let requiredVramBytes: Int64
            let availableVramBytes: Int64
        }
        let mode: String
        let modeLabelKey: String
        let reason: String
        let warnings: [String]
        let limitingResource: String
        let memory: Memory
        let dmoe: DMoE
        let runtime: Runtime
        let unsupported: Unsupported?
    }

    /// What the user sees: the five Dynamic MoE outcomes, plus a model that fits whole.
    enum ProductState: Equatable {
        case fullGPU, fullHost, boundedHost, memoryConstrained, classicFallback, cannotLoad
    }

    let planSchemaVersion: Int?
    let product: Product?
    let state: String
    let mode: String
    let reason: String
    let fallback: String
    let kv: String
    let nCtx: Int
    let ubatch: Int
    let ncmoe: Int
    let reserveMib: Double
    let arenaMib: Double
    let minArenaMib: Double
    let projectedFreeMib: Double
    let hostRequiredMib: Double
    let vramTotalMib: Double
    let bankMib: Double
    let mlock: String
    let dispersion: String
    let candidates: [Candidate]

    var isUnsupported: Bool { state == "UNSUPPORTED" }
    var usesDynamicMoE: Bool { mode == "dmoe" || mode == "dmoe_bounded" }
    /// The user asked for RAM to hold only the experts that are not in VRAM.
    var savesHostRAM: Bool { product?.reason == "HOST_RAM_SAVING" }
    /// Auto took turbo4 because F16 and Q8 left the experts on the CPU.
    var autoPickedTurbo4: Bool { product?.warnings.contains("KV_TURBO4_AUTO") == true }

    var productState: ProductState {
        switch product?.mode ?? "" {
        case "PLAN_FULL_GPU": return .fullGPU
        case "PLAN_FULL_HOST_DMOE": return .fullHost
        // a cache kept small by choice is not a machine short of memory
        case "PLAN_BOUNDED_DMOE": return product?.dmoe.coverageState == "GOOD" || savesHostRAM ? .boundedHost : .memoryConstrained
        case "PLAN_CLASSIC_NCMOE": return .classicFallback
        case "PLAN_UNSUPPORTED": return .cannotLoad
        default:
            return isUnsupported ? .cannotLoad : mode == "legacy_offload" ? .classicFallback : mode == "full_gpu" ? .fullGPU : .fullHost
        }
    }

    static func planURL(port: Int) -> URL {
        let dir = AppSupport.directory.appendingPathComponent("plans")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("plan-\(port).json")
    }

    static func runtimeURL(port: Int) -> URL {
        URL(fileURLWithPath: planURL(port: port).path + ".runtime")
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static func decode(_ data: Data) -> AutoMemoryPlan? {
        try? decoder.decode(AutoMemoryPlan.self, from: data)
    }

    /// Runs the engine with the launch's own arguments and environment, asking it for the plan
    /// only. It loads no weights; a few seconds on a warm driver cache.
    nonisolated static func preview(settings: ServerSettings) async -> AutoMemoryPlan? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: settings.serverBinary)
                p.arguments = settings.arguments
                var env = settings.environment
                env["TOSH_AUTO_DRY_RUN"] = "exit"
                p.environment = env
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { cont.resume(returning: nil); return }
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: timer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()
                let line = String(decoding: data, as: UTF8.self)
                    .split(separator: "\n").last(where: { $0.hasPrefix("{") }).map(String.init)
                cont.resume(returning: line.flatMap { decode(Data($0.utf8)) })
            }
        }
    }

    static func readPlan(port: Int) -> AutoMemoryPlan? {
        (try? Data(contentsOf: planURL(port: port))).flatMap(decode)
    }
}

/// What the engine did once running: whether mixed execution started, its arena, and why not.
struct AutoMemoryRuntime: Decodable, Equatable {
    let dmoe: String
    let code: String
    let detail: String
    let arenaMib: Double
    let bankLocked: Bool

    var isOn: Bool { dmoe == "on" }

    static func read(port: Int) -> AutoMemoryRuntime? {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return (try? Data(contentsOf: AutoMemoryPlan.runtimeURL(port: port))).flatMap { try? d.decode(AutoMemoryRuntime.self, from: $0) }
    }
}

/// How the load that followed the plan ended, with measured memory next to the projection.
struct AutoMemoryActual: Decodable, Equatable {
    let loadResult: String
    let detail: String
    let runtimeCode: String
    let mode: String
    let projectedRssBytes: Int64
    let actualRssBytes: Int64
    let actualFootprintBytes: Int64
    let projectedVramBytes: Int64
    let actualVramBytes: Int64

    static func read(port: Int) -> AutoMemoryActual? {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let url = URL(fileURLWithPath: AutoMemoryPlan.planURL(port: port).path + ".actual")
        return (try? Data(contentsOf: url)).flatMap { try? d.decode(AutoMemoryActual.self, from: $0) }
    }
}

/// User-facing wording for a plan. Rounded numbers: the exact MiB belong to diagnostics.
enum AutoMemoryText {
    private static func t(_ es: String, _ en: String) -> String {
        (UserDefaults.standard.string(forKey: SettingsKeys.language) ?? "en") == "es" ? es : en
    }

    private static func gib(_ mib: Double) -> String {
        String(format: "~%.1f GiB", mib/1024)
    }

    private static func kvLabel(_ kv: String) -> String {
        switch kv {
        case "f16": return "F16"
        case "q8_0": return "Q8"
        case "turbo4": return t("Turbo4 (ahorro de memoria)", "Turbo4 (memory saver)")
        default: return kv
        }
    }

    static func modeLabel(_ mode: String) -> String {
        switch mode {
        case "full_gpu": return t("GPU completa", "Full GPU")
        case "dmoe": return "Dynamic MoE"
        case "dmoe_bounded": return t("Dynamic MoE (RAM limitada)", "Dynamic MoE (bounded RAM)")
        case "legacy_offload": return t("Expertos en CPU", "Expert offload")
        default: return t("Sin configuración válida", "No valid configuration")
        }
    }

    /// e.g. "Dynamic MoE · ~7.1 GiB expert cache · 32K context · KV F16 · ~1.1 GiB VRAM headroom"
    static func summary(_ plan: AutoMemoryPlan, runtime: AutoMemoryRuntime?) -> String {
        var parts = [modeLabel(plan.mode)]
        if plan.usesDynamicMoE {
            let arena = runtime.map { $0.isOn ? $0.arenaMib : 0 } ?? plan.arenaMib
            parts.append(t("\(gib(arena)) de caché de expertos", "\(gib(arena)) expert cache"))
            if let p = plan.product, p.dmoe.warmBytes > 0 {
                parts.append(t("\(gib(Double(p.dmoe.warmBytes)/1048576)) en RAM", "\(gib(Double(p.dmoe.warmBytes)/1048576)) in RAM"))
            }
            if plan.productState == .memoryConstrained { parts.append(t("memoria justa", "memory constrained")) }
        } else if plan.mode == "legacy_offload" {
            parts.append(t("\(plan.ncmoe) capas de expertos en CPU", "\(plan.ncmoe) expert layers on CPU"))
        }
        parts.append(t("contexto \(plan.nCtx / 1024)K", "\(plan.nCtx / 1024)K context"))
        // a plan that found no configuration chose no cache type either
        if !plan.isUnsupported {
            parts.append(plan.autoPickedTurbo4
                         ? t("KV Turbo4 (Auto: puede ir más rápido, con algo menos de calidad)",
                             "KV Turbo4 (Auto: can be faster, at some quality cost)")
                         : "KV \(kvLabel(plan.kv))")
            parts.append(t("\(gib(plan.projectedFreeMib)) de VRAM libre", "\(gib(plan.projectedFreeMib)) VRAM headroom"))
        }
        return parts.joined(separator: " · ")
    }

    /// "Why this mode?" for diagnostics.
    static func reason(_ plan: AutoMemoryPlan) -> String {
        var s: String
        switch plan.state {
        case "FULL_GPU_OPTIMAL":
            s = t("GPU completa: el modelo y el contexto pedido caben con margen.",
                  "Full GPU: the model and the requested context fit with headroom.")
        case "DMOE_CONTEXT_OPTIMAL":
            s = t("Dynamic MoE: el modelo cabe entero, pero no dejaría margen para el contexto pedido; los expertos poco usados se quedan en RAM.",
                  "Dynamic MoE: the model would fit, but not with room for the requested context; rarely used experts stay in RAM.")
        case "DMOE_CAPACITY_REQUIRED":
            s = t("Dynamic MoE: el modelo no cabe en VRAM; la GPU guarda los expertos más usados.",
                  "Dynamic MoE: the model does not fit in VRAM; the GPU keeps the most used experts.")
        case "DMOE_BOUNDED_HOST" where plan.savesHostRAM:
            s = t("Dynamic MoE ahorrando RAM: la RAM guarda solo los expertos que no están en VRAM y el resto se lee del archivo del modelo.",
                  "Dynamic MoE saving RAM: RAM keeps only the experts that are not in VRAM and the rest are read from the model file.")
        case "DMOE_BOUNDED_HOST":
            s = t("Dynamic MoE con RAM limitada: la memoria libre ahora no da para todo el banco de expertos; la RAM guarda los más usados y el resto se lee del archivo del modelo.",
                  "Dynamic MoE with bounded RAM: free memory right now cannot hold the whole expert bank; RAM keeps the most used experts and the rest are read from the model file.")
        case "LEGACY_OFFLOAD_BETTER":
            s = t("Expertos en CPU: Dynamic MoE no está disponible para este modelo o esta máquina.",
                  "Expert offload: Dynamic MoE is not available for this model or machine.")
        default:
            if let u = plan.product?.unsupported {
                let need = { (b: Int64) in gib(Double(b)/1048576) }
                s = u.requiredVramBytes > u.availableVramBytes
                    ? t("No hay configuración segura: hace falta \(need(u.requiredVramBytes)) de VRAM y hay \(need(u.availableVramBytes)).",
                        "No safe configuration: it needs \(need(u.requiredVramBytes)) of VRAM and \(need(u.availableVramBytes)) is free.")
                    : t("No hay configuración segura: hace falta \(need(u.requiredHostBytes)) de RAM y ahora hay \(need(u.availableHostBytes)).",
                        "No safe configuration: it needs \(need(u.requiredHostBytes)) of RAM and \(need(u.availableHostBytes)) is available now.")
            } else {
                s = t("Ninguna configuración deja un margen de VRAM seguro con este contexto; reduce el contexto.",
                      "No configuration leaves a safe VRAM margin at this context; lower the context.")
            }
        }
        if plan.kv == "q8_0" {
            s += " " + t("KV Q8: reduce la memoria del contexto lo suficiente para mantener una caché de expertos útil.",
                         "KV Q8: shrinks context memory enough to keep a useful expert cache.")
        }
        if plan.autoPickedTurbo4 {
            s += " " + t("KV Turbo4, elegido por Auto: ni F16 ni Q8 dejaban los expertos en la GPU. Puede ir bastante más rápido que con los expertos en la CPU, con algo de pérdida de calidad; fija la caché KV en F16 o Q8 para evitarlo.",
                         "KV Turbo4, picked by Auto: neither F16 nor Q8 kept the experts on the GPU. It can be much faster than experts on the CPU, at some quality cost; set the KV cache to F16 or Q8 to avoid it.")
        }
        if !plan.fallback.isEmpty { s += " (\(plan.fallback))" }
        return s
    }

    /// A structured engine refusal, in words for the UI.
    static func runtimeProblem(_ runtime: AutoMemoryRuntime) -> String? {
        switch runtime.code {
        case "DMOE_ON": return nil
        case "DMOE_HOST_BANK_NOT_LOCKABLE":
            return t("Dynamic MoE no pudo reservar suficiente memoria del sistema bloqueada.",
                     "Dynamic MoE could not reserve enough locked system memory.")
        case "DMOE_ARENA_BELOW_MINIMUM":
            return t("La VRAM libre no alcanza para una caché de expertos útil.",
                     "Free VRAM is too small for a useful expert cache.")
        default:
            return t("Dynamic MoE no admite la geometría de este modelo.",
                     "Dynamic MoE does not support this model's layout.")
        }
    }
}
