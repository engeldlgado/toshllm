import SwiftUI
import Charts

// MARK: - Estimates (helper views)

struct EstimateLine: View {
    let est: MemoryEstimate
    @EnvironmentObject var loc: Localizer

    var body: some View {
        HStack(spacing: 10) {
            badge
            Text(String(format: "VRAM ~%.1f GB", est.vramGB))
            if est.ramGB >= 1 { Text(String(format: "RAM ~%.1f GB", est.ramGB)) }
            Text(est.expectedSpeed)
            if est.suggestedNcmoe > 0 { Text("ncmoe \(est.suggestedNcmoe)") }
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
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct CatalogActionButton: View {
    let model: CatalogModel
    let est: MemoryEstimate
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""
    @AppStorage(SettingsKeys.ncmoe) private var ncmoe = 0

    var body: some View {
        if let local = models.localModel(fileName: model.fileName) {
            if modelPath == local.url.path {
                Label(loc.t("Activo", "Active"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
            } else {
                Button(loc.t("Usar", "Use")) {
                    modelPath = local.url.path
                    ncmoe = est.suggestedNcmoe
                }
                .buttonStyle(.borderedProminent)
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
            Label(loc.t("Error", "Failed"), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red).font(.caption).help(message)
        }
    }
}
