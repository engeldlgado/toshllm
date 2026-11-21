// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// The configuration window, as AppKit.
///
/// macOS 12 draws only the first WindowGroup at launch and renders a second scene's
/// content lazily, so `openWindow(id: "control")` has no SwiftUI window to show and the
/// model picker stays unreachable. `MenuBarAppKit.swift` hosts its panel the same way:
/// the very same `ControlPanelView` goes into an `NSHostingController` and the window is
/// built the first time something asks for it.
enum ControlWindow {
    static func register() {
        ToshWindowRegistry.shared.setFactory(id: "control") { make() }
    }

    private static func make() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: Root()))
        window.title = AppObjects.shared.loc.t("Configuración", "Configuration")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 1080, height: 700))
        window.center()
        return window
    }

    struct Root: View {
        private let obj = AppObjects.shared
        @AppStorage(SettingsKeys.appAccent) private var accentRaw = AppTheme.defaultKey

        var body: some View {
            ControlPanelView()
                .tint(AppTheme.accent(accentRaw))
                .environmentObject(obj.server)
                .environmentObject(obj.manager)
                .environmentObject(obj.models)
                .environmentObject(obj.vram)
                .environmentObject(obj.loc)
                .environmentObject(obj.bench)
                .environmentObject(obj.search)
                .environmentObject(obj.profiles)
                .environmentObject(obj.updates)
                .environmentObject(obj.modelUpdates)
                .environmentObject(obj.control)
                .frame(minWidth: 980, minHeight: 640)
                .background(ChatWindowConfigurator())
        }
    }
}
