import SwiftUI

struct ChatSettingsDisclosureGroup<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title).bold()
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                content
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: isExpanded)
    }

    private func toggle() {
        isExpanded.toggle()
    }
}
