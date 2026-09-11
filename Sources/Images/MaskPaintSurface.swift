// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

/// The painting surface, split off so a drag redraws only this and not the
/// whole sheet.
struct MaskPaintSurface: View {
    let image: NSImage?
    let pixelSize: CGSize
    @Binding var strokes: [MaskStroke]
    let radius: Double
    let erasing: Bool
    let maskOnly: Bool

    @State private var current: MaskStroke? = nil
    @State private var hover: CGPoint? = nil

    /// Points closer than this add nothing to a round-capped stroke and cost a
    /// redraw each, in fractions of the image width.
    private static let minStep = 0.004

    var body: some View {
        GeometryReader { geo in
            let rect = MaskEditorView.fitRect(pixelSize, in: geo.size)
            ZStack {
                background(rect)
                Canvas { ctx, _ in
                    ctx.clip(to: Path(rect))
                    // Erasing has to cut out of the accumulated strokes, so they
                    // are composited in their own layer first.
                    ctx.drawLayer { layer in
                        for stroke in strokes { draw(stroke, in: rect, into: &layer) }
                        if let current { draw(current, in: rect, into: &layer) }
                    }
                }
                .opacity(maskOnly ? 1 : 0.5)
                .allowsHitTesting(false)
                brushRing(in: rect)
                Rectangle().stroke(.quaternary)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
            .contentShape(Rectangle())
            .gesture(drag(in: rect))
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = rect.contains(p) ? p : nil
                case .ended: hover = nil
                }
            }
            .onHover { inside in
                // The pointer is the only thing telling you which tool is armed.
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
        }
    }

    /// The exact brush footprint, so the size slider means something before the
    /// first stroke. Dashed while erasing.
    @ViewBuilder
    private func brushRing(in rect: CGRect) -> some View {
        if let hover {
            let d = radius * 2 * rect.width
            Circle()
                .strokeBorder(erasing ? Color.orange : Color.white,
                              style: StrokeStyle(lineWidth: 1.5,
                                                 dash: erasing ? [4, 3] : []))
                .background(Circle().fill(.black.opacity(0.15)))
                .frame(width: d, height: d)
                .position(hover)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func background(_ rect: CGRect) -> some View {
        if let image, !maskOnly {
            Image(nsImage: image)
                .resizable().interpolation(.medium)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        } else {
            Rectangle().fill(.black)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    private func drag(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                // onContinuousHover goes quiet while the button is down, so the
                // ring has to track the drag itself, before any point is dropped.
                hover = rect.contains(v.location) ? v.location : nil
                let p = MaskEditorView.normalise(v.location, in: rect)
                guard var stroke = current else {
                    current = MaskStroke(points: [p], radius: radius, erases: erasing)
                    return
                }
                if let last = stroke.points.last, hypot(p.x - last.x, p.y - last.y) < Self.minStep {
                    return
                }
                stroke.points.append(p)
                current = stroke
            }
            .onEnded { _ in
                if let c = current { strokes.append(c) }
                current = nil
            }
    }

    private func draw(_ stroke: MaskStroke, in rect: CGRect, into ctx: inout GraphicsContext) {
        ctx.blendMode = stroke.erases ? .destinationOut : .normal
        ctx.stroke(MaskEditorView.path(for: stroke, in: rect),
                   with: .color(.white),
                   style: StrokeStyle(lineWidth: stroke.radius * 2 * rect.width,
                                      lineCap: .round, lineJoin: .round))
    }
}
