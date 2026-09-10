// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

struct LocalModelDetailsSheet: View {
    let model: LocalModel
    @EnvironmentObject private var loc: Localizer
    @Environment(\.dismiss) private var dismiss

    private var parsed: ModelName { ModelName.forPath(model.url.path) }
    private var metadata: GGUFMetadata? { GGUFMetadataCache.metadata(at: model.url.path) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    informationCard
                    provenanceCard
                    localFilesCard
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 590)
        .background(WorkspaceStyle.canvas)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ModelBrandIcon(name: model.name, size: 48)
            VStack(alignment: .leading, spacing: 5) {
                Text(parsed.title).font(.title2.bold()).lineLimit(2)
                HStack(spacing: 7) {
                    if !parsed.quant.isEmpty { detailChip(parsed.quant, icon: "shippingbox") }
                    detailChip(parsed.family, icon: "cpu")
                    detailChip("GGUF", icon: "doc")
                }
            }
            Spacer(minLength: 12)
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(GlassIconButtonStyle())
                .accessibilityLabel(loc.t("Cerrar", "Close"))
        }
        .padding(18)
    }

    private var informationCard: some View {
        detailCard(title: loc.t("Información del modelo", "Model information"), icon: "info.circle") {
            detailRow(loc.t("Nombre del GGUF", "GGUF name"),
                      metadata?.string(for: "general.name") ?? parsed.title)
            detailRow(loc.t("Arquitectura", "Architecture"),
                      metadata?.string(for: "general.architecture") ?? parsed.family)
            detailRow(loc.t("Cuantización", "Quantization"),
                      metadata?.fileTypeLabel ?? (parsed.quant.isEmpty ? loc.t("No indicada", "Not reported") : parsed.quant))
            if let parameters = parsed.paramsB {
                detailRow(loc.t("Parámetros", "Parameters"), String(format: "%.1fB", parameters))
            }
            detailRow(loc.t("Tipo", "Type"), model.isMoE ? "MoE" : loc.t("Denso", "Dense"))
        }
    }

    private var provenanceCard: some View {
        detailCard(title: loc.t("Procedencia", "Provenance"), icon: "arrow.down.circle") {
            if let source {
                detailRow(loc.t("Registro", "Record"), source.isRecorded
                          ? loc.t("Descargado con ToshLLM", "Downloaded with ToshLLM")
                          : loc.t("Coincidencia del catálogo", "Catalog match"))
                if let repository = source.repository {
                    detailRow(loc.t("Repositorio", "Repository"), repository)
                }
                if let author = source.author {
                    detailRow(loc.t("Autor", "Author"), author)
                }
                if let revision = source.revision {
                    detailRow(loc.t("Revisión", "Revision"), revision)
                }
                detailRow(loc.t("Archivo de origen", "Source file"), source.fileName)
                VStack(alignment: .leading, spacing: 6) {
                    Text(loc.t("URL de descarga", "Download URL"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(source.url.absoluteString)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(WorkspaceStyle.inset, in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    if let repositoryURL = source.repositoryURL {
                        Button(loc.t("Abrir repositorio", "Open repository"), systemImage: "arrow.up.right.square") {
                            NSWorkspace.shared.open(repositoryURL)
                        }
                        .glassButton()
                    }
                    Button(loc.t("Copiar URL", "Copy URL"), systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(source.url.absoluteString, forType: .string)
                    }
                    .glassButton()
                }
            } else {
                Label(loc.t("No hay una fuente de descarga registrada para este archivo.",
                            "No download source is recorded for this file."),
                      systemImage: "questionmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
                Text(loc.t("Puede haberse copiado manualmente a la carpeta de modelos.",
                           "It may have been copied into the models folder manually."))
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var localFilesCard: some View {
        detailCard(title: loc.t("Archivos locales", "Local files"), icon: "internaldrive") {
            detailRow(loc.t("Archivo principal", "Primary file"), model.name)
            detailRow(loc.t("Tamaño total", "Total size"),
                      ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file))
            detailRow(loc.t("Partes", "Parts"), "\(model.partURLs.count)")
            VStack(alignment: .leading, spacing: 6) {
                Text(loc.t("Ubicación", "Location")).font(.caption).foregroundStyle(.secondary)
                Text(model.url.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(loc.t("Mostrar en Finder", "Reveal in Finder"), systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.url])
            }
            .glassButton()
            Spacer()
            Button(loc.t("Cerrar", "Close")) { dismiss() }
                .glassButton(prominent: true)
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private func detailChip(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(WorkspaceStyle.inset, in: Capsule())
            .overlay(Capsule().strokeBorder(WorkspaceStyle.border))
    }

    private func detailCard<Content: View>(title: String, icon: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: icon).font(.headline)
            Divider()
            content()
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).lineLimit(2).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }

    private struct SourceInfo {
        let url: URL
        let isRecorded: Bool

        var components: [String] { url.pathComponents.filter { $0 != "/" } }
        var resolveIndex: Int? { components.firstIndex(of: "resolve") ?? components.firstIndex(of: "blob") }
        var repository: String? {
            guard url.host?.contains("huggingface.co") == true,
                  let index = resolveIndex, index >= 2 else { return nil }
            return components[(index - 2)...(index - 1)].joined(separator: "/")
        }
        var author: String? { repository?.split(separator: "/").first.map(String.init) }
        var revision: String? {
            guard let index = resolveIndex, components.indices.contains(index + 1) else { return nil }
            return components[index + 1]
        }
        var fileName: String { url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent }
        var repositoryURL: URL? { repository.flatMap { URL(string: "https://huggingface.co/\($0)") } }
    }

    private var source: SourceInfo? {
        for part in model.partURLs {
            if let value = ModelStore.source(forFile: part.lastPathComponent), let url = URL(string: value) {
                return SourceInfo(url: url, isRecorded: true)
            }
        }
        if let catalog = Catalog.models.first(where: { $0.fileName == model.name }),
           let url = URL(string: catalog.urlString) {
            return SourceInfo(url: url, isRecorded: false)
        }
        return nil
    }
}
