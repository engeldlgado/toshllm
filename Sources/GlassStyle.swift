import SwiftUI

// MARK: - Liquid Glass with fallback

/// macOS 26 (Tahoe) "Liquid Glass" surfaces, degrading to translucent
/// materials on macOS 14–15. Lets the chat adopt the system look on Tahoe —
/// matching the configuration window — while still building and running on
/// earlier releases. Reserve `glassSurface` for floating, interactive controls
/// (the composer, the jump-to-bottom button); applying it to every message
/// bubble would stack many GPU-backed blurs and hurt scrolling on AMD GPUs.
extension View {
    @ViewBuilder
    func glassSurface(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(makeToshGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(
                tint.map { AnyShapeStyle($0.opacity(0.18)) } ?? AnyShapeStyle(.regularMaterial),
                in: shape)
        }
    }
}

@available(macOS 26.0, *)
private func makeToshGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass: Glass = .regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}
