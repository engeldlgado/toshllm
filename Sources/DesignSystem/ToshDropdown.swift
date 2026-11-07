// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A consistent dropdown for dense configuration screens. Its popover uses a
/// lazy stack so large model libraries do not build every option at once.
struct ToshDropdown<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        var subtitle: String? = nil
        var systemImage: String? = nil
        var swatch: NSImage? = nil
        var id: Value { value }
    }

    @Binding var selection: Value
    let options: [Option]
    var placeholder = "Select"
    /// nil fills the width offered by the parent.
    var width: CGFloat? = 270
    var maximumListHeight: CGFloat = 330
    var listWidth: CGFloat? = nil

    @State private var presented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    private var selected: Option? { options.first { $0.value == selection } }

    var body: some View {
        Button { presented.toggle() } label: { triggerLabel }
            .buttonStyle(.plain)
            .popover(isPresented: $presented, arrowEdge: .bottom) { optionList }
            .accessibilityValue(selected?.title ?? placeholder)
    }

    // The trigger and the list are split out of body: as one expression the dropdown
    // is more than Swift 5.7 can type-check in reasonable time.
    @ViewBuilder private var triggerLabel: some View {
        HStack(spacing: 9) {
            if let swatch = selected?.swatch {
                Image(nsImage: swatch)
            } else if let image = selected?.systemImage {
                Image(systemName: image).foregroundStyle(.secondary).frame(width: 16)
            }
            Text(selected?.title ?? placeholder)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .frame(width: width, height: 34)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background(WorkspaceStyle.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(WorkspaceStyle.border))
        // a plain button keeps its look when disabled; a locked choice must not look open
        .opacity(isEnabled ? 1 : 0.5)
    }

    @ViewBuilder private var optionList: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(options) { option in optionRow(option) }
            }
            .padding(6)
        }
        // The list is its own container: without this it inherits a smaller
        // control size from rows that shrink their controls.
        .controlSize(.regular)
        .font(.body)
        .frame(width: listWidth ?? max(width ?? 250, 250),
               height: min(max(CGFloat(options.count) * 39 + 12, 56), maximumListHeight))
        .background(WorkspaceStyle.surface)
        .presentationCornerRadius(6)
    }

    @ViewBuilder private func optionRow(_ option: Option) -> some View {
        Button { choose(option.value) } label: {
            HStack(spacing: 10) {
                if let swatch = option.swatch {
                    Image(nsImage: swatch).frame(width: 18)
                } else if let image = option.systemImage {
                    Image(systemName: image).foregroundStyle(.secondary).frame(width: 18)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title).lineLimit(1)
                    if let subtitle = option.subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                if option.value == selection {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold)).foregroundStyle(Color.appAccent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, option.subtitle == nil ? 8 : 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(option.value == selection ? Color.appAccent.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func choose(_ value: Value) {
        if reduceMotion {
            selection = value
            presented = false
        } else {
            withAnimation(.snappy(duration: 0.16)) {
                selection = value
                presented = false
            }
        }
    }
}
