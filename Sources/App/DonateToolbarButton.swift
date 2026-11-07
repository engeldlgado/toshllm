// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Toolbar shortcut to the same donation popover the About tab shows: a heart that now
/// and then spells out its label, so it is noticed without taking the space all the time.
struct DonateToolbarButton: View {
    @EnvironmentObject private var loc: Localizer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presented = false
    @State private var hovering = false
    @State private var announcing = false

    private var expanded: Bool { hovering || announcing || presented }

    var body: some View {
        // The toolbar re-hosts an item whose size changes, which dismisses its popover,
        // so the label unfolds inside a fixed width.
        HStack {
            Spacer(minLength: 0)
            Button { presented = true } label: {
                HStack(spacing: 6) {
                    if expanded {
                        Text(loc.t("Donar", "Donate"))
                            .font(.system(size: 12, weight: .semibold))
                            .fixedSize()
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                    Image(systemName: "heart.fill")
                        .foregroundStyle(Color.appAccent)
                        .scaleEffect(hovering ? 1.15 : 1)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(.quaternary.opacity(expanded ? 1 : 0.6), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc.t("Donar", "Donate"))
            .help(loc.t("Apoya el desarrollo de ToshLLM", "Support ToshLLM development"))
            .onHover { inside in animate { hovering = inside } }
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                DonateView().environmentObject(loc)
            }
        }
        .frame(width: 96, height: 28)
        .task { await announce() }
    }

    private func announce() async {
        try? await Task.sleep(for: .seconds(2))
        while !Task.isCancelled {
            animate { announcing = true }
            try? await Task.sleep(for: .seconds(4))
            animate { announcing = false }
            try? await Task.sleep(nanoseconds: UInt64(Int.random(in: 180...480)) * 1_000_000_000)
        }
    }

    private func animate(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25), change)
    }
}
