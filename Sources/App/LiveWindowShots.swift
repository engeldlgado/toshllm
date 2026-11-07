// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Debug-only: dumps the live windows to PNG. This host grants the shell no Screen
/// Recording, so `screencapture` sees only the desktop; drawing the real view tree
/// from inside the process is the only way to see what the user is looking at.
/// Enabled by TOSH_LIVE_SHOTS=<dir>, optionally with TOSH_LIVE_OPEN=control.
enum LiveWindowShots {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["TOSH_LIVE_SHOTS"] else { return }
        if env["TOSH_LIVE_OPEN"] == "control" {
            ToshOpenWindow()(id: "control")
        }
        let delay = Double(env["TOSH_LIVE_DELAY"] ?? "") ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            for window in NSApp.windows where window.isVisible {
                guard let content = window.contentView,
                      content.bounds.width > 1, content.bounds.height > 1,
                      let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
                else { continue }
                content.cacheDisplay(in: content.bounds, to: rep)
                guard let data = rep.representation(using: .png, properties: [:]) else { continue }
                let key = window.identifier?.rawValue ?? window.className
                let url = URL(fileURLWithPath: dir)
                    .appendingPathComponent("live-\(key.replacingOccurrences(of: " ", with: "_")).png")
                try? data.write(to: url)
                let message = "live shot \(url.lastPathComponent) "
                    + "\(Int(content.bounds.width))x\(Int(content.bounds.height))\n"
                FileHandle.standardError.write(Data(message.utf8))
            }
        }
    }
}
