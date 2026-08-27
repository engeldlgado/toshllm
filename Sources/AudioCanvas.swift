// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

struct AudioCanvas: View {
    @ObservedObject var studio: AudioStudioController
    @EnvironmentObject private var loc: Localizer
    @AppStorage(SettingsKeys.audioExportFormat) private var exportFormatRaw = AudioExportFormat.srt.rawValue
    @AppStorage(SettingsKeys.audioExportTrack) private var exportTrackRaw = AudioExportTrack.translated.rawValue
    @AppStorage(SettingsKeys.audioTranscriptMode) private var transcriptModeRaw = AudioTranscriptMode.original.rawValue
    @AppStorage(SettingsKeys.audioTargetLanguage) private var targetLanguage = "Español"
    @AppStorage(SettingsKeys.audioGlossary) private var glossary = ""
    @AppStorage(SettingsKeys.audioTranslationModel) private var translationModel = ""
    @AppStorage(SettingsKeys.audioFollowTranscript) private var followTranscript = true
    @StateObject private var videoExporter = SubtitleVideoExporter()
    @State private var dropTargeted = false
    @State private var editing = false
    @State private var exportError = ""
    @State private var showExportError = false

    private var exportFormat: AudioExportFormat {
        AudioExportFormat(rawValue: exportFormatRaw) ?? .srt
    }
    private var exportTrack: AudioExportTrack {
        AudioExportTrack(rawValue: exportTrackRaw) ?? .translated
    }

    var body: some View {
        Group {
            if studio.sourceURL == nil {
                emptyDropZone
            } else {
                VStack(spacing: 0) {
                    AudioMediaPreview(studio: studio)
                        .padding(16)
                    Divider()
                    resultHeader
                    SubtitlePreview(studio: studio, followPlayback: $followTranscript,
                                    editing: editing)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropTargeted ? Color.appAccent.opacity(0.08) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, Self.accepts(url), !studio.isBusy else { return false }
            studio.select(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .alert(loc.t("No se pudo exportar", "Could not export"),
               isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError)
        }
        .onChange(of: transcriptModeRaw) { _, value in
            studio.setTranscriptMode(AudioTranscriptMode(rawValue: value) ?? .original)
        }
        .onChange(of: studio.hasTranslation) { _, available in
            guard available else { return }
            let preferred = AudioTranscriptMode(rawValue: transcriptModeRaw) ?? .bilingual
            studio.setTranscriptMode(preferred == .original ? .bilingual : preferred)
            transcriptModeRaw = studio.transcriptMode.rawValue
        }
        .onChange(of: videoExporter.error) { _, message in
            guard let message else { return }
            exportError = message
            showExportError = true
        }
        .onChange(of: videoExporter.completedURL) { _, url in
            guard let url else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private var emptyDropZone: some View {
        ContentUnavailableView {
            Label(loc.t("Audio y subtítulos", "Audio and subtitles"),
                  systemImage: "waveform.and.mic")
        } description: {
            Text(loc.t("Arrastra aquí una película, una grabación o una pista de audio para transcribirla localmente con la GPU.",
                       "Drop a movie, recording, or audio track here to transcribe it locally on the GPU."))
        } actions: {
            Button(loc.t("Elegir archivo…", "Choose file…"),
                   systemImage: "folder", action: pickMedia)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help(loc.t("Selecciona un archivo de audio o vídeo del Mac.",
                            "Select an audio or video file from your Mac."))
            Button(loc.t("Abrir proyecto…", "Open project…"),
                   systemImage: "folder.badge.gearshape", action: openProject)
                .help(loc.t("Abre una transcripción guardada sin volver a procesarla.",
                            "Opens a saved transcript without processing it again."))
            if studio.hasRecoveryProject {
                Button(loc.t("Recuperar último trabajo", "Recover last work"),
                       systemImage: "clock.arrow.circlepath", action: recoverProject)
                    .help(loc.t("Restaura el último trabajo guardado automáticamente.",
                                "Restores the last automatically saved work."))
            }
        }
    }

    private var resultHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(loc.t("Subtítulos", "Subtitles"))
                    .font(.headline)
                if !studio.cues.isEmpty {
                    Text(resultSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu(loc.t("Proyecto", "Project"), systemImage: "folder.badge.gearshape") {
                Button(loc.t("Abrir proyecto…", "Open project…"), systemImage: "folder",
                       action: openProject)
                Button(loc.t("Guardar proyecto…", "Save project…"), systemImage: "square.and.arrow.down",
                       action: saveProject)
                    .disabled(studio.originalCues.isEmpty)
                if studio.hasRecoveryProject {
                    Button(loc.t("Recuperar último trabajo", "Recover last work"),
                           systemImage: "clock.arrow.circlepath", action: recoverProject)
                }
            }
            .help(loc.t("Guarda o recupera la transcripción, traducción y glosario sin reprocesar.",
                        "Saves or restores the transcript, translation, and glossary without reprocessing."))
            if !studio.cues.isEmpty {
                if studio.hasTranslation {
                    Picker(loc.t("Vista", "View"), selection: $transcriptModeRaw) {
                        Text(loc.t("Original", "Original")).tag(AudioTranscriptMode.original.rawValue)
                        Text(loc.t("Traducción", "Translation")).tag(AudioTranscriptMode.translated.rawValue)
                        Text(loc.t("Ambos", "Both")).tag(AudioTranscriptMode.bilingual.rawValue)
                    }
                    .labelsHidden()
                    .frame(width: 105)
                    .help(loc.t("Muestra la transcripción original, la traducción o ambas juntas.",
                                "Shows the original transcript, the translation, or both together."))
                }
                Toggle(isOn: $followTranscript) {
                    Label(loc.t("Seguir", "Follow"), systemImage: "location.fill")
                }
                .toggleStyle(.button)
                .help(loc.t("Mantiene visible el subtítulo que corresponde a la reproducción.",
                            "Keeps the subtitle matching playback visible."))
                Toggle(isOn: $editing) {
                    Label(loc.t("Editar", "Edit"), systemImage: "pencil")
                }
                .toggleStyle(.button)
                .help(loc.t("Permite corregir, dividir, unir o eliminar segmentos.",
                            "Allows correcting, splitting, merging, or deleting segments."))
                Button(loc.t("Copiar texto", "Copy text"), systemImage: "doc.on.doc", action: copyText)
                    .help(loc.t("Copia el texto sin marcas de tiempo.",
                                "Copies the text without timestamps."))
                Menu(loc.t("Exportar", "Export"), systemImage: "square.and.arrow.up") {
                    Picker(loc.t("Formato", "Format"), selection: $exportFormatRaw) {
                        ForEach(AudioExportFormat.allCases) { format in
                            Text(format.rawValue.uppercased()).tag(format.rawValue)
                        }
                    }
                    Picker(loc.t("Contenido", "Content"), selection: $exportTrackRaw) {
                        Text(loc.t("Original", "Original")).tag(AudioExportTrack.original.rawValue)
                        Text(loc.t("Traducción", "Translation")).tag(AudioExportTrack.translated.rawValue)
                        Text(loc.t("Bilingüe", "Bilingual")).tag(AudioExportTrack.bilingual.rawValue)
                    }
                    Divider()
                    Button(loc.t("Guardar subtítulos…", "Save subtitles…"),
                           systemImage: "doc.badge.arrow.up", action: exportResult)
                    if studio.isVideo {
                        Button(loc.t("Crear vídeo subtitulado…", "Create captioned video…"),
                               systemImage: "film", action: exportCaptionedVideo)
                            .disabled(videoExporter.isExporting)
                    }
                }
                .buttonStyle(.borderedProminent)
                .help(loc.t("Elige formato y pista; guarda subtítulos o una copia MOV con texto incrustado.",
                            "Choose format and track; save subtitles or a MOV copy with burned-in text."))
            }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            if videoExporter.isExporting {
                Divider()
                AudioExportProgressBar(exporter: videoExporter)
            }
        }
    }

    private var resultSummary: String {
        let words = studio.cues.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        let language = studio.detectedLanguage.isEmpty ? "" : " · \(studio.detectedLanguage.uppercased())"
        let translating = studio.translationBatchCount > 0 && studio.stage == .translating
        let translationES = translating
            ? " · \(studio.translatedBatchCount)/\(studio.translationBatchCount) traducidos" : ""
        let translationEN = translating
            ? " · \(studio.translatedBatchCount)/\(studio.translationBatchCount) translated" : ""
        return loc.t("\(studio.cues.count) segmentos · \(words) palabras\(language)\(translationES)",
                     "\(studio.cues.count) segments · \(words) words\(language)\(translationEN)")
    }

    private func pickMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        studio.select(url)
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(studio.content(for: .text, track: exportTrack), forType: .string)
    }

    private func exportResult() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: exportFormat.fileExtension) ?? .plainText]
        let base = studio.sourceURL?.deletingPathExtension().lastPathComponent ?? "transcript"
        panel.nameFieldStringValue = "\(base).\(exportFormat.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try studio.content(for: exportFormat, track: exportTrack)
                .write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportError = error.localizedDescription
            showExportError = true
        }
    }

    private func saveProject() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let base = studio.sourceURL?.deletingPathExtension().lastPathComponent ?? "audio"
        panel.nameFieldStringValue = "\(base).tosh-audio.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try studio.saveProject(to: url, targetLanguage: targetLanguage, glossary: glossary)
        } catch {
            exportError = error.localizedDescription
            showExportError = true
        }
    }

    private func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try studio.loadProject(from: url)
            targetLanguage = studio.translationTargetLanguage
            glossary = studio.translationGlossary
            translationModel = studio.translationModel
            transcriptModeRaw = studio.transcriptMode.rawValue
        } catch {
            exportError = error.localizedDescription
            showExportError = true
        }
    }

    private func exportCaptionedVideo() {
        guard let sourceURL = studio.sourceURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = "\(sourceURL.deletingPathExtension().lastPathComponent)-subtitulado.mov"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        videoExporter.export(sourceURL: sourceURL, cues: studio.exportCues(for: exportTrack),
                             outputURL: outputURL)
    }

    private func recoverProject() {
        do {
            try studio.loadRecoveryProject()
            targetLanguage = studio.translationTargetLanguage
            glossary = studio.translationGlossary
            translationModel = studio.translationModel
            transcriptModeRaw = studio.transcriptMode.rawValue
        } catch {
            exportError = error.localizedDescription
            showExportError = true
        }
    }

    private static func accepts(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
    }
}
