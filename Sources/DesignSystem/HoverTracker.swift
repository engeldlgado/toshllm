// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

/// Hover that survives redraws: onHover reinstalls its tracking area on every
/// re-evaluation, and AppKit answers a fresh one with an exit.
struct HoverTracker: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange   // swapping the closure keeps the tracking area
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                      owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }

        // Tracking areas keep working without taking part in hit testing, and
        // this view must never swallow a click meant for the control it covers.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
