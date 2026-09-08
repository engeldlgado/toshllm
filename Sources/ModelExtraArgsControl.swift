import SwiftUI

/// Per-model CLI arguments. They are appended after the shared field in Settings, so a model
/// can override a flag that one also sets.
struct ModelExtraArgsControl: View {
    let modelPath: String

    @EnvironmentObject var loc: Localizer
    @State private var text = ""

    var body: some View {
        TextField(loc.t("Argumentos", "Arguments"),
                  text: $text,
                  prompt: Text(verbatim: "-md /path/head.gguf --spec-type draft-mtp"))
            .workspaceTextField()
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
            .accessibilityLabel(loc.t("Argumentos extra para este modelo",
                                      "Extra arguments for this model"))
            .help(loc.t("Se añaden a los argumentos extra de Ajustes, y ganan sobre ellos. Se aplican solo a este modelo.",
                        "Added after the extra arguments in Settings, and win over them. They apply to this model only."))
            .task(id: modelPath) { text = ServerSettings.extraArgs(forModel: modelPath) }
            .onChange(of: text) { _, new in
                ServerSettings.setExtraArgs(new, forModel: modelPath)
            }
    }
}
