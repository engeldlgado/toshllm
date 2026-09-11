// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum AudioVADProfile: String, CaseIterable, Identifiable {
    case sensitive
    case balanced
    case strict
    case custom

    static let defaultProfile = AudioVADProfile.balanced

    var id: String { rawValue }

    var calibration: AudioVADCalibration {
        switch self {
        case .sensitive:
            AudioVADCalibration(threshold: 0.35, minSpeechDurationMS: 150,
                                minSilenceDurationMS: 100, maxSpeechDurationSeconds: 30,
                                speechPadMS: 140, samplesOverlap: 0.2)
        case .balanced, .custom:
            AudioVADCalibration(threshold: 0.5, minSpeechDurationMS: 250,
                                minSilenceDurationMS: 100, maxSpeechDurationSeconds: 30,
                                speechPadMS: 80, samplesOverlap: 0.1)
        case .strict:
            AudioVADCalibration(threshold: 0.75, minSpeechDurationMS: 500,
                                minSilenceDurationMS: 250, maxSpeechDurationSeconds: 25,
                                speechPadMS: 60, samplesOverlap: 0.05)
        }
    }
}
