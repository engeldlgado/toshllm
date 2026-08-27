// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum AudioVADMode: String, CaseIterable, Identifiable, Sendable {
    case disabled
    case standard
    case calibrated

    static let defaultMode = AudioVADMode.standard

    var id: String { rawValue }

    var isEnabled: Bool { self != .disabled }
}
