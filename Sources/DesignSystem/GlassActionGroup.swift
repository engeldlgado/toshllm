// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Groups nearby glass controls on macOS 26 so their highlights and morphing
/// behave as one native surface. Earlier macOS releases keep the same layout.
struct GlassActionGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        #if compiler(>=6.2) && !TOSH_LEGACY_UI
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) { content }
            }
        } else {
            HStack(spacing: 10) { content }
        }
        #else
        HStack(spacing: 10) { content }
        #endif
    }
}
