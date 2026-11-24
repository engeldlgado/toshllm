// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Per-model MTP policy. The engine still chooses the embedded head or matching
/// assistant automatically; this control decides whether that acceleration is allowed,
/// and which head drafts when several files fit the model.
/// `inline` is one compact row; `settings` is a form section.
struct MTPControl: View {
    enum Layout { case inline, settings, detail }

    let modelPath: String
    var layout: Layout = .detail
    @EnvironmentObject private var loc: Localizer
    // "off", "auto", a head path, or "" while several heads wait for a choice
    @State private var choice = "auto"
    @State private var heads: [String] = []

    private var sourceText: String {
        ServerSettings.modelHasMTP(at: modelPath)
            ? loc.t("Cabezal MTP integrado", "Embedded MTP head")
            : loc.t("Borrador MTP externo", "External MTP draft")
    }

    private var helpText: String {
        heads.count > 1
            ? loc.t("Varios archivos de cabezal sirven para este modelo: elige con cuál predice varios tokens por paso. Con textos que acepta poco puede generar más lento que sin él; Desactivado genera un token por paso. Se aplica al reiniciar el servidor.",
                    "Several head files fit this model: choose the one that predicts several tokens per step. On text it accepts rarely it can generate slower than without it; Disabled generates one token per step. Applies when the server restarts.")
            : loc.t("Automático predice varios tokens por paso con el cabezal del modelo. Con textos que acepta poco puede generar más lento que sin él; Desactivado genera un token por paso. Se aplica al reiniciar el servidor.",
                    "Automatic predicts several tokens per step with the model's head. On text it accepts rarely it can generate slower than without it; Disabled generates one token per step. Applies when the server restarts.")
    }

    private var options: [ToshDropdown<String>.Option] {
        var list: [ToshDropdown<String>.Option] = []
        if heads.count > 1 {
            if choice.isEmpty {
                list.append(.init(value: "", title: loc.t("Elige un cabezal", "Choose a head"),
                                  subtitle: loc.t("%@ cabezales sirven para este modelo", "%@ heads fit this model", "\(heads.count)"),
                                  systemImage: "questionmark.circle"))
            }
            list += heads.map { .init(value: $0, title: Self.headName($0), subtitle: Self.headSize($0), systemImage: "hare.fill") }
        } else {
            list.append(.init(value: "auto", title: loc.t("Automático", "Automatic"), subtitle: sourceText, systemImage: "hare.fill"))
        }
        list.append(.init(value: "off", title: loc.t("Desactivado", "Disabled"),
                          subtitle: loc.t("Generación de un token por paso", "One-token decoding"), systemImage: "hare"))
        return list
    }

    @ViewBuilder
    var body: some View {
        Group {
            switch layout {
            case .detail: detailRow
            case .settings: settingsRow
            case .inline: inlineRow
            }
        }
        .onAppear {
            heads = ServerSettings.mtpHeadCandidates(forModel: modelPath)
            choice = currentChoice()
        }
        .onChange(of: choice) { _, value in apply(value) }
    }

    private func currentChoice() -> String {
        guard ServerSettings.mtpEnabled(forModel: modelPath) else { return "off" }
        guard heads.count > 1 else { return "auto" }
        return ServerSettings.mtpDraftPath(forModel: modelPath) ?? ""
    }

    private func apply(_ value: String) {
        // showing the state on appear is not a choice
        guard value != currentChoice() else { return }
        ServerSettings.setMTPEnabled(value != "off", forModel: modelPath)
        if heads.contains(value) { ServerSettings.setMTPHead(value, forModel: modelPath) }
    }

    nonisolated static func headName(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    nonisolated static func headSize(_ path: String) -> String? {
        GGUFFile.totalSize(at: path).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }

    private var detailRow: some View {
        ToshDropdown(selection: $choice, options: options, width: 220, listWidth: heads.count > 1 ? 380 : 300)
            .help(helpText)
    }

    private var settingsRow: some View {
        LabeledContent(loc.t("Predicción", "Prediction")) {
            if heads.count > 1 {
                menuPicker
            } else {
                Picker(loc.t("Predicción", "Prediction"), selection: $choice) {
                    Text(loc.t("Desactivado", "Disabled")).tag("off")
                    Text(loc.t("Automático", "Automatic")).tag("auto")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
        .help(helpText)
    }

    private var inlineRow: some View {
        Group {
            if heads.count > 1 {
                menuPicker.frame(maxWidth: 220)
            } else {
                Picker("MTP", selection: $choice) {
                    Text(loc.t("Off", "Off")).tag("off")
                    Text(loc.t("Auto", "Auto")).tag("auto")
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .font(.caption)
        .help(helpText)
    }

    private var menuPicker: some View {
        Picker("MTP", selection: $choice) {
            ForEach(options) { Text($0.title).tag($0.value) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }
}
