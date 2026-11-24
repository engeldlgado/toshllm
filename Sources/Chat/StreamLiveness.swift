// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Whether a chat stream is still alive. Prompt progress and text both show the engine working; until text
/// arrives the engine may take a long batch of prompt between progress reports, after that it has to keep it
/// coming.
struct StreamLiveness {
    static let promptLimit: TimeInterval = 180
    static let textLimit: TimeInterval = 30

    private(set) var last: Date
    private(set) var sawText = false

    init(now: Date = Date()) {
        last = now
    }

    mutating func note(text: Bool, now: Date = Date()) {
        last = now
        if text { sawText = true }
    }

    func stalled(now: Date = Date()) -> Bool {
        now.timeIntervalSince(last) > (sawText ? Self.textLimit : Self.promptLimit)
    }

    /// What the watchdog saw when it gave up, for the log.
    func report(now: Date = Date()) -> String {
        String(format: "%.0f s without output %@ (limit %.0f s)", now.timeIntervalSince(last),
               sawText ? "after text" : "during the prompt", sawText ? Self.textLimit : Self.promptLimit)
    }
}
