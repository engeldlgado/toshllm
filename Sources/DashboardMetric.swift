// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct DashboardMetric: View {
    let title: String
    let icon: String
    let value: String
    let detail: String
    var progress: Double? = nil
    var history: [Double] = []
    var historyCeiling: Double? = nil
    var tint: Color = .appAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon)
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 27, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
            if history.count > 1 {
                DashboardSparkline(values: history, ceiling: historyCeiling, tint: tint)
                    .frame(height: 22)
            } else if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(tint)
            }
            Text(detail)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true).help(detail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .frame(height: 138)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }
}

/// Tiny telemetry graph rendered in one Canvas. It has no axes, plot objects or
/// animation timeline, which keeps five live dashboard cards inexpensive.
private struct DashboardSparkline: View {
    let values: [Double]
    let ceiling: Double?
    let tint: Color

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            guard values.count > 1, size.width > 0, size.height > 0 else { return }
            let low = ceiling == nil ? (values.min() ?? 0) : 0
            let high = max(ceiling ?? (values.max() ?? 1), low + 0.001)
            let points = values.enumerated().map { index, value in
                CGPoint(x: size.width * CGFloat(index) / CGFloat(values.count - 1),
                        y: size.height * (1 - CGFloat((value - low) / (high - low))))
            }
            let curve = smoothPath(through: points, height: size.height)
            var area = curve
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(tint.opacity(0.13)))
            context.stroke(curve, with: .color(tint), style: StrokeStyle(lineWidth: 1.5,
                                                                          lineCap: .round,
                                                                          lineJoin: .round))
        }
        .accessibilityHidden(true)
    }

    /// Catmull-Rom converted to cubic Bézier segments. This keeps the same
    /// tiny sample buffer as the straight plot and only changes how Canvas
    /// joins adjacent points.
    private func smoothPath(through points: [CGPoint], height: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }

        for index in 0..<(points.count - 1) {
            let previous = index > 0 ? points[index - 1] : points[index]
            let current = points[index]
            let next = points[index + 1]
            let following = index + 2 < points.count ? points[index + 2] : next
            let control1 = CGPoint(
                x: current.x + (next.x - previous.x) / 6,
                y: min(max(current.y + (next.y - previous.y) / 6, 0), height)
            )
            let control2 = CGPoint(
                x: next.x - (following.x - current.x) / 6,
                y: min(max(next.y - (following.y - current.y) / 6, 0), height)
            )
            path.addCurve(to: next, control1: control1, control2: control2)
        }
        return path
    }
}
