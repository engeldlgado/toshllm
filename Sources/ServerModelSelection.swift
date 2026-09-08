// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension Profile {
    mutating func selectInstanceModel(path: String, ncmoe: Int) {
        modelPath = path
        self.ncmoe = ncmoe
        // nil is a legacy full snapshot; retain all its other overrides.
        if var pins = pinned, !pins.contains(Pin.model) {
            pins.append(Pin.model)
            pinned = pins
        }
    }
}

extension ServerController {
    /// Shared by the overview and expanded configuration. Never mutate another
    /// instance, and never change the displayed model underneath a running engine.
    func selectModel(path: String, ncmoe: Int) {
        guard state != .running && state != .starting else { return }
        if var profile {
            profile.selectInstanceModel(path: path, ncmoe: ncmoe)
            self.profile = profile
        } else {
            UserDefaults.standard.set(path, forKey: SettingsKeys.modelPath)
            UserDefaults.standard.set(ncmoe, forKey: SettingsKeys.ncmoe)
        }
    }
}
