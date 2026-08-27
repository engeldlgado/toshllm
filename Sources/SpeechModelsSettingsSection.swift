// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct SpeechModelsSettingsSection: View {
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var models: ModelStore
    @AppStorage(SettingsKeys.whisperModel) private var selectedID = WhisperModel.recommendedID
    @AppStorage(SettingsKeys.speechInputMethod) private var methodRaw = ""
    @AppStorage(SettingsKeys.whisperLoadPolicy) private var loadPolicyRaw = WhisperLoadPolicy.onDemand.rawValue

    private var selected: WhisperModel { WhisperModel.model(id: selectedID) }

    var body: some View {
        Section(loc.t("Voz y transcripción", "Speech & transcription")) {
            Picker(loc.t("Método del micrófono", "Microphone method"), selection: $methodRaw) {
                Text(loc.t("Elegir…", "Choose…")).tag("")
                Text(loc.t("Dictado de Apple", "Apple Dictation")).tag(SpeechInputMethod.apple.rawValue)
                Text("Whisper.cpp · GPU").tag(SpeechInputMethod.whisper.rawValue)
            }
            .help(loc.t("Elige el dictado de macOS o Whisper.cpp acelerado por la GPU.",
                        "Choose macOS dictation or GPU-accelerated Whisper.cpp."))

            if methodRaw == SpeechInputMethod.apple.rawValue {
                Text(loc.t("Dictado en vivo con el servicio integrado de macOS. No reserva VRAM.",
                           "Live dictation with macOS's built-in service. It reserves no VRAM."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if methodRaw != SpeechInputMethod.apple.rawValue {
                Picker(loc.t("Carga de Whisper", "Whisper loading"), selection: $loadPolicyRaw) {
                    Text(loc.t("Bajo demanda", "On demand")).tag(WhisperLoadPolicy.onDemand.rawValue)
                    Text(loc.t("Siempre cargado", "Always loaded")).tag(WhisperLoadPolicy.alwaysLoaded.rawValue)
                }
                .help(loc.t("Carga bajo demanda libera VRAM; Siempre cargado reduce la espera del próximo dictado.",
                            "On demand releases VRAM; Always loaded reduces the wait for the next dictation."))

                Text(loadPolicyRaw == WhisperLoadPolicy.alwaysLoaded.rawValue
                     ? loc.t("Conserva el modelo en la VRAM para que el siguiente dictado empiece antes.",
                             "Keeps the model in VRAM so the next dictation starts sooner.")
                     : loc.t("Libera el modelo y su VRAM al terminar cada transcripción.",
                             "Releases the model and its VRAM after each transcription."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

            Picker(loc.t("Modelo Whisper", "Whisper model"), selection: $selectedID) {
                ForEach(WhisperModel.catalog) { model in
                    Text(label(for: model)).tag(model.id)
                }
            }
            .help(loc.t("Elige el equilibrio entre velocidad, uso de VRAM y precisión.",
                        "Choose the balance between speed, VRAM use, and accuracy."))

            LabeledContent(loc.t("Perfil", "Profile")) {
                Text(loc.t(selected.detailES, selected.detailEN))
                    .foregroundStyle(.secondary)
            }

            if models.whisperModelInstalled(selected) {
                Label(loc.t("Instalado y listo para micrófono, audio y video",
                            "Installed and ready for microphone, audio, and video"),
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else if let download = models.whisperDownload(selected) {
                DownloadRow(item: download)
            } else {
                Button {
                    models.downloadWhisperModel(selected)
                } label: {
                    Label(loc.t("Descargar \(selected.name) (\(selected.sizeMB) MB)",
                                "Download \(selected.name) (\(selected.sizeMB) MB)"),
                          systemImage: "arrow.down.circle")
                }
                .help(loc.t("Descarga el modelo seleccionado para usarlo con micrófono, audio y vídeo.",
                            "Downloads the selected model for microphone, audio, and video."))
            }

            Text(loc.t("El modelo se descarga bajo demanda. El audio y los videos se transcriben localmente en la GPU y se entregan al chat como texto.",
                       "The model downloads on demand. Audio and video are transcribed locally on the GPU and passed to chat as text."))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func label(for model: WhisperModel) -> String {
        let badge: String
        switch model.tier {
        case .fast: badge = loc.t("Rápido", "Fast")
        case .recommended: badge = loc.t("Recomendado", "Recommended")
        case .maximum: badge = loc.t("Máxima precisión", "Maximum accuracy")
        case .advanced: badge = loc.t("Avanzado", "Advanced")
        }
        return "\(model.name) · \(model.sizeMB) MB · \(badge)"
    }
}
