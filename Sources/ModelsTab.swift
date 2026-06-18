import SwiftUI

// MARK: - Models

struct ModelsView: View {
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var search: SearchStore
    @EnvironmentObject var loc: Localizer
    @State private var tab: Tab = .recommended

    enum Tab: Hashable { case recommended, browse, mine }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(loc.t("Recomendados", "Recommended")).tag(Tab.recommended)
                Text(loc.t("Buscar / Tendencia", "Browse")).tag(Tab.browse)
                Label(loc.t("Mis modelos", "My models"),
                      systemImage: models.downloads.contains { $0.phase == .downloading } ? "arrow.down.circle.fill" : "internaldrive")
                    .tag(Tab.mine)
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleOnly)
            .padding(12)
            Divider()

            ScrollView {
                switch tab {
                case .recommended: RecommendedTab()
                case .browse: BrowseTab()
                case .mine: MyModelsTab()
                }
            }
        }
        .toolbar {
            Button { models.refresh() } label: {
                Label(loc.t("Actualizar", "Refresh"), systemImage: "arrow.clockwise")
            }
        }
    }
}

/// Adaptive grid of model cards used across the tabs.
private struct ModelGrid<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)],
                  alignment: .leading, spacing: 12) {
            content
        }
    }
}

// MARK: - Recommended tab

private struct RecommendedTab: View {
    @EnvironmentObject var loc: Localizer

    var body: some View {
        let recs = Catalog.recommendations(for: hardware)
        let recIDs = Set(recs.map(\.id))
        let rest = Catalog.models.filter { !recIDs.contains($0.id) }

        VStack(alignment: .leading, spacing: 16) {
            if !recs.isEmpty {
                SectionHeader(icon: "star.fill",
                              title: loc.t("Para tu equipo", "For your machine"),
                              subtitle: loc.t("Elegidos según tu GPU/RAM, según lo que necesites.",
                                              "Picked for your GPU/RAM, by what you need."))
                ModelGrid {
                    ForEach(recs) { rec in
                        CatalogCard(model: rec.model,
                                    est: rec.est,
                                    role: rec.role)
                    }
                }
            }

            if !rest.isEmpty {
                SectionHeader(icon: "square.grid.2x2",
                              title: loc.t("Resto del catálogo", "Rest of the catalog"),
                              subtitle: loc.t("Modelos curados con estimaciones medidas para tu equipo.",
                                              "Curated models with measured estimates for your machine."))
                ModelGrid {
                    ForEach(rest) { m in
                        CatalogCard(model: m,
                                    est: Estimator.estimateCurrent(spec: m.spec, hw: hardware),
                                    role: nil)
                    }
                }
            }
        }
        .padding(16)
    }
}

// MARK: - Browse / Trending tab

private struct BrowseTab: View {
    @EnvironmentObject var search: SearchStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(loc.t("Buscar GGUF en Hugging Face…", "Search GGUF on Hugging Face…"),
                              text: $search.query)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await search.search() } }
                    if !search.query.isEmpty {
                        Button { search.query = ""; search.didSearch = false } label: {
                            Image(systemName: "xmark.circle.fill")
                        }.buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

                Button { Task { await search.search() } } label: {
                    if search.searching { ProgressView().controlSize(.small) }
                    else { Text(loc.t("Buscar", "Search")) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(search.query.isEmpty || search.searching)
            }

            if search.didSearch && !search.query.isEmpty {
                if search.results.isEmpty && !search.searching {
                    Text(loc.t("Sin resultados", "No results")).foregroundStyle(.secondary).font(.callout)
                } else {
                    SectionHeader(icon: "magnifyingglass",
                                  title: loc.t("Resultados", "Results"), subtitle: nil)
                    ForEach(search.results) { RepoCard(repo: $0) }
                }
            } else {
                HStack {
                    SectionHeader(icon: "flame.fill",
                                  title: loc.t("Tendencia en Hugging Face", "Trending on Hugging Face"),
                                  subtitle: loc.t("Lo más popular ahora mismo. Despliega para ver cuantizaciones y si caben.",
                                                  "Most popular right now. Expand to see quants and whether they fit."))
                    Spacer()
                    if search.loadingTrending { ProgressView().controlSize(.small) }
                }
                ForEach(search.trending) { RepoCard(repo: $0) }
            }
        }
        .padding(16)
        .task { await search.loadTrending() }
    }
}

/// An expandable Hugging Face repo: header with stats, expands to its GGUF
/// files with per-quant fit badges. Shared by search results and trending.
private struct RepoCard: View {
    let repo: HFRepo
    @EnvironmentObject var search: SearchStore
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Task { await search.toggleFiles(repo: repo.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: search.expanded == repo.id ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary).frame(width: 12)
                    Text(repo.id).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer()
                    if let l = repo.likes {
                        Label("\(l)", systemImage: "heart").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let d = repo.downloads {
                        Label(compact(d), systemImage: "arrow.down.circle")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(12)

            if search.expanded == repo.id {
                Divider()
                Group {
                    if let files = search.files[repo.id] {
                        if files.isEmpty {
                            Text(loc.t("Sin archivos .gguf directos", "No direct .gguf files"))
                                .font(.caption).foregroundStyle(.secondary).padding(12)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(files) { FileRow(repo: repo.id, file: $0) }
                            }
                            .padding(12)
                        }
                    } else {
                        ProgressView().controlSize(.small).padding(12)
                    }
                }
            }
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func compact(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6)
            : n >= 1_000 ? String(format: "%.0fk", Double(n) / 1e3) : "\(n)"
    }
}

private struct FileRow: View {
    let repo: String
    let file: HFFile
    @EnvironmentObject var search: SearchStore
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer

    var body: some View {
        let est = Estimator.estimateCurrent(
            spec: .estimated(fileBytes: file.sizeBytes, isMoE: file.isMoE), hw: hardware)
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: file.path).lastPathComponent).font(.caption)
                EstimateLine(est: est)
            }
            Spacer()
            Text(file.sizeGB).font(.caption2).foregroundStyle(.secondary)
            let fileName = URL(fileURLWithPath: file.path).lastPathComponent
            if models.isDownloaded(fileName: fileName) {
                Label(loc.t("Descargado", "Downloaded"), systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly).foregroundStyle(.green)
            } else if let item = models.downloadItem(fileName: fileName) {
                InlineDownloadProgress(item: item)
            } else if est.level == .no {
                Text(loc.t("No cabe", "Won't fit")).font(.caption2).foregroundStyle(.red)
            } else {
                Button {
                    models.download(urlString: search.downloadURL(repo: repo, file: file.path))
                } label: { Image(systemName: "arrow.down.circle") }
                    .buttonStyle(.borderless)
                    .help(loc.t("Descargar", "Download"))
            }
        }
    }
}

// MARK: - My models tab

private struct MyModelsTab: View {
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""
    @AppStorage(SettingsKeys.ncmoe) private var ncmoe = 0
    @State private var customURL = ""
    @State private var pendingDelete: LocalModel?

    private var modelsFolderShort: String {
        (models.directory.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !models.downloads.isEmpty {
                SectionHeader(icon: "arrow.down.circle", title: loc.t("Descargas", "Downloads"), subtitle: nil)
                VStack(spacing: 8) {
                    ForEach(models.downloads) { DownloadRow(item: $0) }
                }
                Button(loc.t("Limpiar terminadas", "Clear finished")) {
                    models.clearFinishedDownloads()
                }.font(.caption).buttonStyle(.borderless)
            }

            SectionHeader(icon: "internaldrive",
                          title: loc.t("Archivos locales en \(modelsFolderShort)",
                                       "Local files in \(modelsFolderShort)"),
                          subtitle: nil)
            if models.models.isEmpty {
                Text(loc.t("No hay modelos .gguf todavía. Descarga uno desde Recomendados o Buscar.",
                           "No .gguf models yet. Download one from Recommended or Browse."))
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                ModelGrid {
                    ForEach(models.models) { m in
                        LocalModelCard(model: m, pendingDelete: $pendingDelete)
                    }
                }
            }

            SectionHeader(icon: "link",
                          title: loc.t("URL personalizada (GGUF directo)", "Custom URL (direct GGUF)"),
                          subtitle: nil)
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
        .padding(16)
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

// MARK: - Cards

/// A catalog model as a card: optional recommendation role chip, name, size,
/// MoE badge, blurb, fit estimate and the download/use action.
private struct CatalogCard: View {
    let model: CatalogModel
    let est: MemoryEstimate
    let role: Catalog.Recommendation.Role?
    @EnvironmentObject var loc: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if let role { RoleChip(role: role) }
                if model.spec.isMoE { MoEBadge() }
                Spacer(minLength: 0)
                Text(String(format: "%.1f GB", model.spec.fileGB))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(model.name).font(.headline)
            Text(model.detail(loc.isSpanish))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            EstimateLine(est: est)
            Spacer(minLength: 2)
            HStack { Spacer(); CatalogActionButton(model: model, est: est) }
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(role != nil ? RoleChip.color(role!).opacity(0.35) : .clear, lineWidth: 1))
    }
}

private struct LocalModelCard: View {
    let model: LocalModel
    @Binding var pendingDelete: LocalModel?
    @EnvironmentObject var loc: Localizer
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""
    @AppStorage(SettingsKeys.ncmoe) private var ncmoe = 0

    var body: some View {
        let est = Estimator.estimateCurrent(spec: Catalog.spec(forLocal: model), hw: hardware)
        let active = modelPath == model.url.path
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if model.isMoE { MoEBadge() }
                Spacer(minLength: 0)
                Text(model.sizeGB).font(.caption2).foregroundStyle(.secondary)
            }
            Text(model.name).font(.subheadline.weight(active ? .semibold : .medium)).lineLimit(2)
            EstimateLine(est: est)
            Spacer(minLength: 2)
            HStack(spacing: 8) {
                if active {
                    Label(loc.t("Activo", "Active"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                } else {
                    Button(loc.t("Usar", "Use")) {
                        modelPath = model.url.path
                        ncmoe = est.suggestedNcmoe
                    }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                Spacer()
                Button { NSWorkspace.shared.activateFileViewerSelecting([model.url]) } label: {
                    Image(systemName: "magnifyingglass")
                }.buttonStyle(.borderless).help(loc.t("Mostrar en Finder", "Reveal in Finder"))
                Button { pendingDelete = model } label: {
                    Image(systemName: "trash")
                }.buttonStyle(.borderless).foregroundStyle(.red)
                    .help(loc.t("Eliminar (a la Papelera)", "Delete (to Trash)"))
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background((active ? Color.green.opacity(0.10) : Color.secondary.opacity(0.08)),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(active ? Color.green.opacity(0.4) : .clear, lineWidth: 1))
    }
}

// MARK: - Small components

private struct SectionHeader: View {
    let icon: String
    let title: String
    let subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon)
                .font(.headline)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct RoleChip: View {
    let role: Catalog.Recommendation.Role
    @EnvironmentObject var loc: Localizer

    static func color(_ role: Catalog.Recommendation.Role) -> Color {
        switch role {
        case .fast: return .green
        case .balanced: return .blue
        case .quality: return .purple
        case .coding: return .orange
        }
    }

    var body: some View {
        let (text, icon): (String, String) = {
            switch role {
            case .fast:     return (loc.t("Más rápido", "Fastest"), "hare.fill")
            case .balanced: return (loc.t("Equilibrado", "Balanced"), "scalemass.fill")
            case .quality:  return (loc.t("Máxima calidad", "Top quality"), "sparkles")
            case .coding:   return (loc.t("Programación", "Coding"), "chevron.left.forwardslash.chevron.right")
            }
        }()
        let color = Self.color(role)
        return Label(text, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
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
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
