import SwiftUI

/// Per-model DFlash policy, shown only when a compatible downloaded draft exists.
struct DflashControl: View {
    let modelPath: String
    var switchLeading: Bool = false
    @EnvironmentObject var loc: Localizer
    @State private var mode: DflashMode = .auto

    var body: some View {
        HStack(spacing: 8) {
            Label("DFlash", systemImage: "bolt.fill")
                .font(.caption).foregroundStyle(mode == .off ? Color.secondary : Color.orange)
            Picker("DFlash", selection: $mode) {
                Text(loc.t("Off", "Off")).tag(DflashMode.off)
                Text(loc.t("Auto", "Auto")).tag(DflashMode.auto)
                Text(loc.t("Forzado", "Forced")).tag(DflashMode.forced)
            }
            .labelsHidden()
            .fixedSize()
        }
        .onAppear { mode = ServerSettings.dflashMode(forModel: modelPath) }
        .onChange(of: mode) { _, value in ServerSettings.setDflashMode(value, forModel: modelPath) }
        .help(loc.t("Auto solo usa DFlash en modelos MoE con expertos en CPU y memoria suficiente. Forzado también lo intenta con ncmoe=0, donde puede ser más lento, y avisa si la VRAM supera 95 %.",
                    "Auto only uses DFlash for MoE models with CPU-offloaded experts and enough memory. Forced also tries it with ncmoe=0, where it may be slower, and warns if VRAM exceeds 95%."))
    }
}
