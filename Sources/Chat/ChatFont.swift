// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Chat text size. macOS ignores `.dynamicTypeSize()`, so the scale is ours; the
/// sizes below are what the semantic styles resolve to at 1.0.
enum ChatFont {
    static let range = 0.8...2.0
    static let step = 0.1

    enum Base {
        case body, code, small, heading1, heading2, heading3

        var points: CGFloat {
            switch self {
            case .body, .code, .heading3: return 13
            case .small: return 10
            case .heading1: return 17
            case .heading2: return 15
            }
        }
    }

    static func clamp(_ scale: Double) -> Double {
        min(max(scale, range.lowerBound), range.upperBound)
    }
}

private struct ChatFontScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

extension EnvironmentValues {
    var chatFontScale: Double {
        get { self[ChatFontScaleKey.self] }
        set { self[ChatFontScaleKey.self] = newValue }
    }
}

extension View {
    /// Chat text at the reader's size. Chrome (headers, badges, buttons) keeps
    /// the system size on purpose: only what is read grows.
    func chatFont(_ base: ChatFont.Base, weight: Font.Weight = .regular,
                  design: Font.Design = .default) -> some View {
        modifier(ChatFontModifier(base: base, weight: weight, design: design))
    }
}

private struct ChatFontModifier: ViewModifier {
    let base: ChatFont.Base
    let weight: Font.Weight
    let design: Font.Design
    @Environment(\.chatFontScale) private var scale

    func body(content: Content) -> some View {
        content.font(.system(size: base.points * scale, weight: weight, design: design))
    }
}
