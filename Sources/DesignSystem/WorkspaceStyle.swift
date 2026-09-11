// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Neutral surfaces independent of wallpaper tinting and the system accent.
enum WorkspaceStyle {
    static let canvas = adaptive(light: 0xF5F5F8, dark: 0x131315)
    static let sidebar = adaptive(light: 0xEEEEF3, dark: 0x19181C)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x201F24)
    static let inset = adaptive(light: 0xF0EFF5, dark: 0x28262D)
    static let border = adaptive(light: 0xDEDCE5, dark: 0x343139)
    static let field = adaptive(light: 0xF7F7FA, dark: 0x26252A)

    private static func adaptive(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
}

private struct WorkspaceTextFieldModifier: ViewModifier {
    let width: CGFloat?

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(width: width, height: 34)
            .background(WorkspaceStyle.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(WorkspaceStyle.border, lineWidth: 1))
    }
}

extension View {
    /// Neutral field surface that is not tinted by the window material.
    func workspaceTextField(width: CGFloat? = nil) -> some View {
        modifier(WorkspaceTextFieldModifier(width: width))
    }

    /// Neutral surface for multiline fields whose height is controlled by their content.
    func workspaceFieldSurface(cornerRadius: CGFloat = 8) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(WorkspaceStyle.field,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(WorkspaceStyle.border, lineWidth: 1))
    }
}
