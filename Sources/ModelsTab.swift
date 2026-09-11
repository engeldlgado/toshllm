// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

// MARK: - Models

struct ModelsView: View {
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var search: SearchStore
    @EnvironmentObject var modelUpdates: ModelUpdateChecker
    @EnvironmentObject var loc: Localizer
    @State private var tab: Tab = .recommended
    @State private var refreshing = false

    enum Tab: Hashable { case recommended, browse, mine }

    var body: some View {
        VStack(spacing: 0) {
            ModelSectionSwitcher(selection: $tab, items: [
                .init(value: .recommended, title: loc.t("Recomendados", "Recommended"),
                      subtitle: loc.t("Elegidos para este Mac", "Matched to this Mac"), systemImage: "sparkles"),
                .init(value: .browse, title: loc.t("Explorar", "Explore"),
                      subtitle: "Hugging Face · GGUF", systemImage: "magnifyingglass"),
                .init(value: .mine, title: loc.t("Mis modelos", "My models"),
                      subtitle: loc.t("Biblioteca local", "Local library"), systemImage: "internaldrive",
                      badge: models.downloads.contains { $0.phase == .downloading } ? loc.t("Descargando", "Downloading") : "\(models.models.count)"),
            ])
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            ToolbarItem(id: "modelUpdateCheck") {
                Button {
                    Task { await modelUpdates.check(models.models) }
                } label: {
                    Label(loc.t("Buscar actualizaciones", "Check for updates"),
                          systemImage: "arrow.triangle.2.circlepath")
                        .spinningSymbol(modelUpdates.checking)
                }
                .disabled(modelUpdates.checking || models.models.isEmpty)
                .help(loc.t("Comprueba si los modelos descargados se han vuelto a publicar en su repositorio de Hugging Face.",
                            "Checks whether the downloaded models have been re-published in their Hugging Face repo."))
            }

            ToolbarItem(id: "modelFolderRefresh") {
                Button {
                    models.refresh()
                    withAnimation { refreshing = true }
                    Task { try? await Task.sleep(for: .seconds(0.8)); withAnimation { refreshing = false } }
                } label: {
                    Label(loc.t("Actualizar", "Refresh"),
                          systemImage: refreshing ? "checkmark" : "arrow.clockwise")
                        .contentTransition(.symbolEffect(.replace))
                }
                .disabled(refreshing)
                .help(loc.t("Vuelve a escanear la carpeta de modelos para detectar archivos añadidos o eliminados.",
                            "Re-scans the models folder to pick up files added or removed outside the app."))
            }
        }
    }
}

// MARK: - Recommended tab

private struct RecommendedTab: View {
    @EnvironmentObject var loc: Localizer
    @State private var filter: CatalogFilter = .all
    @State private var query = ""
    @State private var selectedID: String?
    @State private var featuredIndex = 0
    @State private var compactLayout = false

    enum CatalogFilter: CaseIterable, Hashable { case all, text, vision, coder, moe, reasoning }

    private func label(_ f: CatalogFilter) -> String {
        switch f {
        case .all: return loc.t("Todos", "All")
        case .text: return loc.t("Texto", "Text")
        case .vision: return loc.t("Visión", "Vision")
        case .coder: return "Coder"
        case .moe: return "MoE"
        case .reasoning: return loc.t("Razonamiento", "Reasoning")
        }
    }
    private func icon(_ f: CatalogFilter) -> String {
        switch f {
        case .all: return "square.grid.2x2"
        case .text: return "text.alignleft"
        case .vision: return "eye"
        case .coder: return "chevron.left.forwardslash.chevron.right"
        case .moe: return "square.stack.3d.up"
        case .reasoning: return "brain.head.profile"
        }
    }
    private func matches(_ m: CatalogModel) -> Bool {
        switch filter {
        case .all: return true
        case .text: return !m.isVision
        case .vision: return m.isVision
        case .coder: return m.isCoder
        case .moe: return m.isMoE
        case .reasoning:
            return m.name.localizedCaseInsensitiveContains("GPT-OSS") ||
                m.detail(false).localizedCaseInsensitiveContains("reasoning")
        }
    }

    private func matchesSearch(_ model: CatalogModel) -> Bool {
        query.isEmpty || model.name.localizedCaseInsensitiveContains(query) ||
            model.detail(loc.isSpanish).localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        let allRecommendations = Catalog.recommendations(for: hardware)
        let visibleModels = Catalog.models.filter { matches($0) && matchesSearch($0) }
        let visibleIDs = Set(visibleModels.map(\.id))
        let recs = allRecommendations.filter { visibleIDs.contains($0.model.id) }
        let safeIndex = allRecommendations.isEmpty ? 0 : min(featuredIndex, allRecommendations.count - 1)
        let featuredID = allRecommendations.isEmpty ? nil : allRecommendations[safeIndex].model.id
        let rest = visibleModels.filter { $0.id != featuredID }
        let selected = Catalog.models.first { $0.id == selectedID }
            ?? recs.first?.model ?? visibleModels.first

        VStack(alignment: .leading, spacing: 18) {
            if !allRecommendations.isEmpty {
                let featured = allRecommendations[safeIndex]
                FeaturedModelBanner(recommendation: featured,
                                    currentIndex: safeIndex, total: allRecommendations.count,
                                    previous: { changeFeatured(to: (safeIndex - 1 + allRecommendations.count) % allRecommendations.count) },
                                    next: { changeFeatured(to: (safeIndex + 1) % allRecommendations.count) }) {
                    selectedID = featured.model.id
                }
            }

            ModelSearchAndFilters(placeholder: loc.t("Buscar modelos…", "Search models…"), text: $query) {
                ModelFilterBar(selection: $filter, filters: CatalogFilter.allCases.map {
                    .init(value: $0, title: label($0), systemImage: icon($0),
                          count: $0 == .all ? Catalog.models.count : nil)
                })
            }

            if visibleModels.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                Group {
                    if compactLayout {
                        VStack(alignment: .leading, spacing: 16) {
                            catalogResults(rest, selected: selected)
                            if let selected { inspector(selected).frame(maxWidth: .infinity) }
                        }
                    } else {
                        HStack(alignment: .top, spacing: 16) {
                            catalogResults(rest, selected: selected)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            if let selected { inspector(selected).frame(width: 320) }
                        }
                    }
                }
                .onGeometryChange(for: Bool.self) { geometry in
                    geometry.size.width < 830
                } action: { compactLayout = $0 }
            }
        }
        .padding(16)
    }

    @ViewBuilder private func catalogResults(_ models: [CatalogModel], selected: CatalogModel?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(icon: "square.grid.2x2",
                          title: loc.t("Catálogo de modelos", "Model catalog"),
                          subtitle: loc.t("Selecciona un modelo para revisar sus detalles.",
                                          "Select a model to inspect its details."))
            if models.isEmpty {
                Text(loc.t("Las coincidencias actuales están disponibles en el carrusel superior.",
                           "The current matches are available in the carousel above."))
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 16)
            } else {
                CatalogList {
                    ForEach(models) { model in
                        CatalogModelRow(model: model,
                                        est: Estimator.estimateCurrent(spec: model.spec, hw: hardware),
                                        role: nil, selected: selected?.id == model.id) {
                            selectedID = model.id
                        }
                    }
                }
            }
        }
    }

    private func inspector(_ model: CatalogModel) -> some View {
        CatalogModelInspector(model: model,
                              estimate: Estimator.estimateCurrent(spec: model.spec, hw: hardware))
    }

    private func changeFeatured(to index: Int) {
        withAnimation(.easeInOut(duration: 0.18)) { featuredIndex = index }
    }
}

private struct FeaturedModelBanner: View {
    let recommendation: Catalog.Recommendation
    let currentIndex: Int
    let total: Int
    let previous: () -> Void
    let next: () -> Void
    let select: () -> Void
    @EnvironmentObject private var loc: Localizer
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .leading) {
            WorkspaceHeroArtwork()
            LinearGradient(colors: [WorkspaceStyle.surface.opacity(0.99),
                                    WorkspaceStyle.surface.opacity(0.88),
                                    WorkspaceStyle.surface.opacity(0.12)],
                           startPoint: .leading, endPoint: .trailing)
            VStack(alignment: .leading, spacing: 12) {
                Label(loc.t("RECOMENDADO PARA TU EQUIPO", "RECOMMENDED FOR YOUR MACHINE"),
                      systemImage: "seal.fill")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(Color.appAccent)
                HStack(spacing: 9) {
                    Text(ModelName(recommendation.model.name).title)
                        .font(.system(size: 25, weight: .bold)).lineLimit(1)
                    RoleChip(role: recommendation.role)
                    if recommendation.model.isVision {
                        TagBadge(text: loc.t("Visión", "Vision"), icon: "eye", color: .purple)
                    }
                }
                Text(recommendation.model.detail(loc.isSpanish))
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                AdaptiveTwoUp(threshold: 560, spacing: 10, alignment: .center) {
                    metrics
                } second: {
                    actions
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
            .frame(maxWidth: 850, alignment: .leading)
        }
        .frame(minHeight: 176)
        .background(WorkspaceStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Color.appAccent.opacity(0.25)))
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 9) {
                HStack(spacing: 5) {
                    ForEach(0..<total, id: \.self) { index in
                        Capsule().fill(index == currentIndex ? carouselControlColor : carouselControlColor.opacity(0.25))
                            .frame(width: index == currentIndex ? 14 : 5, height: 5)
                    }
                }
                Button(action: previous) { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).frame(width: 28, height: 28)
                    .contentShape(Circle())
                    .background(carouselButtonBackground, in: Circle())
                Button(action: next) { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain).frame(width: 28, height: 28)
                    .contentShape(Circle())
                    .background(carouselButtonBackground, in: Circle())
            }
            .foregroundStyle(carouselControlColor).padding(14)
        }
        .contentTransition(.opacity)
    }

    @ViewBuilder private var metrics: some View {
        HeroMetric(icon: "bolt.fill", value: recommendation.est.expectedSpeed,
                   label: loc.t("Velocidad est.", "Speed est."), color: .appAccent)
        HeroMetric(icon: "memorychip", value: String(format: "%.1f GB", recommendation.est.vramGB),
                   label: "VRAM", color: .secondary)
        HeroMetric(icon: "circle.fill", value: compatibilityText,
                   label: loc.t("Compatibilidad", "Compatibility"), color: compatibilityColor)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            CatalogActionButton(model: recommendation.model, est: recommendation.est)
            Button(loc.t("Ver detalles", "View details"), systemImage: "info.circle", action: select)
                .glassButton()
        }
    }

    private var compatibilityText: String {
        switch recommendation.est.level {
        case .ideal: return loc.t("GPU completa", "Full GPU")
        case .good: return loc.t("Híbrido", "Hybrid")
        case .slow: return loc.t("Lento", "Slow")
        case .no: return loc.t("No cabe", "Won't fit")
        }
    }

    private var compatibilityColor: Color {
        recommendation.est.level == .ideal ? .green : recommendation.est.level == .no ? .red : .orange
    }

    private var carouselControlColor: Color {
        colorScheme == .light ? Color.black.opacity(0.72) : .white
    }

    private var carouselButtonBackground: Color {
        colorScheme == .light ? Color.white.opacity(0.68) : Color.black.opacity(0.20)
    }
}

private struct HeroMetric: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(WorkspaceStyle.inset.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
    }
}

/// The appearance-specific 1000 px JPEG is loaded lazily. Only the active
/// appearance is decoded during a normal session (~1.4 MB), and switching the
/// system appearance updates the banner without rebuilding its parent screen.
struct WorkspaceHeroArtwork: View {
    @Environment(\.colorScheme) private var colorScheme
    private static let darkImage: NSImage? = Bundle.main.url(forResource: "model-hero", withExtension: "jpg")
        .flatMap(NSImage.init(contentsOf:))
    private static let lightImage: NSImage? = Bundle.main.url(forResource: "model-hero-light", withExtension: "jpg")
        .flatMap(NSImage.init(contentsOf:))

    private var image: NSImage? {
        colorScheme == .light ? (Self.lightImage ?? Self.darkImage) : Self.darkImage
    }

    var body: some View {
        GeometryReader { proxy in
            if let image {
                Image(nsImage: image)
                    .resizable().scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            } else {
                LinearGradient(colors: [WorkspaceStyle.surface, Color.purple.opacity(0.22)],
                               startPoint: .leading, endPoint: .trailing)
            }
        }
        .accessibilityHidden(true)
        // scaledToFill overflows the frame and clipped() does not clip hit-testing,
        // so without this the artwork swallows clicks on whatever sits beside it.
        .allowsHitTesting(false)
    }
}

private struct CatalogModelInspector: View {
    enum Tab: CaseIterable { case overview, performance, files, details }

    let model: CatalogModel
    let estimate: MemoryEstimate
    @State private var tab: Tab = .overview
    @EnvironmentObject private var loc: Localizer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ModelBrandIcon(name: model.name, size: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(ModelName(model.name).title).font(.headline).lineLimit(2)
                    Text("\(repositoryOwner) · \(String(format: "%.1f GB", model.spec.fileGB))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)

            CatalogActionButton(model: model, est: estimate)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 14).padding(.bottom, 12)

            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { item in
                    Button(tabTitle(item)) { tab = item }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: tab == item ? .semibold : .regular))
                        .foregroundStyle(tab == item ? Color.appAccent : Color.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .overlay(alignment: .bottom) {
                            if tab == item { Rectangle().fill(Color.appAccent).frame(height: 2) }
                        }
                }
            }
            Divider()

            Group {
                switch tab {
                case .overview: overview
                case .performance: performance
                case .files: files
                case .details: details
                }
            }
            .padding(14)
        }
        .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(WorkspaceStyle.border))
        .id(model.id)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.detail(loc.isSpanish)).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            tags
            HStack(spacing: 8) {
                InspectorMetric(value: estimate.expectedSpeed, label: loc.t("Velocidad est.", "Speed est."), icon: "bolt.fill")
                InspectorMetric(value: String(format: "%.1f GB", estimate.vramGB), label: "VRAM", icon: "memorychip")
            }
            detailRows
        }
    }

    private var performance: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorMetric(value: estimate.expectedSpeed,
                            label: loc.t("Generación estimada", "Estimated generation"), icon: "bolt.fill")
            InspectorMetric(value: String(format: "%.1f GB VRAM · %.1f GB RAM", estimate.vramGB, estimate.ramGB),
                            label: loc.t("Memoria estimada", "Estimated memory"), icon: "memorychip")
            Text(loc.t("Las cifras son estimaciones para este Mac y pueden variar según el contexto.",
                       "Figures are estimates for this Mac and can vary with context."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorRow(label: loc.t("Archivo", "File"), value: model.fileName)
            InspectorRow(label: loc.t("Tamaño", "Size"), value: String(format: "%.1f GB", model.spec.fileGB))
            InspectorRow(label: loc.t("Cuantización", "Quantization"), value: quantization)
            Button("Hugging Face", systemImage: "safari") { openRepository() }
                .glassButton().controlSize(.small)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            detailRows
            Button(loc.t("Abrir repositorio", "Open repository"), systemImage: "arrow.up.right.square") {
                openRepository()
            }
            .glassButton().controlSize(.small)
        }
    }

    private var tags: some View {
        HStack(spacing: 6) {
            if model.isVision { TagBadge(text: loc.t("Visión", "Vision"), icon: "eye", color: .purple) }
            if model.isCoder { TagBadge(text: "Coder", icon: "chevron.left.forwardslash.chevron.right", color: .blue) }
            if model.isMoE { MoEBadge() }
            if !model.isVision && !model.isCoder && !model.isMoE {
                TagBadge(text: loc.t("Texto", "Text"), icon: "text.alignleft", color: .secondary)
            }
        }
    }

    private var detailRows: some View {
        VStack(spacing: 0) {
            InspectorRow(label: loc.t("Autor", "Author"), value: repositoryOwner)
            InspectorRow(label: loc.t("Familia", "Family"), value: modelFamily)
            InspectorRow(label: loc.t("Parámetros", "Parameters"), value: String(format: "%.1fB", model.spec.paramsB))
            InspectorRow(label: loc.t("Cuantización", "Quantization"), value: quantization)
            InspectorRow(label: loc.t("Arquitectura", "Architecture"), value: model.isMoE ? "MoE" : loc.t("Densa", "Dense"))
        }
    }

    private func tabTitle(_ item: Tab) -> String {
        switch item {
        case .overview: return loc.t("Resumen", "Overview")
        case .performance: return loc.t("Rendimiento", "Performance")
        case .files: return loc.t("Archivos", "Files")
        case .details: return loc.t("Detalles", "Details")
        }
    }

    private var repositoryURL: URL? {
        guard let url = URL(string: model.urlString),
              let resolve = url.pathComponents.firstIndex(of: "resolve") else { return nil }
        let path = url.pathComponents[1..<resolve].joined(separator: "/")
        return URL(string: "https://huggingface.co/\(path)")
    }
    private var repositoryOwner: String { repositoryURL?.pathComponents.dropFirst().first ?? "—" }
    private var quantization: String { ModelName.forPath(model.fileName).quant }
    private var modelFamily: String { ModelName(model.name).title.split(separator: " ").first.map(String.init) ?? model.name }
    private func openRepository() { if let repositoryURL { NSWorkspace.shared.open(repositoryURL) } }
}

private struct InspectorMetric: View {
    let value: String
    let label: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(value, systemImage: icon).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .padding(9).frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspaceStyle.inset, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct InspectorRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 11)).padding(.vertical, 7)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct ModelCollectionHero: View {
    let eyebrow: String
    let icon: String
    let title: String
    let detail: String
    let primaryValue: String
    let primaryLabel: String
    let secondaryValue: String
    let secondaryLabel: String
    var actionTitle: String?
    var actionIcon = "arrow.up.right.square"
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(Color.appAccent)
                .frame(width: 52, height: 52)
                .background(Color.appAccent.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text(eyebrow.uppercased())
                    .font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(Color.appAccent)
                Text(title).font(.system(size: 19, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 16)
            collectionStat(primaryValue, label: primaryLabel)
            Divider().frame(height: 38)
            collectionStat(secondaryValue, label: secondaryLabel)
            if let actionTitle, let action {
                Button(actionTitle, systemImage: actionIcon, action: action)
                    .glassButton().controlSize(.small)
            }
        }
        .padding(17)
        .background {
            LinearGradient(colors: [Color.appAccent.opacity(0.10), WorkspaceStyle.surface],
                           startPoint: .leading, endPoint: .trailing)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(WorkspaceStyle.border))
    }

    private func collectionStat(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 16, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(minWidth: 72, alignment: .leading)
    }
}

// MARK: - Browse / Trending tab

private struct BrowseTab: View {
    @EnvironmentObject var search: SearchStore
    @EnvironmentObject var loc: Localizer

    private func sortTitle(_ order: HFSortOrder) -> String {
        switch order {
        case .trending: return loc.t("Tendencia", "Trending")
        case .downloads: return loc.t("Descargas", "Downloads")
        case .likes: return loc.t("Favoritos", "Likes")
        case .recent: return loc.t("Recientes", "Recent")
        }
    }

    private func sortIcon(_ order: HFSortOrder) -> String {
        switch order {
        case .trending: return "flame"
        case .downloads: return "arrow.down.circle"
        case .likes: return "heart"
        case .recent: return "clock"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ModelCollectionHero(
                eyebrow: "Hugging Face · GGUF", icon: "network",
                title: loc.t("Explora modelos de la comunidad", "Explore community models"),
                detail: loc.t("Busca repositorios GGUF, revisa sus cuantizaciones y descarga solo los archivos que necesites.",
                              "Search GGUF repositories, inspect their quantizations, and download only the files you need."),
                primaryValue: "\(search.didSearch ? search.results.count : search.trending.count)",
                primaryLabel: loc.t("resultados", "results"),
                secondaryValue: "GGUF", secondaryLabel: loc.t("formato local", "local format"),
                actionTitle: "Hugging Face"
            ) {
                if let url = URL(string: "https://huggingface.co/models?library=gguf") {
                    NSWorkspace.shared.open(url)
                }
            }

            HStack(spacing: 8) {
                GlassSearchField(placeholder: loc.t("Buscar GGUF en Hugging Face…", "Search GGUF on Hugging Face…"),
                                 text: $search.query)
                    .onSubmit { Task { await search.search() } }
                    .onChange(of: search.query) {
                        if search.query.isEmpty { search.didSearch = false }
                    }

                Button(loc.t("Buscar", "Search"), systemImage: "magnifyingglass") {
                    Task { await search.search() }
                }
                .glassButton(prominent: true)
                .labelStyle(.titleOnly)
                .disabled(search.query.isEmpty || search.searching)
                .opacity(search.searching ? 0.6 : 1)
            }

            HStack(alignment: .center, spacing: 10) {
                Text(loc.t("Ordenar", "Sort by"))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ModelFilterBar(selection: $search.sort, filters: HFSortOrder.allCases.map {
                    .init(value: $0, title: sortTitle($0), systemImage: sortIcon($0))
                })
                .onChange(of: search.sort) { Task { await search.reload() } }
                .help(loc.t("Orden en el que Hugging Face devuelve los repositorios; siempre limitado a los que publican GGUF. «Recientes» además exige un mínimo de descargas, para no llenarse de repositorios recién subidos que nadie usa.",
                            "The order Hugging Face returns repositories in, always limited to those publishing GGUF. “Recent” also requires a minimum number of downloads, so it doesn't fill up with freshly pushed repos nobody uses."))
                if search.searching || search.loadingTrending {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
            }

            if search.didSearch && !search.query.isEmpty {
                if search.results.isEmpty && !search.searching {
                    ContentUnavailableView.search(text: search.query)
                } else {
                    SectionHeader(icon: "magnifyingglass",
                                  title: loc.t("Resultados", "Results"), subtitle: nil)
                    LazyVStack(spacing: 12) {
                        ForEach(search.results) { RepoCard(repo: $0) }
                    }
                }
            } else {
                SectionHeader(icon: sortIcon(search.sort),
                              title: loc.t("Modelos GGUF en Hugging Face", "GGUF models on Hugging Face"),
                              subtitle: loc.t("Despliega un repositorio para ver sus cuantizaciones y si caben.",
                                              "Expand a repo to see its quants and whether they fit."))
                LazyVStack(spacing: 12) {
                    ForEach(search.trending) { RepoCard(repo: $0) }
                }
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

    private var isVisionRepo: Bool { search.visionRepos.contains(repo.id) }
    private var verifiedVision: Bool {
        Catalog.models.contains { $0.isVision && $0.urlString.contains(repo.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Task { await search.toggleFiles(repo: repo.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: search.expanded == repo.id ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary).frame(width: 12)
                    Text(repo.id).font(.callout.weight(.medium)).lineLimit(1)
                    // Once expanded, the file list is loaded; a sibling mmproj means
                    // it's a vision model (the projector is fetched with the model).
                    if isVisionRepo {
                        TagBadge(text: loc.t("Visión", "Vision"), icon: "eye", color: .purple)
                        if verifiedVision {
                            Label(loc.t("Verificado", "Verified"), systemImage: "checkmark.seal.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.green.opacity(0.16), in: Capsule())
                                .foregroundStyle(.green)
                        } else {
                            Label(loc.t("Sin verificar", "Unverified"), systemImage: "exclamationmark.triangle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.orange.opacity(0.18), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    if let l = repo.likes {
                        Label("\(l)", systemImage: "heart").font(.caption).foregroundStyle(.secondary)
                    }
                    if let d = repo.downloads {
                        Label(compact(d), systemImage: "arrow.down.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let updated = repo.lastModified, updated > .distantPast {
                        Text(updated, format: .relative(presentation: .named))
                            .font(.caption).foregroundStyle(.secondary)
                            .help(loc.t("Última actualización del repositorio", "Repository last updated"))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(12)

            if search.expanded == repo.id {
                Divider()
                if isVisionRepo && !verifiedVision {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(loc.t("Visión sin verificar. Con el botón de visión se descarga el proyector (mmproj) que mejor coincida, pero no se garantiza la compatibilidad. Si la visión falla, comprueba que el mmproj corresponda a este modelo.",
                                   "Unverified vision. The vision button downloads the best-matching projector (mmproj), but compatibility isn't guaranteed. If vision fails, check that the mmproj matches this model."))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12))
                }
                Group {
                    if let files = search.files[repo.id] {
                        if files.isEmpty {
                            Text(loc.t("Sin archivos .gguf directos", "No direct .gguf files"))
                                .font(.caption).foregroundStyle(.secondary).padding(12)
                        } else {
                            LazyVStack(spacing: 8) {
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
        .cardSurface()
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
    @State private var visionBusy = false

    private var repoHasVision: Bool { search.visionRepos.contains(repo) }
    private var stem: String { URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent }
    private var projName: String { stem + ".mmproj.gguf" }
    private var draftName: String { stem + ".dflash.gguf" }

    var body: some View {
        let est = Estimator.estimateCurrent(
            spec: .estimated(fileBytes: file.sizeBytes, isMoE: search.isMoE(repo: repo, file: file),
                             name: URL(fileURLWithPath: file.path).lastPathComponent), hw: hardware)
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                ModelTitleLabel(ModelName.forPath(file.path), titleFont: .caption)
                EstimateLine(est: est)
            }
            Spacer()
            Text(file.sizeGB).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                modelPill(est: est)
                if repoHasVision { visionPill }
                if let draft = search.draftRepos[repo] { dflashPill(draft) }
            }
        }
    }

    private func modelPill(est: MemoryEstimate) -> some View {
        let names = file.paths.map { URL(fileURLWithPath: $0).lastPathComponent }
        return AssetDownloadButton(
            icon: "arrow.down.circle", label: loc.t("Modelo", "Model"), prominent: true,
            help: loc.t("Descargar el modelo base", "Download the base model"),
            downloaded: names.allSatisfy { models.isDownloaded(fileName: $0) },
            item: names.compactMap { models.downloadItem(fileName: $0) }.first,
            busy: false, disabledReason: est.level == .no ? loc.t("No cabe", "Won't fit") : nil) {
            for path in file.paths where !models.isDownloaded(fileName: URL(fileURLWithPath: path).lastPathComponent) {
                models.download(urlString: search.downloadURL(repo: repo, file: path), fetchVisionProjector: false)
            }
        }
    }

    // Vision (mmproj) is opt-in. The spinner covers the HF tree lookup before the
    // transfer is queued (the projector lives as a sibling in the same repo).
    private var visionPill: some View {
        AssetDownloadButton(
            icon: "eye.circle", label: loc.t("Visión", "Vision"),
            help: loc.t("Descargar el proyector de visión (mmproj)", "Download the vision projector (mmproj)"),
            downloaded: models.isDownloaded(fileName: projName),
            item: models.downloadItem(fileName: projName), busy: visionBusy, disabledReason: nil) {
            visionBusy = true
            Task {
                await models.autoFetchProjector(for: URL(string: search.downloadURL(repo: repo, file: file.path))!)
                visionBusy = false
            }
        }
    }

    private func dflashPill(_ draft: SearchStore.DraftInfo) -> some View {
        AssetDownloadButton(
            icon: "bolt.circle", label: "DFlash",
            help: loc.t("Descargar el draft DFlash para decodificación especulativa (experimental). Por ahora acelera la generación en modelos MoE con expertos en CPU (offload); en denso a GPU completa puede ser más lento.",
                        "Download the DFlash draft for speculative decoding (experimental). For now it speeds up generation on MoE models with CPU-offloaded experts; on full-GPU dense models it can be slower."),
            downloaded: models.isDownloaded(fileName: draftName),
            item: models.downloadItem(fileName: draftName), busy: false, disabledReason: nil) {
            models.downloadDflashDraft(repo: draft.repo, file: draft.file, modelStem: stem)
        }
    }
}

/// One download control in a consistent visual language across the base model,
/// vision projector and DFlash draft: a tinted pill that becomes a live progress
/// bar while transferring and a green check once present.
private struct AssetDownloadButton: View {
    let icon: String
    let label: String
    var prominent = false
    let help: String
    let downloaded: Bool
    let item: DownloadItem?
    let busy: Bool
    let disabledReason: String?
    let action: () -> Void

    var body: some View {
        Group {
            if let item, !item.finished, item.error == nil {
                InlineDownloadProgress(item: item)
            } else if downloaded {
                Label(label, systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.green)
            } else if busy {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
            } else if let reason = disabledReason {
                Text(reason).font(.caption).foregroundStyle(.red)
            } else {
                Button(label, systemImage: icon, action: action)
                    .font(.caption)
                    .glassButton(prominent: prominent)
                    .controlSize(.small)
            }
        }
        .fixedSize()
        .help(help)
    }
}

// MARK: - My models tab

private struct MyModelsTab: View {
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var modelUpdates: ModelUpdateChecker
    @EnvironmentObject var loc: Localizer
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""
    @AppStorage(SettingsKeys.ncmoe) private var ncmoe = 0
    @State private var customURL = ""
    @State private var pendingDelete: LocalModel?
    @State private var pendingUpdate: LocalModel?
    @State private var filter: LocalFilter = .all
    @State private var query = ""

    enum LocalFilter: CaseIterable, Hashable { case all, vision, mtp, dflash, moe }

    private func label(_ f: LocalFilter) -> String {
        switch f {
        case .all: return loc.t("Todos", "All")
        case .vision: return loc.t("Visión", "Vision")
        case .mtp: return "MTP"
        case .dflash: return "DFlash"
        case .moe: return "MoE"
        }
    }

    private func icon(_ f: LocalFilter) -> String {
        switch f {
        case .all: return "square.grid.2x2"
        case .vision: return "eye"
        case .mtp: return "hare"
        case .dflash: return "bolt"
        case .moe: return "square.stack.3d.up"
        }
    }

    private struct LibraryIndex {
        var visible: [LocalModel] = []
        var counts: [LocalFilter: Int] = [:]
        var totalBytes: Int64 = 0
    }

    /// One pass and one cache lookup per model. Previously every filter count
    /// traversed the whole library, which was visible as stutter on large folders.
    private var libraryIndex: LibraryIndex {
        var result = LibraryIndex()
        result.counts[.all] = models.models.count
        for model in models.models {
            result.totalBytes += model.sizeBytes
            let traits = ModelTraitsCache.cached(for: model.url.path) ?? .unknown
            let matches: [LocalFilter] = [
                traits.hasVision ? .vision : nil,
                traits.hasMTP ? .mtp : nil,
                traits.hasDflash ? .dflash : nil,
                traits.isMoE ? .moe : nil,
            ].compactMap { $0 }
            for match in matches { result.counts[match, default: 0] += 1 }
            let matchesFilter = filter == .all || matches.contains(filter)
            let matchesQuery = query.isEmpty || model.name.localizedCaseInsensitiveContains(query)
            if matchesFilter && matchesQuery {
                result.visible.append(model)
            }
        }
        return result
    }

    var body: some View {
        let library = libraryIndex
        VStack(alignment: .leading, spacing: 16) {
            ModelCollectionHero(
                eyebrow: loc.t("EN ESTE MAC", "ON THIS MAC"), icon: "internaldrive",
                title: loc.t("Tu biblioteca local", "Your local library"),
                detail: loc.t("Administra modelos, configuraciones y archivos descargados desde un solo lugar.",
                              "Manage downloaded models, settings, and files in one place."),
                primaryValue: "\(models.models.count)", primaryLabel: loc.t("modelos", "models"),
                secondaryValue: ByteCountFormatter.string(fromByteCount: library.totalBytes, countStyle: .file),
                secondaryLabel: loc.t("almacenamiento", "storage"),
                actionTitle: loc.t("Mostrar carpeta", "Show folder"), actionIcon: "folder"
            ) {
                NSWorkspace.shared.open(models.directory)
            }

            if !models.downloads.isEmpty {
                SectionHeader(icon: "arrow.down.circle", title: loc.t("Descargas", "Downloads"), subtitle: nil)
                VStack(spacing: 8) {
                    ForEach(models.downloads) { DownloadRow(item: $0) }
                }
                Button(loc.t("Limpiar terminadas", "Clear finished"), systemImage: "checkmark.circle") {
                    models.clearFinishedDownloads()
                }
                .glassButton()
                .controlSize(.small)
            }

            if !models.models.isEmpty {
                ModelSearchAndFilters(placeholder: loc.t("Buscar en tu biblioteca…", "Search your library…"), text: $query) {
                    ModelFilterBar(selection: $filter, filters: LocalFilter.allCases.map {
                        .init(value: $0, title: label($0), systemImage: icon($0), count: library.counts[$0, default: 0])
                    })
                }
            }
            if models.models.isEmpty {
                ContentUnavailableView(loc.t("Todavía no hay modelos", "No models yet"),
                                       systemImage: "internaldrive",
                                       description: Text(loc.t("Descarga uno desde Recomendados o Buscar y aparecerá aquí.",
                                                               "Download one from Recommended or Browse and it will show up here.")))
            } else if library.visible.isEmpty {
                ContentUnavailableView(loc.t("Ningún modelo con esa característica", "No model with that trait"),
                                       systemImage: icon(filter),
                                       description: Text(loc.t("Ninguno de tus modelos descargados la tiene.",
                                                               "None of your downloaded models has it.")))
            } else {
                LazyVStack(spacing: 1) {
                    ForEach(library.visible) { m in
                        LocalModelCard(model: m, pendingDelete: $pendingDelete, pendingUpdate: $pendingUpdate)
                    }
                }
                .background(WorkspaceStyle.border)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WorkspaceStyle.border))
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(icon: "link",
                              title: loc.t("Descarga directa", "Direct download"),
                              subtitle: loc.t("Añade un archivo GGUF desde una URL.", "Add a GGUF file from a URL."))
                HStack {
                    TextField("https://huggingface.co/…/resolve/main/model.gguf", text: $customURL)
                        .textFieldStyle(.plain).padding(.horizontal, 11).padding(.vertical, 8)
                        .background(WorkspaceStyle.inset, in: RoundedRectangle(cornerRadius: 8))
                    Button(loc.t("Descargar", "Download"), systemImage: "arrow.down.circle") {
                        models.download(urlString: customURL)
                        customURL = ""
                    }
                    .glassButton(prominent: true)
                    .disabled(!customURL.hasPrefix("http"))
                }
            }
            .padding(14)
            .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WorkspaceStyle.border))
        }
        .padding(16)
        .task { await modelUpdates.checkIfStale(models.models) }
        .confirmationDialog(
            loc.t("¿Actualizar %@?", "Update %@?", "\(pendingUpdate?.name ?? "")"),
            isPresented: Binding(get: { pendingUpdate != nil }, set: { if !$0 { pendingUpdate = nil } })
        ) {
            Button(loc.t("Descargar y reemplazar", "Download and replace")) {
                if let m = pendingUpdate { models.update(m) }
                pendingUpdate = nil
            }
            Button(loc.t("Cancelar", "Cancel"), role: .cancel) { pendingUpdate = nil }
        } message: {
            Text(loc.t("Se descarga de nuevo desde su repositorio y el archivo actual se reemplaza al verificarse el checksum. Si el modelo está cargado, reinicia el servidor al terminar.",
                       "It is downloaded again from its repo and the current file is replaced once the checksum verifies. If the model is loaded, restart the server afterwards."))
        }
        .confirmationDialog(
            loc.t("¿Eliminar %@?", "Delete %@?", "\(pendingDelete?.name ?? "")"),
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
        } message: {
            if let m = pendingDelete, ServerSettings.mmprojPath(forModel: m.url.path) != nil {
                Text(loc.t("Se eliminará también su archivo de visión (mmproj).",
                           "Its vision file (mmproj) will be removed too."))
            }
        }
    }
}

// MARK: - Catalog

/// Native-style catalog container: dense rows scan faster and avoid the large
/// empty areas created by a three-column card grid.
private struct CatalogList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVStack(spacing: 1) { content }
            .background(WorkspaceStyle.border)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WorkspaceStyle.border))
    }
}

private struct CatalogModelRow: View {
    let model: CatalogModel
    let est: MemoryEstimate
    let role: Catalog.Recommendation.Role?
    var selected = false
    var onSelect: (() -> Void)?
    @EnvironmentObject private var loc: Localizer

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                identity.frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
                estimateColumn(est.expectedSpeed, label: loc.t("Velocidad", "Speed"), icon: "bolt")
                    .frame(width: 120, alignment: .leading)
                estimateColumn(String(format: "%.1f GB", est.vramGB), label: "VRAM", icon: "memorychip")
                    .frame(width: 90, alignment: .leading)
                compatibility.frame(width: 105, alignment: .leading)
                CatalogActionButton(model: model, est: est).frame(width: 108, alignment: .trailing)
            }
            HStack(alignment: .center, spacing: 14) {
                identity
                Spacer(minLength: 8)
                CatalogActionButton(model: model, est: est)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(selected ? Color.appAccent.opacity(0.10) : WorkspaceStyle.surface)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Color.appAccent).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
        .help(model.detail(loc.isSpanish))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var identity: some View {
        HStack(spacing: 13) {
            ModelBrandIcon(name: model.name, size: 38)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(ModelName(model.name).title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if let role { RoleChip(role: role) }
                    if model.isVision { TagBadge(text: loc.t("Visión", "Vision"), icon: "eye", color: .purple) }
                    if model.isCoder { TagBadge(text: "Coder", icon: "chevron.left.forwardslash.chevron.right", color: .blue) }
                    if model.isMoE { MoEBadge() }
                }
                Text(model.detail(loc.isSpanish))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Text(String(format: "%.1f GB", model.spec.fileGB))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
    }

    private var compatibility: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(compatibilityText, systemImage: est.level == .no ? "xmark.circle" : "circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(est.level == .ideal ? .green : est.level == .no ? .red : .orange)
            Text(loc.t("Compatibilidad", "Compatibility")).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private var compatibilityText: String {
        switch est.level {
        case .ideal: return loc.t("GPU completa", "Full GPU")
        case .good: return loc.t("Híbrido", "Hybrid")
        case .slow: return loc.t("Lento", "Slow")
        case .no: return loc.t("No cabe", "Won't fit")
        }
    }

    private func estimateColumn(_ value: String, label: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(value, systemImage: icon).font(.system(size: 11, weight: .medium)).lineLimit(1)
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
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
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct MoEBadge: View {
    var body: some View { TagBadge(text: "MoE", icon: "square.stack.3d.up", color: Color.appAccent) }
}

/// Small capsule tag (MoE / Vision / MTP / DFlash / Coder) shown on model cards.
/// The icon carries the meaning where color alone would.
struct TagBadge: View {
    let text: String
    var icon: String?
    let color: Color

    var body: some View {
        Group {
            if let icon {
                Label(text, systemImage: icon)
            } else {
                Text(text)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(color.opacity(0.16), in: Capsule())
    }
}

struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var models: ModelStore

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
                        .lineLimit(2).frame(maxWidth: 300, alignment: .trailing)
                    Button(loc.t("Reintentar", "Retry"), systemImage: "arrow.clockwise") {
                        models.retry(item)
                    }
                    .glassButton()
                    .controlSize(.small)
                    .help(loc.t("Reintentar la descarga desde cero.", "Retry the download from scratch."))
                case .downloading, .paused:
                    Text(String(format: "%.0f / %.0f MB", item.receivedMB, item.totalMB))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    if item.phase == .paused {
                        Button { item.resume() } label: { Label(loc.t("Reanudar", "Resume"), systemImage: "play.circle") }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .iconHelp(loc.t("Reanudar", "Resume"))
                    } else {
                        Button { item.pause() } label: { Label(loc.t("Pausar", "Pause"), systemImage: "pause.circle") }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .iconHelp(loc.t("Pausar (reanudable)", "Pause (resumable)"))
                    }
                    Button { item.cancel() } label: { Label(loc.t("Cancelar", "Cancel"), systemImage: "xmark.circle") }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .iconHelp(loc.t("Cancelar", "Cancel"))
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
