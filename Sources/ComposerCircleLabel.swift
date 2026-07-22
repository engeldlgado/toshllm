import SwiftUI

struct ComposerCircleLabel: View {
    let title: String
    let systemImage: String
    var active = false
    @AppStorage(SettingsKeys.appAccent) private var accentRaw = AppTheme.defaultKey

    var body: some View {
        let accent = AppTheme.accent(accentRaw)
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: .medium))
            .frame(width: 28, height: 28)
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .background(active ? AnyShapeStyle(accent.opacity(0.88)) : AnyShapeStyle(.clear), in: Circle())
            .glassSurface(in: Circle(), tint: active ? accent : nil, interactive: true)
            .overlay(Circle().strokeBorder(.primary.opacity(0.07)))
            .contentShape(Circle())
            .accessibilityLabel(title)
    }
}
