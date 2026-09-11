// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct AudioVADConfiguration: Equatable, Sendable {
    let mode: AudioVADMode
    let calibration: AudioVADCalibration?

    var isEnabled: Bool { mode.isEnabled }

    func arguments(modelURL: URL) -> [String] {
        guard isEnabled else { return [] }
        var result = ["--vad", "--vad-model", modelURL.path]
        if mode == .calibrated, let calibration {
            result.append(contentsOf: calibration.arguments)
        }
        return result
    }
}
