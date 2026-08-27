// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum DynamicMoeOptimizationState: Equatable {
    case idle
    case cannotOptimize
    case measuringBaseline
    case baselineFailed
    case testingDirect(slots: Int)
    case optimizedDirect(slots: Int)
    case saveFailed(message: String)
    case mapCreationFailed
    case learningExperts
    case invalidMap
    case testingSplit(slots: Int)
    case noSweepResults
    case tuningPrefetch(Int)
    case optimizedSplit(slots: Int, ringSlots: Int)
    case cancelled

    func localized(using loc: Localizer) -> String {
        switch self {
        case .idle:
            return ""
        case .cannotOptimize:
            return loc.t("No se puede optimizar este modelo", "This model cannot be optimized")
        case .measuringBaseline:
            return loc.t("Midiendo referencia normal…", "Measuring normal baseline…")
        case .baselineFailed:
            return loc.t("Falló la medición de referencia", "Baseline measurement failed")
        case .testingDirect(let slots):
            return loc.t("Probando dMoE directo K\(slots)…", "Testing direct dMoE K\(slots)…")
        case .optimizedDirect(let slots):
            return loc.t("Optimizado: ruta directa K\(slots)", "Optimized: direct route K\(slots)")
        case .saveFailed(let message):
            return loc.t("No se pudo guardar: \(message)", "Could not save: \(message)")
        case .mapCreationFailed:
            return loc.t("No se pudo crear el mapa de expertos", "Could not create the expert map")
        case .learningExperts:
            return loc.t("Aprendiendo expertos por capa…", "Learning experts by layer…")
        case .invalidMap:
            return loc.t("No se pudo generar un mapa válido", "Could not generate a valid map")
        case .testingSplit(let slots):
            return loc.t("Probando dMoE dividido K\(slots)…", "Testing split dMoE K\(slots)…")
        case .noSweepResults:
            return loc.t("El barrido dMoE no produjo resultados", "The dMoE sweep produced no results")
        case .tuningPrefetch(let prefetch):
            return loc.t("Afinando procesamiento del prompt · prefetch\(prefetch)…",
                         "Tuning prompt processing · prefetch\(prefetch)…")
        case .optimizedSplit(let slots, let ringSlots):
            return loc.t("Optimizado: ruta dividida K\(slots) + ring\(ringSlots)",
                         "Optimized: split route K\(slots) + ring\(ringSlots)")
        case .cancelled:
            return loc.t("Optimización cancelada", "Optimization cancelled")
        }
    }
}
