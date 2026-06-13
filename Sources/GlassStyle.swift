import SwiftUI

// MARK: - Liquid Glass with fallback

/// macOS 26 (Tahoe) "Liquid Glass" surfaces, degrading to translucent
/// materials on macOS 14–15 — and, importantly, when built with an SDK older
/// than macOS 26 (e.g. CI runners). `#available` is only a *runtime* check; it
/// does not help if the build SDK lacks `glassEffect`/`Glass` symbols at all,
/// so the new API is additionally gated behind `#if compiler(>=6.2)` — the
/// toolchain that ships the macOS 26 SDK. Reserve `glassSurface` for floating,
/// interactive controls (composer, jump-to-bottom button); applying it to
/// every message bubble would stack many GPU-backed blurs and hurt scrolling.
extension View {
    @ViewBuilder
    func glassSurface(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(makeToshGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            materialSurface(in: shape, tint: tint)
        }
        #else
        materialSurface(in: shape, tint: tint)
        #endif
    }

    @ViewBuilder
    private func materialSurface(in shape: some Shape, tint: Color?) -> some View {
        self.background(
            tint.map { AnyShapeStyle($0.opacity(0.18)) } ?? AnyShapeStyle(.regularMaterial),
            in: shape)
    }
}

#if compiler(>=6.2)
@available(macOS 26.0, *)
private func makeToshGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass: Glass = .regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}
#endif
