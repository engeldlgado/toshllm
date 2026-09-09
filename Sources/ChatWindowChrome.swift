// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

extension View {
    @ViewBuilder
    func hiddenChatToolbarBackground() -> some View {
        if #available(macOS 15.0, *) {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}

/// Applies the same title-bar treatment used by native document windows while
/// leaving the content and sidebar responsible for their own backgrounds.
struct ChatWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowConfigurationView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowConfigurationView)?.applyConfiguration()
    }
}

private final class WindowConfigurationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyConfiguration()
    }

    func applyConfiguration() {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.toolbar?.showsBaselineSeparator = false
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}
