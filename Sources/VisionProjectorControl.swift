import SwiftUI
import UniformTypeIdentifiers

/// Per-model vision control: an always-visible on/off switch plus, when on, a
/// compact menu to pin a projector file or auto-pair it. Off runs text-only.
/// Used on model cards and the server card.
struct VisionProjectorControl: View {
    let modelPath: String
    /// Anchor the switch to the leading edge (model cards, left-aligned) or the
    /// trailing edge (server card, right-aligned) so revealing the menu never
    /// shifts the switch's position.
    var switchLeading: Bool = false
    @EnvironmentObject var loc: Localizer
    @State private var version = 0

    var body: some View {
        _ = version
        let override = ServerSettings.mmprojOverride(forModel: modelPath)
        let enabled = override != ""   // nil (auto) or a pinned path = on; "" = off
        let resolved = ServerSettings.mmprojPath(forModel: modelPath)
        let mismatch = resolved.map { ServerSettings.mmprojIncompatible(model: modelPath, projector: $0) } ?? false
        let current = resolved.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? loc.t("auto", "auto")
        return HStack(spacing: 8) {
            if switchLeading { toggle(enabled) }
            if enabled {
                Menu {
                    Button(loc.t("Elegir archivo…", "Choose file…")) { pick() }
                    Button(loc.t("Automático", "Automatic")) { set(nil) }
                } label: {
                    HStack(spacing: 4) {
                        Text("mmproj:").foregroundStyle(.secondary)
                        Text(current).lineLimit(1).truncationMode(.middle)
                        if mismatch {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .help(loc.t("El proyector no coincide con la dimensión del modelo; la visión podría fallar.",
                                            "The projector doesn't match the model's dimension; vision may fail."))
                        }
                    }
                    .font(.caption)
                }
                .menuStyle(.button).buttonStyle(.bordered).controlSize(.small).fixedSize()
            } else {
                Text(loc.t("solo texto", "text-only")).font(.caption).foregroundStyle(.secondary)
            }
            if !switchLeading { toggle(enabled) }
        }
    }

    private func toggle(_ enabled: Bool) -> some View {
        Toggle("", isOn: Binding(get: { enabled }, set: { set($0 ? nil : "") }))
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .help(loc.t("Activar o desactivar la visión para este modelo", "Turn vision on or off for this model"))
    }

    private func set(_ value: String?) {
        ServerSettings.setMmprojOverride(value, forModel: modelPath)
        // Enabling (auto or a file) re-arms the vision load path.
        if value != "" { UserDefaults.standard.set(true, forKey: SettingsKeys.loadVision) }
        version += 1
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { set(url.path) }
    }
}
