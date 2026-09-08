// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// MARK: - Liquid Glass with fallback

/// macOS 26 (Tahoe) "Liquid Glass" surfaces, degrading to translucent
/// materials on macOS 14–15 — and, importantly, when built with an SDK older
/// than macOS 26 (e.g. CI runners). `#available` is only a *runtime* check; it
/// does not help if the build SDK lacks `glassEffect`/`Glass` symbols at all,
/// so the new API is additionally gated behind `#if compiler(>=6.2) && !TOSH_LEGACY_UI` — the
/// toolchain that ships the macOS 26 SDK. Reserve `glassSurface` for floating,
/// interactive controls (composer, jump-to-bottom button); applying it to
/// every message bubble would stack many GPU-backed blurs and hurt scrolling.
extension View {
    func glassSurface(in shape: some InsettableShape, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive))
    }
}

/// Reading the accessibility environment needs a modifier, not a plain View
/// extension: with "Reduce transparency" or "Increase contrast" on, a blurred
/// surface over content is exactly what the user asked the system to remove.
private struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(tint.map { AnyShapeStyle($0.opacity(0.28)) } ?? AnyShapeStyle(.clear),
                            in: shape)
                .background(.background, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.45 : 0.18)))
        } else {
            #if compiler(>=6.2) && !TOSH_LEGACY_UI
            if #available(macOS 26.0, *) {
                content.glassEffect(makeToshGlass(tint: tint, interactive: interactive), in: shape)
            } else {
                materialSurface(content)
            }
            #else
            materialSurface(content)
            #endif
        }
    }

    private func materialSurface(_ content: Content) -> some View {
        content.background(tint.map { AnyShapeStyle($0.opacity(0.18)) } ?? AnyShapeStyle(.regularMaterial),
                           in: shape)
    }
}

#if compiler(>=6.2) && !TOSH_LEGACY_UI
@available(macOS 26.0, *)
private func makeToshGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass: Glass = .regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}
#endif

// MARK: - App accent theme

/// Brand accent, user-selectable in Settings; deliberately independent from
/// the system accent so a green/blue user accent never clashes with the UI.
enum AppTheme {
    static let defaultKey = "pink"

    static let palette: [(key: String, color: Color)] = [
        ("pink", .pink), ("blue", .blue), ("purple", .purple), ("indigo", .indigo),
        ("teal", .teal), ("green", .green), ("orange", .orange), ("red", .red),
        ("system", Color(nsColor: .controlAccentColor)),
    ]

    static func accent(_ raw: String) -> Color {
        palette.first { $0.key == raw }?.color ?? .pink
    }

    /// Contrast partner for two-series charts: warm accents pair with blue,
    /// cool ones with orange, so both bars stay apart under any theme.
    static func chartSecondary(_ raw: String) -> Color {
        switch raw {
        case "pink", "red", "orange": return .blue
        case "system":
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            NSColor.controlAccentColor.usingColorSpace(.deviceRGB)?
                .getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            let warm = h < 0.17 || h > 0.83
            return (warm || s < 0.2) ? .blue : .orange
        default: return .orange
        }
    }

    /// Menu-safe color dot: NSMenu templates SF symbols and drops their
    /// foreground color, so swatches must be non-template bitmap images.
    static func swatchImage(_ color: Color, size: CGFloat = 12) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    static func label(_ raw: String, _ loc: Localizer) -> String {
        switch raw {
        case "pink": return loc.t("Rosa", "Pink")
        case "blue": return loc.t("Azul", "Blue")
        case "purple": return loc.t("Púrpura", "Purple")
        case "indigo": return loc.t("Índigo", "Indigo")
        case "teal": return loc.t("Turquesa", "Teal")
        case "green": return loc.t("Verde", "Green")
        case "orange": return loc.t("Naranja", "Orange")
        case "red": return loc.t("Rojo", "Red")
        case "system": return loc.t("Sistema", "System")
        default: return raw
        }
    }
}

extension Color {
    /// Theme accent for static contexts; the window-level tint re-render
    /// keeps every read fresh when the setting changes.
    static var appAccent: Color {
        AppTheme.accent(UserDefaults.standard.string(forKey: SettingsKeys.appAccent) ?? AppTheme.defaultKey)
    }

    /// Second chart series, always distinguishable from the accent.
    static var chartSecondary: Color {
        AppTheme.chartSecondary(UserDefaults.standard.string(forKey: SettingsKeys.appAccent) ?? AppTheme.defaultKey)
    }
}

// MARK: - Buttons in the macOS 26 idiom (capsules and circles over glass)

/// Reusable action button matching the compact rounded controls used throughout
/// the workspace. Its dimensions do not collapse when a parent becomes narrow.
struct GlassPillButtonStyle: ButtonStyle {
    var prominent = false
    @AppStorage(SettingsKeys.appAccent) private var accentRaw = AppTheme.defaultKey
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let accent = AppTheme.accent(accentRaw)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 13)
            .frame(minHeight: 30)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(prominent ? AnyShapeStyle(accent.opacity(0.90)) : AnyShapeStyle(WorkspaceStyle.inset),
                        in: shape)
            .glassSurface(in: shape, tint: prominent ? accent : nil, interactive: true)
            .overlay(shape.strokeBorder(prominent ? Color.white.opacity(0.10) : WorkspaceStyle.border))
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Small round icon button over glass; `active` tints it with the app accent.
struct GlassIconButtonStyle: ButtonStyle {
    var active = false
    @AppStorage(SettingsKeys.appAccent) private var accentRaw = AppTheme.defaultKey
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let accent = AppTheme.accent(accentRaw)
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(width: 28, height: 28)
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .background(active ? AnyShapeStyle(accent.opacity(0.88)) : AnyShapeStyle(.clear), in: Circle())
            .glassSurface(in: Circle(), tint: active ? accent : nil, interactive: true)
            .overlay(Circle().strokeBorder(.primary.opacity(0.07)))
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.94 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Capsule search field over glass.
struct GlassSearchField: View {
    let placeholder: String
    @Binding var text: String
    @EnvironmentObject private var loc: Localizer

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .iconHelp(loc.t("Borrar la búsqueda", "Clear the search"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassSurface(in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.07)))
    }
}

// MARK: - Accessibility

extension View {
    /// Tooltip that a screen reader can also announce. An icon-only control is
    /// read as just "button" otherwise, so use this wherever there is no text.
    func iconHelp(_ text: String) -> some View {
        help(text).accessibilityLabel(text)
    }
}

// MARK: - Toolbar symbols

extension View {
    /// Spins a toolbar symbol in place. Swapping the item for a `ProgressView`
    /// rebuilds it and splits the shared glass background of the toolbar group.
    @ViewBuilder
    func spinningSymbol(_ active: Bool) -> some View {
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) {
            self.symbolEffect(.rotate, options: .repeating, isActive: active)
        } else {
            self.symbolEffect(.pulse, options: .repeating, isActive: active)
        }
        #else
        self.symbolEffect(.pulse, options: .repeating, isActive: active)
        #endif
    }
}

// MARK: - Cards and controls in the macOS 26 idiom

enum CardMetrics {
    static let corner: CGFloat = 12
    static let padding: CGFloat = 14
    static let spacing: CGFloat = 8
    static let minWidth: CGFloat = 320
}

extension View {
    /// Static cards stay opaque. They update while tokens and telemetry stream,
    /// so turning every card into a GPU-backed blur wastes rendering work.
    func cardSurface(tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: CardMetrics.corner)
        return background(tint.map { AnyShapeStyle($0.opacity(0.10)) }
                          ?? AnyShapeStyle(WorkspaceStyle.surface), in: shape)
            .overlay(shape.strokeBorder(tint?.opacity(0.35) ?? WorkspaceStyle.border))
    }

    /// The one button identity in the app: same shape everywhere, tinted with the
    /// accent chosen in Settings.
    func glassButton(prominent: Bool = false) -> some View {
        buttonStyle(GlassPillButtonStyle(prominent: prominent))
    }
}
