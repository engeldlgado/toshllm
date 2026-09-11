// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum AudioVADPreferences {
    static func configuration(defaults: UserDefaults = .standard) -> AudioVADConfiguration {
        let mode = defaults.string(forKey: SettingsKeys.audioVADMode)
            .flatMap(AudioVADMode.init(rawValue:)) ?? .defaultMode
        return AudioVADConfiguration(
            mode: mode,
            calibration: mode == .calibrated ? calibration(defaults: defaults) : nil
        )
    }

    static func calibration(defaults: UserDefaults = .standard) -> AudioVADCalibration {
        let profile = defaults.string(forKey: SettingsKeys.audioVADProfile)
            .flatMap(AudioVADProfile.init(rawValue:)) ?? .defaultProfile
        guard profile == .custom else { return profile.calibration }
        let fallback = AudioVADProfile.balanced.calibration
        return .custom(
            threshold: value(SettingsKeys.audioVADThreshold, fallback.threshold, defaults),
            minSpeechDurationMS: value(SettingsKeys.audioVADMinSpeechMS,
                                       Double(fallback.minSpeechDurationMS), defaults),
            minSilenceDurationMS: value(SettingsKeys.audioVADMinSilenceMS,
                                        Double(fallback.minSilenceDurationMS), defaults),
            maxSpeechDurationSeconds: value(SettingsKeys.audioVADMaxSpeechSeconds,
                                            fallback.maxSpeechDurationSeconds, defaults),
            speechPadMS: value(SettingsKeys.audioVADSpeechPadMS,
                               Double(fallback.speechPadMS), defaults)
        )
    }

    private static func value(_ key: String, _ fallback: Double,
                              _ defaults: UserDefaults) -> Double {
        defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
    }
}
