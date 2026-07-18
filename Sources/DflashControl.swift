import SwiftUI

/// Per-model DFlash (speculative decoding) on/off switch, shown when the model has
/// a downloaded `.dflash.gguf` draft. Off keeps the file but skips the draft.
struct DflashControl: View {
    let modelPath: String
    var switchLeading: Bool = false
    @EnvironmentObject var loc: Localizer
    @State private var version = 0

    var body: some View {
        _ = version
        let enabled = ServerSettings.dflashEnabled(forModel: modelPath)
        return HStack(spacing: 8) {
            if switchLeading { toggle(enabled) }
            Label("DFlash", systemImage: "bolt.fill")
                .font(.caption).foregroundStyle(enabled ? .orange : .secondary)
            if !switchLeading { toggle(enabled) }
        }
        .help(loc.t("Decodificación especulativa DFlash (experimental). El modelo borrador ocupa VRAM extra: si te acercas al límite de tu GPU, baja el contexto o desactívalo. Por ahora ayuda en MoE con expertos en CPU y contenido predecible; en denso a GPU completa o con contexto alto puede ir más lento.",
                    "DFlash speculative decoding (experimental). The draft model uses extra VRAM: if you're near your GPU's limit, lower the context or turn it off. For now it helps on MoE with CPU-offloaded experts and predictable content; on full-GPU dense or high context it can be slower."))
    }

    private func toggle(_ enabled: Bool) -> some View {
        Toggle("", isOn: Binding(get: { enabled }, set: {
            ServerSettings.setDflashEnabled($0, forModel: modelPath); version += 1
        }))
        .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(.orange)
    }
}
