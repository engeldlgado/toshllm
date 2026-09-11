// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// How burned-in subtitles look. Sizes are fractions of the frame height so one
/// setting reads the same on a 720p clip and a 4K one.
struct SubtitleStyle: Codable, Equatable {
    enum Background: String, Codable, CaseIterable, Identifiable, Hashable {
        case box, outline, none
        var id: String { rawValue }
    }

    enum Position: String, Codable, CaseIterable, Identifiable, Hashable {
        case bottom, top
        var id: String { rawValue }
    }

    var fontName = "Helvetica-Bold"
    var relativeSize = 0.038
    var textColor = RGBA(r: 1, g: 1, b: 1, a: 1)
    var background = Background.box
    var backgroundOpacity = 0.72
    var position = Position.bottom
    /// Fraction of the frame height between the text and its edge.
    var margin = 0.06
    /// Fraction of the frame width the text may occupy.
    var maxWidth = 0.86
    /// Floor for the shrink-to-fit, also a fraction of the height: an absolute
    /// point size would mean something different on a still than on the video.
    var minRelativeSize = 0.012

    static let `default` = SubtitleStyle()

    struct RGBA: Codable, Equatable {
        var r, g, b, a: Double
        var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
        var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

        init(r: Double, g: Double, b: Double, a: Double) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }

        init(_ color: Color) {
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
            self.init(r: ns.redComponent, g: ns.greenComponent,
                      b: ns.blueComponent, a: ns.alphaComponent)
        }
    }

    // MARK: persistence

    static func load() -> SubtitleStyle {
        guard let data = UserDefaults.standard.data(forKey: SettingsKeys.subtitleStyle),
              let style = try? JSONDecoder().decode(SubtitleStyle.self, from: data) else {
            return .default
        }
        return style
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: SettingsKeys.subtitleStyle)
    }

    /// Faces that ship with macOS and read well over moving pictures.
    static let fontChoices: [(name: String, label: String)] = [
        ("Helvetica-Bold", "Helvetica Bold"),
        ("HelveticaNeue-Medium", "Helvetica Neue"),
        ("Avenir-Heavy", "Avenir Heavy"),
        ("ArialRoundedMTBold", "Arial Rounded"),
        ("Georgia-Bold", "Georgia Bold"),
        ("Menlo-Bold", "Menlo Bold"),
    ]
}
