// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Keeps search and filters on one line while there is room, then promotes the
/// search field to its own row so filter chips receive the full content width.
struct ModelSearchAndFilters<Filters: View>: View {
    let placeholder: String
    @Binding var text: String
    @ViewBuilder let filters: Filters

    var body: some View {
        ToshAdaptive(minWidth: 850) {
            HStack(spacing: 14) {
                GlassSearchField(placeholder: placeholder, text: $text).frame(width: 310)
                filters
            }
            .frame(minWidth: 850, alignment: .leading)
        } narrow: {
            VStack(alignment: .leading, spacing: 9) {
                GlassSearchField(placeholder: placeholder, text: $text)
                    .frame(maxWidth: .infinity)
                filters
            }
        }
    }
}

/// Compact destination navigation for the three model workflows. Subtitles
/// remain available as help text without consuming a second row of content.
struct ModelSectionSwitcher<Value: Hashable>: View {
    struct Item: Identifiable {
        let value: Value
        let title: String
        let subtitle: String
        let systemImage: String
        var badge: String?
        var id: Value { value }
    }

    @Binding var selection: Value
    let items: [Item]
    @Namespace private var selectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            ForEach(items) { item in
                let selected = selection == item.value
                Button { select(item.value) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: item.systemImage)
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: 13, weight: .medium))
                        Text(item.title).font(.system(size: 12, weight: selected ? .semibold : .medium))
                        if let badge = item.badge {
                            Text(badge).font(.system(size: 9, weight: .bold, design: .rounded))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(selected ? Color.white.opacity(0.16) : Color.appAccent.opacity(0.13),
                                            in: Capsule())
                            }
                    }
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .background {
                        if selected {
                            Capsule().fill(Color.appAccent)
                                .matchedGeometryEffect(id: "model-section", in: selectionNamespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(item.subtitle)
            }
        }
        .padding(3)
        .fixedSize()
        .background(WorkspaceStyle.inset.opacity(0.78), in: Capsule())
        .overlay(Capsule().strokeBorder(WorkspaceStyle.border))
    }

    private func select(_ value: Value) {
        if reduceMotion { selection = value }
        else { withAnimation(.snappy(duration: 0.24)) { selection = value } }
    }
}

/// Compact, horizontally scrolling chips for refining a model list.
struct ModelFilterBar<Value: Hashable>: View {
    struct Filter: Identifiable {
        let value: Value
        let title: String
        let systemImage: String
        var count: Int?
        var id: Value { value }
    }

    @Binding var selection: Value
    let filters: [Filter]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ToshFlowLayout(spacing: 7) {
            ForEach(filters) { filter in
                let selected = selection == filter.value
                Button { select(filter.value) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: filter.systemImage).symbolRenderingMode(.hierarchical)
                        Text(filter.title)
                        if let count = filter.count {
                            Text("\(count)")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                        }
                    }
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .lineLimit(1).fixedSize()
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(selected ? Color.appAccent : WorkspaceStyle.inset,
                                in: Capsule())
                    .overlay(Capsule().strokeBorder(selected ? Color.clear : WorkspaceStyle.border))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func select(_ value: Value) {
        if reduceMotion { selection = value }
        else { withAnimation(.easeOut(duration: 0.16)) { selection = value } }
    }
}
