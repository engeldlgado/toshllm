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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                GlassSearchField(placeholder: placeholder, text: $text).frame(width: 310)
                filters
            }
            .frame(minWidth: 850, alignment: .leading)

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
        WrappingFilterLayout(spacing: 7) {
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

/// A lightweight flow layout for short filter bars. It measures only the
/// handful of visible chips and wraps complete controls instead of clipping
/// labels or requiring horizontal scrolling in narrow windows.
private struct WrappingFilterLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                     cache: inout ()) -> CGSize {
        let rows = arrangement(width: proposal.width ?? .greatestFiniteMagnitude, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let rows = arrangement(width: bounds.width, subviews: subviews)
        var index = 0
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for _ in 0..<row.count {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y),
                                      anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
            y += row.height + spacing
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextWidth = row.count == 0 ? size.width : row.width + spacing + size.width
            if row.count > 0 && nextWidth > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.count == 0 ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.count += 1
        }
        if row.count > 0 { rows.append(row) }
        return rows
    }

    private struct Row {
        var width: CGFloat = 0
        var height: CGFloat = 0
        var count = 0
    }
}
