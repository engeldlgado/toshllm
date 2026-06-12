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
        } else if models.isDownloading(fileName: model.fileName) {
            ProgressView().controlSize(.small)
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
