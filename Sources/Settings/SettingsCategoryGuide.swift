// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// One highlight in the guide panel.
struct SettingsGuideItem: Identifiable {
    let icon: String
    let title: String
    let detail: String
    var id: String { title }
}

/// What the guide panel shows for a category.
struct SettingsGuideContent {
    let icon: String
    let title: String
    let detail: String
    let note: String
    var items: [SettingsGuideItem] = []
}

/// The panel beside a settings form. It is its own view so the artwork and the
/// copy are not rebuilt every time an unrelated setting changes.
struct SettingsCategoryGuide: View {
    let content: SettingsGuideContent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {

        ZStack {
            SettingsGuideArtwork()
            LinearGradient(colors: guideGradientColors,
                           startPoint: .topTrailing, endPoint: .bottomLeading)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: content.icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 44, height: 44)
                    .background(Color.appAccent.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.appAccent.opacity(0.22)))
                VStack(alignment: .leading, spacing: 7) {
                    Text(content.title).font(.title2.weight(.bold))
                    Text(content.detail)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 13) {
                    ForEach(content.items) { item in
                        HStack(alignment: .center, spacing: 11) {
                            Image(systemName: item.icon)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.appAccent)
                                .frame(width: 32, height: 32)
                                .background(Color.appAccent.opacity(0.11),
                                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.callout.weight(.semibold))
                                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Spacer(minLength: 8)
                Label(content.note, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(noteBackground,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(WorkspaceStyle.border.opacity(0.8)))
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    private var guideGradientColors: [Color] {
        if colorScheme == .light {
            return [Color.white.opacity(0.02),
                    Color.white.opacity(0.32),
                    WorkspaceStyle.surface.opacity(0.96)]
        }
        return [Color.black.opacity(0.18),
                Color.black.opacity(0.58),
                WorkspaceStyle.surface.opacity(0.94)]
    }

    private var noteBackground: Color {
        colorScheme == .light ? Color.white.opacity(0.64) : Color.black.opacity(0.16)
    }
}
