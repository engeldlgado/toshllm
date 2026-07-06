import SwiftUI
import Charts

// MARK: - Estimates (helper views)

struct EstimateLine: View {
    let est: MemoryEstimate
    @EnvironmentObject var loc: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                badge
                Text(est.expectedSpeed)
            }
            HStack(spacing: 10) {
                Text(String(format: "VRAM ~%.1f GB", est.vramGB))
                if est.ramGB >= 1 { Text(String(format: "RAM ~%.1f GB", est.ramGB)) }
                if est.suggestedNcmoe > 0 { Text("ncmoe \(est.suggestedNcmoe)") }
            }
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    private var badge: some View {
        let (text, color): (String, Color) = {
            switch est.level {
            case .ideal: return (loc.t("GPU completa", "Full GPU"), .green)
            case .good: return (loc.t("Híbrido GPU+CPU", "GPU+CPU hybrid"), .blue)
            case .slow: return (loc.t("Lento", "Slow"), .orange)
            case .no: return (loc.t("No cabe", "Won't fit"), .red)
            }
        }()
        return Text(text)
            .font(.caption2.weight(.medium))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

/// "Use" action for a model: marks it as the primary server's model and, when
/// that server is up, asks to restart it so the change applies right away.
struct UseModelButton: View {
    let path: String
    let modelName: String
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var server: ServerController
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""
    @AppStorage(SettingsKeys.ncmoe) private var ncmoe = 0
    @State private var confirmRestart = false

    var body: some View {
        Button(loc.t("Usar", "Use")) {
            if server.state == .running || server.state == .starting {
                confirmRestart = true
            } else {
                apply()
            }
        }
        .buttonStyle(.borderedProminent)
        .help(loc.t("Usa este modelo en el servidor principal; si está corriendo, pedirá confirmación para reiniciarlo.",
                    "Use this model on the main server; if it's running, you'll be asked to confirm a restart."))
        .alert(loc.t("¿Reiniciar el servidor principal?", "Restart the main server?"),
               isPresented: $confirmRestart) {
            Button(loc.t("Reiniciar", "Restart")) {
                apply()
                server.restart(.fromDefaults())
            }
            Button(loc.t("Cancelar", "Cancel"), role: .cancel) {}
        } message: {
            Text(loc.t("El servidor principal se reiniciará para usar «\(modelName)».",
                       "The main server will restart to use “\(modelName)”."))
        }
    }

    private func apply() {
        modelPath = path
        ncmoe = Estimator.ncmoeForSelection(path: path, models: models.models)
    }
}

/// GPU picker that also supports sets: none selected = system default, one =
/// pin that GPU, two or more = split the layers across exactly those GPUs.
struct GPUSelectionMenu: View {
    @Binding var gpuIndex: Int
    @Binding var gpuList: [Int]
    @EnvironmentObject var loc: Localizer

    private var selection: Set<Int> {
        gpuList.count >= 2 ? Set(gpuList) : (gpuIndex >= 0 ? [gpuIndex] : [])
    }

    var body: some View {
        Menu {
            Button(loc.t("Predeterminada", "Default")) { gpuIndex = -1; gpuList = [] }
            Divider()
            ForEach(hardware.gpus) { g in
                Toggle("\(g.name) · \(g.vramMB / 1024) GB", isOn: Binding(
                    get: { selection.contains(g.index) },
                    set: { _ in toggle(g.index) }))
            }
        } label: {
            Text(label).lineLimit(1)
        }
        .help(loc.t("GPU(s) que usa este servidor: una fija esa GPU; varias reparten las capas del modelo entre ellas (experimental); ninguna deja elegir a macOS.",
                    "GPU(s) this server uses: one pins that GPU; several split the model's layers across them (experimental); none lets macOS choose."))
    }

    private var label: String {
        let sel = selection
        if sel.count >= 2 { return loc.t("Reparto · \(sel.count) GPUs", "Split · \(sel.count) GPUs") }
        if let i = sel.first, let g = hardware.gpus.first(where: { $0.index == i }) { return g.name }
        return loc.t("GPU predeterminada", "Default GPU")
    }

    private func toggle(_ i: Int) {
        var sel = selection
        if sel.contains(i) { sel.remove(i) } else { sel.insert(i) }
        let sorted = sel.sorted()
        if sorted.count >= 2 { gpuIndex = -1; gpuList = sorted }
        else { gpuIndex = sorted.first ?? -1; gpuList = [] }
    }
}

struct CatalogActionButton: View {
    let model: CatalogModel
    let est: MemoryEstimate
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""

    var body: some View {
        if let local = models.localModel(fileName: model.fileName) {
            if modelPath == local.url.path {
                Label(loc.t("Activo", "Active"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
            } else {
                UseModelButton(path: local.url.path, modelName: model.name)
            }
        } else if let item = models.downloadItem(fileName: model.fileName) {
            InlineDownloadProgress(item: item)
        } else if est.level == .no {
            Text(loc.t("No compatible", "Not compatible")).font(.caption).foregroundStyle(.secondary)
        } else {
            Button {
                models.download(urlString: model.urlString)
            } label: {
                Label(loc.t("Descargar", "Download"), systemImage: "arrow.down.circle")
            }
        }
    }
}

/// Compact live download state for a single file — a determinate bar with a
/// percentage and pause/cancel — shown inline on a model card so pressing
/// Download gives immediate, visible feedback with progress.
struct InlineDownloadProgress: View {
    @ObservedObject var item: DownloadItem
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var models: ModelStore

    var body: some View {
        switch item.phase {
        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(loc.t("Preparando…", "Preparing…")).font(.caption2).foregroundStyle(.secondary)
            }
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(loc.t("Verificando…", "Verifying…")).font(.caption2).foregroundStyle(.secondary)
            }
        case .downloading, .paused:
            HStack(spacing: 7) {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: item.progress).frame(width: 88)
                    Text("\(Int(item.progress * 100))%  ·  \(Int(item.receivedMB))/\(Int(item.totalMB)) MB")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }
                Button {
                    item.phase == .paused ? item.resume() : item.pause()
                } label: {
                    Image(systemName: item.phase == .paused ? "play.circle" : "pause.circle")
                }
                .buttonStyle(.borderless)
                .help(item.phase == .paused ? loc.t("Reanudar", "Resume") : loc.t("Pausar", "Pause"))
                Button { item.cancel() } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help(loc.t("Cancelar", "Cancel"))
            }
        case .finished:
            Label(loc.t("Listo", "Done"), systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green).font(.caption)
        case .failed(let message):
            HStack(spacing: 7) {
                Label(loc.t("Error", "Failed"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).font(.caption).help(message)
                Button { models.retry(item) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(loc.t("Reintentar la descarga desde cero.", "Retry the download from scratch."))
            }
        }
    }
}
