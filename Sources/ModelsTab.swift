import SwiftUI
import Charts

// MARK: - Models

struct ModelsView: View {
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""
    @AppStorage(SettingsKeys.ncmoe) private var ncmoe = 0
    @State private var customURL = ""
    @State private var pendingDelete: LocalModel?

    var body: some View {
        List {
            if !models.downloads.isEmpty {
                Section(loc.t("Descargas", "Downloads")) {
                    ForEach(models.downloads) { DownloadRow(item: $0) }
                    Button(loc.t("Limpiar terminadas", "Clear finished")) {
                        models.clearFinishedDownloads()
                    }.font(.caption)
                }
            }

            HFSearchSection()

            Section(loc.t("Catálogo — estimaciones para tu equipo",
                          "Catalog — estimates for your machine")) {
                ForEach(Catalog.models) { m in
                    let est = Estimator.estimateCurrent(spec: m.spec, hw: hardware)
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(m.name).fontWeight(.medium)
                                Text(String(format: "%.1f GB", m.spec.fileGB))
                                    .font(.caption).foregroundStyle(.secondary)
                                if m.spec.isMoE { MoEBadge() }
                            }
                            Text(m.detail(loc.isSpanish)).font(.caption).foregroundStyle(.secondary)
                            EstimateLine(est: est)
                        }
                        Spacer()
                        CatalogActionButton(model: m, est: est)
                    }
                    .padding(.vertical, 3)
                }
            }

            Section(loc.t("Archivos locales en ~/models", "Local files in ~/models")) {
                if models.models.isEmpty {
                    Text(loc.t("No hay modelos .gguf todavía", "No .gguf models yet"))
                        .foregroundStyle(.secondary)
                }
                ForEach(models.models) { m in
                    let est = Estimator.estimateCurrent(spec: Catalog.spec(forLocal: m), hw: hardware)
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(m.name).fontWeight(modelPath == m.url.path ? .semibold : .regular)
                                if m.isMoE { MoEBadge() }
                            }
                            Text(m.sizeGB).font(.caption).foregroundStyle(.secondary)
                            EstimateLine(est: est)
                        }
                        Spacer()
                        if modelPath == m.url.path {
                            Label(loc.t("Activo", "Active"), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.callout)
                        } else {
                            Button(loc.t("Usar", "Use")) {
                                modelPath = m.url.path
                                ncmoe = est.suggestedNcmoe
                            }
                        }
                        Button { NSWorkspace.shared.activateFileViewerSelecting([m.url]) } label: {
                            Image(systemName: "magnifyingglass")
                        }.buttonStyle(.borderless)
                            .help(loc.t("Mostrar en Finder", "Reveal in Finder"))
                        Button { pendingDelete = m } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless).foregroundStyle(.red)
                            .help(loc.t("Eliminar (a la Papelera)", "Delete (to Trash)"))
                    }
                    .padding(.vertical, 3)
                }
            }

            Section(loc.t("URL personalizada (GGUF directo)", "Custom URL (direct GGUF)")) {
                HStack {
                    TextField("https://huggingface.co/…/resolve/main/model.gguf", text: $customURL)
                        .textFieldStyle(.roundedBorder)
                    Button(loc.t("Descargar", "Download")) {
                        models.download(urlString: customURL)
                        customURL = ""
                    }
                    .disabled(!customURL.hasPrefix("http"))
                }
            }
        }
        .toolbar {
            Button { models.refresh() } label: {
                Label(loc.t("Actualizar", "Refresh"), systemImage: "arrow.clockwise")
            }
        }
        .confirmationDialog(
            loc.t("¿Eliminar \(pendingDelete?.name ?? "")?", "Delete \(pendingDelete?.name ?? "")?"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button(loc.t("Mover a la Papelera", "Move to Trash"), role: .destructive) {
                if let m = pendingDelete {
                    if modelPath == m.url.path { modelPath = "" }
                    models.delete(m)
                }
                pendingDelete = nil
            }
            Button(loc.t("Cancelar", "Cancel"), role: .cancel) { pendingDelete = nil }
        }
    }
}

// MARK: - Hugging Face search

struct HFSearchSection: View {
    @EnvironmentObject var search: SearchStore
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        Section(loc.t("Buscar en Hugging Face", "Search Hugging Face")) {
            HStack {
                TextField(loc.t("p. ej. Qwen3.6 35B A3B", "e.g. Qwen3.6 35B A3B"), text: $search.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search.search() } }
                Button {
                    Task { await search.search() }
                } label: {
                    if search.searching { ProgressView().controlSize(.small) }
                    else { Label(loc.t("Buscar", "Search"), systemImage: "magnifyingglass") }
                }
                .disabled(search.query.isEmpty || search.searching)
            }

            if search.didSearch && search.results.isEmpty && !search.searching {
                Text(loc.t("Sin resultados", "No results")).foregroundStyle(.secondary).font(.caption)
            }

            ForEach(search.results) { repo in
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        Task { await search.toggleFiles(repo: repo.id) }
                    } label: {
                        HStack {
                            Image(systemName: search.expanded == repo.id ? "chevron.down" : "chevron.right")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(repo.id).font(.callout)
                            Spacer()
                            if let d = repo.downloads {
                                Label("\(d)", systemImage: "arrow.down.circle")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if search.expanded == repo.id {
                        if let files = search.files[repo.id] {
                            if files.isEmpty {
                                Text(loc.t("Sin archivos .gguf directos", "No direct .gguf files"))
                                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 18)
                            }
                            ForEach(files) { f in
                                let est = Estimator.estimateCurrent(
                                    spec: .estimated(fileBytes: f.sizeBytes, isMoE: f.isMoE), hw: hardware)
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(f.path).font(.caption)
                                        EstimateLine(est: est)
                                    }
                                    Spacer()
                                    Text(f.sizeGB).font(.caption2).foregroundStyle(.secondary)
                                    if models.isDownloaded(fileName: URL(fileURLWithPath: f.path).lastPathComponent) {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    } else if est.level == .no {
                                        Text(loc.t("No cabe", "Won't fit")).font(.caption2).foregroundStyle(.red)
                                    } else {
                                        Button {
                                            models.download(urlString: search.downloadURL(repo: repo.id, file: f.path))
                                        } label: { Image(systemName: "arrow.down.circle") }
                                            .buttonStyle(.borderless)
                                    }
                                }
                                .padding(.leading, 18)
                            }
                        } else {
                            ProgressView().controlSize(.small).padding(.leading, 18)
                        }
                    }
                }
            }
        }
    }
}

struct MoEBadge: View {
    var body: some View {
        Text("MoE").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
            .background(.pink.opacity(0.2), in: Capsule())
    }
}

struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    @EnvironmentObject var loc: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.fileName).font(.callout)
                Spacer()
                switch item.phase {
                case .preparing:
                    Text(loc.t("Preparando…", "Preparing…"))
                        .font(.caption).foregroundStyle(.secondary)
                case .verifying:
                    ProgressView().controlSize(.small)
                    Text(loc.t("Verificando SHA-256…", "Verifying SHA-256…"))
                        .font(.caption).foregroundStyle(.secondary)
                case .finished:
                    Label(loc.t("Completada y verificada", "Done and verified"),
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green).font(.caption)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red)
                        .lineLimit(2).frame(maxWidth: 340, alignment: .trailing)
                case .downloading, .paused:
                    Text(String(format: "%.0f / %.0f MB", item.receivedMB, item.totalMB))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    if item.phase == .paused {
                        Button { item.resume() } label: { Image(systemName: "play.circle") }
                            .buttonStyle(.borderless)
                            .help(loc.t("Reanudar", "Resume"))
                    } else {
                        Button { item.pause() } label: { Image(systemName: "pause.circle") }
                            .buttonStyle(.borderless)
                            .help(loc.t("Pausar (reanudable)", "Pause (resumable)"))
                    }
                    Button { item.cancel() } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .help(loc.t("Cancelar", "Cancel"))
                }
            }
            if item.phase == .downloading || item.phase == .paused {
                ProgressView(value: item.progress)
                    .tint(item.phase == .paused ? .orange : .accentColor)
            }
        }
        .padding(.vertical, 2)
    }
}
