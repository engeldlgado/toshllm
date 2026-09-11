// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Uses the exact icon shipped by the running application. Keeping this in one
/// component prevents the sidebar, onboarding and About views from drifting to
/// unrelated SF Symbols.
struct ToshLLMLogo: View {
    var size: CGFloat = 38

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("ToshLLM")
    }
}
