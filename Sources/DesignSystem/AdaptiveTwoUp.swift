// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Side by side when there is room, stacked otherwise. Not ViewThatFits: it builds
/// every candidate, which splits hover and focus across the copy that is hidden.
struct AdaptiveTwoUp<First: View, Second: View>: View {
    var threshold: CGFloat
    var spacing: CGFloat = 14
    var alignment: VerticalAlignment = .top
    @ViewBuilder var first: First
    @ViewBuilder var second: Second

    @State private var wide = true

    var body: some View {
        if #available(macOS 15, *) {
            stack.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                wide = width >= threshold
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: alignment, spacing: spacing) { first; second }
                    .frame(minWidth: threshold)
                VStack(alignment: .leading, spacing: spacing) { first; second }
            }
        }
    }

    @ViewBuilder private var stack: some View {
        if wide {
            HStack(alignment: alignment, spacing: spacing) { first; second }
        } else {
            VStack(alignment: .leading, spacing: spacing) { first; second }
        }
    }
}
