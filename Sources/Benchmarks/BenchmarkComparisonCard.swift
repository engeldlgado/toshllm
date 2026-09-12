// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Two runs side by side. A view of its own, so the rest of the Benchmarks screen
/// invalidating does not rebuild it.
struct BenchmarkComparisonCard: View, Equatable {
    let history: [BenchResult]
    @EnvironmentObject private var loc: Localizer
    @State private var runA: UUID?
    @State private var runB: UUID?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.history.map(\.id) == rhs.history.map(\.id)
    }

    private var first: BenchResult? {
        history.first { $0.id == runA } ?? history.first
    }

    private var second: BenchResult? {
        history.first { $0.id == runB } ?? history.dropFirst().first ?? history.first
    }

    var body: some View {
        if history.count < 2 {
            Card(title: loc.t("Comparación", "Comparison"), icon: "arrow.left.arrow.right") {
                ContentUnavailableView(loc.t("Se necesitan dos resultados", "Two results are required"),
                                       systemImage: "chart.bar.xaxis",
                                       description: Text(loc.t("Ejecuta otro benchmark para comparar.",
                                                               "Run another benchmark to compare.")))
                    .frame(height: 150)
            }
        } else if let first, let second {
            Card(title: loc.t("Comparar ejecuciones", "Compare runs"), icon: "arrow.left.arrow.right") {
                VStack(spacing: 16) {
                    let options = history.map { result in
                        ToshDropdown<UUID?>.Option(value: result.id,
                                                   title: "\(result.shortModel) · \(result.quantization)",
                                                   subtitle: result.date.formatted(date: .abbreviated, time: .shortened))
                    }
                    HStack(spacing: 12) {
                        ComparisonRunPicker(title: loc.t("Ejecución A", "Run A"), selection: $runA, options: options)
                        Image(systemName: "arrow.left.arrow.right")
                            .foregroundStyle(.secondary).accessibilityHidden(true)
                        ComparisonRunPicker(title: loc.t("Ejecución B", "Run B"), selection: $runB, options: options)
                    }
                    HStack(spacing: 12) {
                        ComparisonMetric(title: "Prompt", first: first.pp, second: second.pp,
                                         color: Color.chartSecondary)
                        ComparisonMetric(title: loc.t("Generación", "Generation"),
                                         first: first.tg, second: second.tg, color: Color.appAccent)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        ComparisonRunDetails(result: first, label: "A")
                        ComparisonRunDetails(result: second, label: "B")
                    }
                }
            }
            .onAppear(perform: seedSelection)
            .onChange(of: history.count) { seedSelection() }
        }
    }

    private func seedSelection() {
        if !history.contains(where: { $0.id == runA }) { runA = history.first?.id }
        if !history.contains(where: { $0.id == runB }) { runB = history.dropFirst().first?.id ?? history.first?.id }
    }
}

private struct ComparisonRunPicker: View {
    let title: String
    @Binding var selection: UUID?
    let options: [ToshDropdown<UUID?>.Option]
    @EnvironmentObject private var loc: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            // Not a Picker: a native pop-up is as wide as its longest item, and this one lists the whole history.
            ToshDropdown(selection: $selection, options: options, width: nil, listWidth: 420)
                .help(loc.t("Elige la ejecución a comparar", "Choose the run to compare"))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ComparisonMetric: View {
    let title: String
    let first: Double
    let second: Double
    let color: Color

    private var delta: Double { first == 0 ? 0 : ((second - first) / first) * 100 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Label(String(format: "%+.1f%%", delta),
                      systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(delta >= 0 ? Color.green : Color.orange)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("A").font(.caption).foregroundStyle(.secondary)
                Text(String(format: "%.1f", first)).font(.system(size: 25, weight: .bold, design: .rounded))
                Spacer()
                Text("B").font(.caption).foregroundStyle(.secondary)
                Text(String(format: "%.1f", second)).font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text("t/s").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(maxWidth: .infinity)
        .background(WorkspaceStyle.inset.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.22)) }
    }
}

private struct ComparisonRunDetails: View {
    let result: BenchResult
    let label: String
    @EnvironmentObject private var loc: Localizer

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.headline).foregroundStyle(Color.appAccent)
            ModelBrandIcon(name: result.shortModel, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.shortModel).font(.callout.weight(.semibold)).lineLimit(1)
                Text("\(result.quantization) · \(result.configLabel)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(result.gpu ?? loc.t("GPU predeterminada", "Default GPU"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(10).frame(maxWidth: .infinity)
        .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(WorkspaceStyle.border) }
    }
}
