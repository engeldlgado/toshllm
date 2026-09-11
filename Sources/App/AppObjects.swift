// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The app-lifetime models, held behind a plain reference instead of `@StateObject`
/// on the `App`. A property wrapper there subscribes the scene body to every
/// publish, so a VRAM sample or a log line would rebuild both windows and the menu
/// bar; the views that actually read them take them from the environment.
@MainActor
final class AppObjects {
    static let shared = AppObjects()

    let manager = ServerManager.shared
    // The active instance. One server today; switching the active one is handled
    // when the multi-server UI lands.
    let server = ServerManager.shared.active
    let models = ModelStore()
    let vram = VRAMMonitor()
    let loc = Localizer()
    let bench = BenchmarkController()
    let search = SearchStore()
    let profiles = ProfileStore()
    let updates = UpdateChecker()
    let modelUpdates = ModelUpdateChecker()
    let control = ControlPanelState()

    private init() {}
}
