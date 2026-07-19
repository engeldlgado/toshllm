import SwiftUI

/// Per-model DFlash policy, shown only when a compatible downloaded draft exists.
struct DflashControl: View {
    let modelPath: String
    var switchLeading: Bool = false
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var server: ServerController
    @State private var mode: DflashMode = .auto
    @State private var glow = false

    private var active: Bool { server.activeDflashModelPath == modelPath }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(active ? .orange : (mode == .off ? Color.secondary : Color.orange.opacity(0.6)))
                .shadow(color: active ? .orange.opacity(glow ? 0.9 : 0.25) : .clear, radius: active ? (glow ? 6 : 2) : 0)
            Text("DFlash")
                .foregroundStyle(active ? .orange : (mode == .off ? Color.secondary : .primary))
                .fixedSize()
            if active, let acc = server.dflashAcceptance {
                Text(acc.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit().foregroundStyle(.secondary)
                    .help(loc.t("Aceptación del borrador en la última respuesta",
                                "Draft acceptance on the last response"))
            }
            Picker("DFlash", selection: $mode) {
                Text(loc.t("Off", "Off")).tag(DflashMode.off)
                Text(loc.t("Auto", "Auto")).tag(DflashMode.auto)
                Text(loc.t("Forzado", "Forced")).tag(DflashMode.forced)
            }
            .labelsHidden()
            .fixedSize()
        }
        .font(.caption)
        .onAppear {
            mode = ServerSettings.dflashMode(forModel: modelPath)
            glow = active
        }
        .onChange(of: mode) { _, value in ServerSettings.setDflashMode(value, forModel: modelPath) }
        .onChange(of: active) { _, on in
            withAnimation(on ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default) { glow = on }
        }
        .help(loc.t("Auto solo usa DFlash en modelos MoE con expertos en CPU y memoria suficiente. Forzado también lo intenta con ncmoe=0, donde puede ser más lento, y avisa si la VRAM supera 95 %.",
                    "Auto only uses DFlash for MoE models with CPU-offloaded experts and enough memory. Forced also tries it with ncmoe=0, where it may be slower, and warns if VRAM exceeds 95%."))
    }
}
