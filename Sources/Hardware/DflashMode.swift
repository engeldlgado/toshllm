// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Per-model DFlash policy. Auto is deliberately restricted to MoE models with
/// CPU-offloaded experts, where speculative verification can beat normal decode.
enum DflashMode: String, CaseIterable, Identifiable {
    case off
    case auto
    case forced

    var id: String { rawValue }
}

struct DflashRuntimeWarning: Identifiable, Equatable {
    let id = UUID()
    let modelPath: String
    let usedGB: Double
    let totalGB: Double
    let fraction: Double
}
