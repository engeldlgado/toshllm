// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Segmented control in the app's own idiom: a glass track with the selection
/// sliding behind the labels, instead of the stock segmented picker.
struct GlassSegmentedControl<Value: Hashable>: View {
    struct Segment: Identifiable {
        let value: Value
        let title: String
        var systemImage: String?
        var id: Value { value }
    }

    @Binding var selection: Value
    let segments: [Segment]
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SettingsKeys.appAccent) private var accentRaw = AppTheme.defaultKey

    var body: some View {
        let accent = AppTheme.accent(accentRaw)
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                let selected = segment.value == selection
                Button {
                    select(segment.value)
                } label: {
                    label(for: segment)
                        .font(.callout)
                        .foregroundStyle(selected ? ToshStyle.primary : ToshStyle.secondary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 5)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(accent.opacity(0.20))
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .glassSurface(in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.07)))
        .fixedSize()
        // The pill animates here, not around the binding: animating the write puts whatever the
        // selection swaps into the same transaction, and a page that changes size inside it can
        // keep asking the window for another constraints pass until macOS 15 gives up (#97).
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: selection)
    }

    @ViewBuilder
    private func label(for segment: Segment) -> some View {
        if let image = segment.systemImage {
            Label(segment.title, systemImage: image)
        } else {
            Text(segment.title)
        }
    }

    private func select(_ value: Value) {
        selection = value
    }
}
