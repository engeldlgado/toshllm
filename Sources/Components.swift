// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

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
            .font(.caption)
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
        .glassButton(prominent: true)
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
            Text(loc.t("El servidor principal se reiniciará para usar «%@».", "The main server will restart to use “%@”.", "\(modelName)"))
        }
    }

    private func apply() {
        modelPath = path
        ncmoe = Estimator.ncmoeForSelection(path: path, models: models.models)
    }
}

private struct GPUPickerSection: Identifiable {
    let id: UInt64
    let title: String?
    let color: Color?
    let gpus: [GPUDevice]
}

private enum GPUPickerLayout {
    static let palette: [Color] = [.accentColor, .teal, .orange, .purple, .pink]

    static func colors(_ gpus: [GPUDevice]) -> [UInt64: Color] {
        let items = gpus.map { (index: $0.index, groupID: $0.peerGroupID) }
        return GPUPeerTopology.groupIDs(items).enumerated().reduce(into: [:]) { out, pair in
            out[pair.element] = palette[pair.offset % palette.count]
        }
    }

    /// Linked cards first, each bridge as its own block, then the loose ones.
    static func sections(_ gpus: [GPUDevice], loc: Localizer) -> [GPUPickerSection] {
        let colors = colors(gpus)
        let linked = GPUPeerTopology.groups(of: gpus).map { group -> GPUPickerSection in
            let members = gpus.filter { group.indices.contains($0.index) }
            let gb = members.reduce(0) { $0 + $1.vramGB }
            let id = members.first?.peerGroupID ?? 0
            return GPUPickerSection(id: id,
                                    title: loc.t("Fabric %@ · %@ GB", "Fabric %@ · %@ GB", group.label, "\(gb)"),
                                    color: colors[id], gpus: members)
        }
        let loose = gpus.filter { colors[$0.peerGroupID] == nil }
        guard !loose.isEmpty else { return linked }
        return linked + [GPUPickerSection(id: 0,
                                          title: linked.isEmpty ? nil : loc.t("Sin enlace", "No link"),
                                          color: nil, gpus: loose)]
    }
}

private struct GPUPickerRow: View {
    let gpu: GPUDevice
    let color: Color?
    let selected: Bool
    let onToggle: (Int) -> Void

    @State private var hovered = false

    var body: some View {
        Button { onToggle(gpu.index) } label: {
            HStack(spacing: 9) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? (color ?? Color.accentColor) : Color.secondary.opacity(0.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(gpu.name).font(.system(size: 12)).lineLimit(1)
                    Text("#\(gpu.index) · \(gpu.vramGB) GB")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(hovered ? 0.06 : 0),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5).fill(color ?? .clear).frame(width: 2.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hovered = $0 }
    }
}

private struct GPUPickerChip: View {
    let title: String
    let color: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium))
                .foregroundStyle(color ?? .primary)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background((color ?? .primary).opacity(color == nil ? 0.08 : 0.14), in: Capsule())
                .overlay(Capsule().strokeBorder((color ?? .clear).opacity(0.35)))
        }
        .buttonStyle(.plain)
    }
}

private struct GPUPickerPanel: View {
    let gpus: [GPUDevice]
    let sections: [GPUPickerSection]
    let selection: Set<Int>
    let defaultTitle: String
    let onDefault: () -> Void
    let onSelect: ([Int]) -> Void
    let onToggle: (Int) -> Void

    @EnvironmentObject var loc: Localizer

    private var splitEligible: [GPUDevice] { gpus.filter { !$0.isIntegrated } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            shortcuts
            Divider().opacity(0.6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 1) {
                            header(section)
                            ForEach(section.gpus) { g in
                                GPUPickerRow(gpu: g, color: section.color,
                                             selected: selection.contains(g.index), onToggle: onToggle)
                            }
                        }
                    }
                }
                .padding(.vertical, 10)
            }
            .frame(maxHeight: 340)
            Divider().opacity(0.6)
            summary
        }
        .frame(width: 340)
    }

    @ViewBuilder private func header(_ section: GPUPickerSection) -> some View {
        if let title = section.title {
            HStack(spacing: 5) {
                Circle().fill(section.color ?? .clear).frame(width: 6, height: 6)
                Text(title).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary).textCase(.uppercase)
            }
            .padding(.horizontal, 12).padding(.bottom, 3)
        }
    }

    private var shortcuts: some View {
        HStack(spacing: 6) {
            GPUPickerChip(title: defaultTitle, color: nil, action: onDefault)
            if splitEligible.count > 1 {
                if defaultTitle != loc.t("Todas", "All") {
                    GPUPickerChip(title: loc.t("Todas", "All"), color: nil) {
                        onSelect(splitEligible.map(\.index))
                    }
                }
                ForEach(sections.filter { $0.color != nil }) { section in
                    GPUPickerChip(title: loc.t("Fabric %@", "Fabric %@", letter(section)),
                                  color: section.color) { onSelect(section.gpus.map(\.index)) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func letter(_ section: GPUPickerSection) -> String {
        section.title.flatMap { $0.split(separator: " ").dropFirst().first.map(String.init) } ?? ""
    }

    private var summary: some View {
        let chosen = gpus.filter { selection.contains($0.index) }
        let gb = chosen.reduce(0) { $0 + $1.vramGB }
        return HStack(spacing: 6) {
            Image(systemName: chosen.count >= 2 ? "square.split.2x1" : "cpu")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(chosen.count >= 2
                    ? loc.t("%@ GPUs · %@ GB de reparto", "%@ GPUs · %@ GB split", "\(chosen.count)", "\(gb)")
                    : (chosen.first.map { "\($0.name) · \($0.vramGB) GB" } ?? defaultTitle))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(WorkspaceStyle.inset)
    }
}

/// Checkbox list of GPUs in a popover: a menu closes on every click, which makes
/// picking several cards one reopen per card.
struct GPUMultiPicker: View {
    let label: String
    let selection: Set<Int>
    let defaultTitle: String
    var width: CGFloat = 230
    var help: String = ""
    let onDefault: () -> Void
    let onSelect: ([Int]) -> Void
    let onToggle: (Int) -> Void

    @EnvironmentObject var loc: Localizer
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: selection.count >= 2 ? "square.split.2x1" : "cpu")
                    .foregroundStyle(.secondary).frame(width: 16)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .frame(width: width, height: 34)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(WorkspaceStyle.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(WorkspaceStyle.border))
        }
        .buttonStyle(.plain)
        .help(help)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            let gpus = hardware.gpus
            GPUPickerPanel(gpus: gpus, sections: GPUPickerLayout.sections(gpus, loc: loc),
                           selection: selection,
                           defaultTitle: defaultTitle, onDefault: onDefault,
                           onSelect: onSelect, onToggle: onToggle)
        }
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
        GPUMultiPicker(label: label, selection: selection,
                       defaultTitle: loc.t("Predeterminada", "Default"),
                       help: loc.t("GPU(s) que usa este servidor: una fija esa GPU; varias reparten las capas del modelo entre ellas (experimental); ninguna deja elegir a macOS. Los atajos eligen todas de golpe o un enlace Infinity Fabric entero.",
                                   "GPU(s) this server uses: one pins that GPU; several split the model's layers across them (experimental); none lets macOS choose. The shortcuts pick every card at once, or one whole Infinity Fabric link."),
                       onDefault: { gpuIndex = -1; gpuList = [] },
                       onSelect: select, onToggle: toggle)
    }

    private var label: String {
        let sel = selection
        if sel.count >= 2 { return loc.t("Reparto · %@ GPUs", "Split · %@ GPUs", "\(sel.count)") }
        if let i = sel.first, let g = hardware.gpus.first(where: { $0.index == i }) { return g.name }
        return loc.t("GPU predeterminada", "Default GPU")
    }

    private func select(_ indices: [Int]) {
        if indices.count >= 2 { gpuIndex = -1; gpuList = indices.sorted() }
        else { gpuIndex = indices.first ?? -1; gpuList = [] }
    }

    private func toggle(_ i: Int) {
        var sel = selection
        if sel.contains(i) { sel.remove(i) } else { sel.insert(i) }
        select(sel.sorted())
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
            Button(loc.t("Descargar", "Download"), systemImage: "arrow.down.circle") {
                models.download(urlString: model.urlString)
            }
            .glassButton(prominent: true)
            .controlSize(.small)
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
                Text(loc.t("Preparando…", "Preparing…")).font(.caption).foregroundStyle(.secondary)
            }
        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(loc.t("Verificando…", "Verifying…")).font(.caption).foregroundStyle(.secondary)
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
                .iconHelp(item.phase == .paused ? loc.t("Reanudar", "Resume") : loc.t("Pausar", "Pause"))
                Button { item.cancel() } label: { Label(loc.t("Quitar", "Clear"), systemImage: "xmark.circle") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .iconHelp(loc.t("Cancelar", "Cancel"))
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
                .accessibilityLabel(loc.t("Reintentar la descarga", "Retry the download"))
                .help(loc.t("Reintentar la descarga desde cero.", "Retry the download from scratch."))
            }
        }
    }
}
