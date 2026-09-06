// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A downloaded model in the grid; its per-model configuration lives in the popover.
struct LocalModelCard: View {
    let model: LocalModel
    @Binding var pendingDelete: LocalModel?
    @Binding var pendingUpdate: LocalModel?
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var modelUpdates: ModelUpdateChecker
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""
    @State private var showingSettings = false

    var body: some View {
        let path = model.url.path
        let traits = ModelTraitsCache.cached(for: path) ?? .unknown
        let parsed = ModelName.forPath(path)
        let est = Estimator.estimateCurrent(spec: Catalog.spec(forLocal: model), hw: hardware,
                                            ncmoeOverride: ServerSettings.recalledNcmoe(forModel: path))
        let active = modelPath == path
        let updatable = modelUpdates.state(for: model).isAvailable
            && models.downloadItem(fileName: model.name) == nil

        VStack(alignment: .leading, spacing: CardMetrics.spacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(parsed.title)
                    .font(.headline)
                    .lineLimit(1)
                    .help(model.name)
                Spacer(minLength: 4)
                if !parsed.quant.isEmpty {
                    Text(parsed.quant)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                }
                Text(model.sizeGB)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
            }

            HStack(spacing: 6) {
                ModelTraitBadges(traits: traits)
                Spacer(minLength: 0)
            }

            EstimateLine(est: est)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                if active {
                    Label(loc.t("Activo", "Active"), systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.green)
                } else {
                    UseModelButton(path: path, modelName: model.name).controlSize(.small)
                }
                if updatable {
                    Button(loc.t("Actualizar", "Update"), systemImage: "arrow.down.circle") {
                        pendingUpdate = model
                    }
                    .glassButton()
                    .controlSize(.small)
                    .help(loc.t("Su repositorio publica una versión distinta de este archivo.",
                                "Its repo publishes a different version of this file."))
                }
                Spacer(minLength: 0)
                if traits.hasDflash || ServerSettings.mightSupportVision(modelPath: path) {
                    Button(loc.t("Ajustes del modelo", "Model settings"), systemImage: "slider.horizontal.3") {
                        showingSettings = true
                    }
                    .buttonStyle(.borderless).labelStyle(.iconOnly)
                    .help(loc.t("Visión y borrador DFlash para este modelo.",
                                "Vision and DFlash draft for this model."))
                    .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                        LocalModelSettingsPopover(model: model, traits: traits)
                    }
                }
                LocalModelMenu(model: model, traits: traits, updatable: updatable,
                               pendingDelete: $pendingDelete, pendingUpdate: $pendingUpdate)
            }
        }
        .padding(CardMetrics.padding)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .cardSurface(tint: active ? .green : nil)
    }
}

private struct LocalModelMenu: View {
    let model: LocalModel
    let traits: ModelTraits
    let updatable: Bool
    @Binding var pendingDelete: LocalModel?
    @Binding var pendingUpdate: LocalModel?
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var models: ModelStore

    var body: some View {
        Menu(loc.t("Más acciones", "More actions"), systemImage: "ellipsis") {
            Button(loc.t("Mostrar en Finder", "Reveal in Finder"), systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.url])
            }
            if updatable {
                Button(loc.t("Actualizar modelo", "Update model"), systemImage: "arrow.down.circle") {
                    pendingUpdate = model
                }
            }
            if let visionCatalog = models.missingVisionProjector(for: model) {
                Button(loc.t("Descargar archivo de visión", "Download vision file"),
                       systemImage: "photo.badge.arrow.down") {
                    models.downloadProjector(for: visionCatalog)
                }
            }
            Divider()
            Button(loc.t("Eliminar…", "Delete…"), systemImage: "trash", role: .destructive) {
                pendingDelete = model
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
            .labelStyle(.iconOnly)
        .fixedSize()
        .help(loc.t("Mostrar en Finder, actualizar o eliminar este modelo.",
                    "Reveal in Finder, update or delete this model."))
    }
}

private struct LocalModelSettingsPopover: View {
    let model: LocalModel
    let traits: ModelTraits
    @EnvironmentObject var loc: Localizer

    var body: some View {
        let parsed = ModelName.forPath(model.url.path)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(parsed.title).font(.headline).lineLimit(1)
                Text(parsed.quant.isEmpty ? model.sizeGB : "\(parsed.quant) · \(model.sizeGB)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            Form {
                if ServerSettings.mightSupportVision(modelPath: model.url.path) {
                    Section {
                        VisionProjectorControl(modelPath: model.url.path, layout: .settings)
                    } header: {
                        Text(loc.t("Visión", "Vision"))
                    } footer: {
                        Text(loc.t("El proyector (mmproj) es el archivo que convierte la imagen en algo que el modelo entiende. En automático se empareja el de esta carpeta.",
                                   "The projector (mmproj) is the file that turns an image into something the model understands. Automatic pairs the one in this folder."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if traits.hasDflash {
                    Section {
                        DflashControl(modelPath: model.url.path, layout: .settings)
                    } header: {
                        Text("DFlash")
                    } footer: {
                        Text(loc.t("Un modelo pequeño adelanta tokens que este verifica. Auto lo usa solo cuando queda memoria de sobra.",
                                   "A small model drafts tokens this one verifies. Auto only uses it when memory allows."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    ModelExtraArgsControl(modelPath: model.url.path)
                } header: {
                    Text(loc.t("Argumentos extra", "Extra arguments"))
                } footer: {
                    Text(loc.t("Se añaden a los de Ajustes y solo se aplican a este modelo, por ejemplo un cabezal MTP en otro archivo.",
                               "Added to the ones in Settings and applied to this model only, an MTP head in a separate file for instance."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
        .frame(width: 360)
    }
}
