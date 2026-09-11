// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct DynamicMoeOptimizationSample: Identifiable, Sendable {
    let route: DynamicMoeExecutionRoute
    let slots: Int
    let prefetch: Int
    let pp: Double
    let tg: Double
    let estimatedVRAMFraction: Double?

    var id: String { "\(route.rawValue)-\(slots)-p\(prefetch)" }
}
