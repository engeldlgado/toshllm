// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct ComposerCircleLabel: View {
    let title: String
    let systemImage: String
    var active = false
    @AppStorage(SettingsKeys.appAccent) private var accentRaw = AppTheme.defaultKey

    var body: some View {
        let accent = AppTheme.accent(accentRaw)
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: .medium))
            .frame(width: 28, height: 28)
            .foregroundStyle(active ? ToshShape(.white) : ToshStyle.secondary)
            .background(active ? ToshShape(accent.opacity(0.88)) : ToshShape(.clear), in: Circle())
            .glassSurface(in: Circle(), tint: active ? accent : nil, interactive: true)
            .overlay(Circle().strokeBorder(.primary.opacity(0.07)))
            .contentShape(Circle())
            .accessibilityLabel(title)
    }
}
