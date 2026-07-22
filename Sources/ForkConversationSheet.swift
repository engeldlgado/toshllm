import SwiftUI

struct ForkConversationSheet: View {
    let sourceTitle: String
    let confirm: (String?, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var loc: Localizer
    @State private var title = ""
    @State private var includeAttachments = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(loc.t("Bifurcar conversación", "Fork conversation"),
                  systemImage: "arrow.triangle.branch")
                .font(.title2.weight(.semibold))
            Text(loc.t("Crea una conversación independiente hasta este mensaje. La conversación original no cambia.",
                       "Creates an independent conversation through this message. The original conversation is unchanged."))
                .foregroundStyle(.secondary)
            TextField(loc.t("Título (opcional)", "Title (optional)"), text: $title,
                      prompt: Text(loc.t("Bifurcación de \(sourceTitle)", "Fork of \(sourceTitle)")))
                .textFieldStyle(.roundedBorder)
            Toggle(loc.t("Incluir archivos, imágenes, audio y video",
                         "Include files, images, audio and video"),
                   isOn: $includeAttachments)
            HStack {
                Spacer()
                Button(loc.t("Cancelar", "Cancel")) { dismiss() }
                Button(loc.t("Crear bifurcación", "Create fork")) {
                    let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    confirm(value.isEmpty ? nil : value, includeAttachments)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 500)
    }
}
