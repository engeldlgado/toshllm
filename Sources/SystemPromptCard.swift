import SwiftUI

struct SystemPromptCard: View {
    let prompt: String
    let edit: () -> Void
    @EnvironmentObject private var loc: Localizer
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(loc.t("Sistema", "System"), systemImage: "text.bubble.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(loc.t("Editar", "Edit"), systemImage: "pencil", action: edit)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            Text(prompt)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 4)
                .textSelection(.enabled)
            if prompt.count > 240 {
                Button(expanded ? loc.t("Mostrar menos", "Show less")
                       : loc.t("Mostrar completo", "Show full")) { expanded.toggle() }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}
