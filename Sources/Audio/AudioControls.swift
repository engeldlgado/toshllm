// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

struct AudioControls: View {
    @ObservedObject var studio: AudioStudioController
    @EnvironmentObject private var loc: Localizer
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var server: ServerController
    @EnvironmentObject private var control: ControlPanelState
    @Environment(\.openWindow) private var openWindow

    @AppStorage(SettingsKeys.whisperModel) private var whisperModelID = WhisperModel.recommendedID
    @AppStorage(SettingsKeys.gpuIndex) private var gpuIndex = -1
    @AppStorage(SettingsKeys.whisperLoadPolicy) private var loadPolicyRaw = WhisperLoadPolicy.onDemand.rawValue
    @AppStorage(SettingsKeys.audioOperation) private var operationRaw = AudioStudioOperation.transcribe.rawValue
    @AppStorage(SettingsKeys.audioLanguage) private var language = "auto"
    @AppStorage(SettingsKeys.audioTargetLanguage) private var targetLanguage = "Español"
    @AppStorage(SettingsKeys.port) private var port = 8080
    @AppStorage(SettingsKeys.routerMode) private var routerMode = false
    @AppStorage(SettingsKeys.chatSelectedModel) private var routerModel = ""
    @AppStorage(SettingsKeys.audioTranslationModel) private var translationModel = ""
    @AppStorage(SettingsKeys.audioGlossary) private var glossary = ""
    @State private var usesCustomTargetLanguage = false
    @FocusState private var customTargetLanguageFocused: Bool
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""
    @AppStorage(SettingsKeys.audioVADMode) private var vadModeRaw = AudioVADMode.defaultMode.rawValue
    @AppStorage(SettingsKeys.ncmoe) private var ncmoe = 0

    private var model: WhisperModel { WhisperModel.model(id: whisperModelID) }
    private var operation: AudioStudioOperation {
        AudioStudioOperation(rawValue: operationRaw) ?? .transcribe
    }
    private var vadMode: AudioVADMode {
        AudioVADMode(rawValue: vadModeRaw) ?? .defaultMode
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sourceCard
                    Divider()
                    taskCard
                    Divider()
                    modelCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            Divider()
            actionCard
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(minWidth: 300)
        .buttonStyle(GlassPillButtonStyle())
        .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 420)
        .onAppear {
            seedTargetLanguageIfNeeded()
            syncCustomTargetLanguage()
        }
        .onChange(of: operationRaw) { _, _ in
            seedTargetLanguageIfNeeded()
        }
    }

    private var sourceCard: some View {
        AudioSidebarSection(title: loc.t("Archivo", "File"), icon: "doc") {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: pickMedia) {
                    Label(loc.t("Elegir audio o vídeo…", "Choose audio or video…"),
                          systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .disabled(studio.isBusy)
                .help(loc.t("Admite audio y vídeo; ToshLLM extrae el audio localmente sin modificar el original.",
                            "Accepts audio and video; ToshLLM extracts audio locally without changing the original."))

                if let source = studio.sourceURL {
                    Text(source.lastPathComponent)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Label(sourceSummary, systemImage: studio.isVideo ? "film" : "music.note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(loc.t("También puedes arrastrarlo al área de previsualización.",
                               "You can also drop it onto the preview area."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var taskCard: some View {
        AudioSidebarSection(title: loc.t("Resultado", "Result"), icon: "captions.bubble") {
            VStack(alignment: .leading, spacing: 10) {
                Picker(loc.t("Operación", "Operation"), selection: $operationRaw) {
                    Text(loc.t("Transcribir", "Transcribe")).tag(AudioStudioOperation.transcribe.rawValue)
                    Text(loc.t("Traducir a inglés", "Translate to English")).tag(AudioStudioOperation.translateEnglish.rawValue)
                    Text(loc.t("Traducir con el chat", "Translate with chat")).tag(AudioStudioOperation.translateLocal.rawValue)
                }
                .help(loc.t("Whisper transcribe o traduce directamente al inglés; otros idiomas usan el modelo local del chat sin cambiar los tiempos.",
                            "Whisper transcribes or translates directly to English; other languages use the local chat model without changing timestamps."))

                Picker(loc.t("Idioma hablado", "Spoken language"), selection: $language) {
                    ForEach(WhisperLanguage.common) { item in
                        Text(loc.isSpanish ? item.es : item.en).tag(item.id)
                    }
                }
                .help(loc.t("Fijar el idioma mejora la precisión; Automático es útil cuando no lo conoces.",
                            "Choosing the language improves accuracy; Automatic is useful when it is unknown."))

                if operation == .translateLocal {
                    HStack(spacing: 10) {
                        Text(loc.t("Idioma de destino", "Target language"))
                        Spacer(minLength: 8)
                        ToshDropdown(selection: targetLanguageSelection,
                                     options: targetLanguageOptions,
                                     placeholder: loc.t("Elegir idioma", "Choose language"),
                                     width: 172,
                                     maximumListHeight: 320,
                                     listWidth: 260)
                    }
                    .help(loc.t("Elige el idioma final, por ejemplo Español, Coreano o Francés.",
                                "Choose the final language, such as Spanish, Korean, or French."))

                    if usesCustomTargetLanguage {
                        TextField(loc.t("Escribe otro idioma…", "Enter another language…"),
                                  text: $targetLanguage)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .workspaceFieldSurface()
                            .focused($customTargetLanguageFocused)
                            .onSubmit { commitCustomTargetLanguage() }
                    }
                    chatRequirement
                    translationModelControl
                    TextField(loc.t("Glosario: término = traducción", "Glossary: term = translation"),
                              text: $glossary, axis: .vertical)
                        .textFieldStyle(.plain)
                        .padding(8)
                        .workspaceFieldSurface()
                        .lineLimit(2...5)
                        .help(loc.t("Fija nombres, marcas y términos, uno por línea, para mantenerlos iguales durante todo el vídeo.",
                                    "Pins names, brands and terminology, one per line, to keep them consistent throughout the video."))
                } else if operation == .translateEnglish {
                    Label(loc.t("La traducción integrada de Whisper siempre produce inglés.",
                                "Whisper's built-in translation always produces English."),
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var translationModelControl: some View {
        if routerMode {
            Picker(loc.t("Modelo traductor", "Translation model"), selection: $translationModel) {
                ForEach(models.models) { item in
                    Text(ModelName.forPath(item.url.path).title)
                        .tag(ServerSettings.routerAlias(for: item.url.path))
                }
            }
            .help(loc.t("Elige el modelo del router que traducirá los subtítulos.",
                        "Choose the router model that will translate the subtitles."))
            .task { selectDefaultTranslationModel() }
            if let selected = models.models.first(where: {
                ServerSettings.routerAlias(for: $0.url.path) == translationModel
            }), selected.sizeBytes < 1_500_000_000 {
                Label(loc.t("Un modelo mayor suele conservar mejor nombres, contexto y JSON en vídeos largos.",
                            "A larger model usually preserves names, context, and JSON better in long videos."),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } else if models.models.isEmpty {
            LabeledContent(loc.t("Modelo traductor", "Translation model")) {
                Text(loc.t("Sin modelos", "No models")).lineLimit(1)
            }
            downloadModelButton
        } else {
            Picker(loc.t("Modelo traductor", "Translation model"), selection: $modelPath) {
                Text(loc.t("Sin modelo", "No model")).tag("")
                ForEach(ModelFamilyGroup.grouped(models.models)) { group in
                    Section(group.isOther ? loc.t("Otros", "Others") : group.family) {
                        ForEach(group.models) {
                            Text(ModelName.forPath($0.url.path).display)
                                .tag($0.url.path)
                        }
                    }
                }
            }
            .disabled(server.state == .running || server.state == .starting)
            // Selecting a model also seeds ncmoe so it never carries over stale
            // from the previous one, same as the dashboard picker.
            .onChange(of: modelPath) { _, path in
                ncmoe = Estimator.ncmoeForSelection(path: path, models: models.models)
            }
            .help(loc.t("Modelo que traducirá los segmentos; es el mismo del Chat. Para cambiarlo hay que detener el motor.",
                        "Model that will translate the segments; it is the same one Chat uses. Stop the engine to change it."))
        }
    }

    private var downloadModelButton: some View {
        Button(loc.t("Descargar un modelo…", "Download a model…"),
               systemImage: "arrow.down.circle", action: openModelCatalog)
        .controlSize(.small)
        .help(loc.t("Abre el catálogo para descargar un modelo de lenguaje, necesario para traducir.",
                    "Opens the catalog to download a language model, which translating requires."))
    }

    private func openModelCatalog() {
        control.section = .models
        openWindow(id: "control")
    }

    @ViewBuilder
    private var chatRequirement: some View {
        if server.state == .running {
            Label(loc.t("El chat está listo para traducir los segmentos.",
                        "Chat is ready to translate the segments."), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                Label(loc.t("Esta opción necesita el motor de chat activo.",
                            "This option needs the chat engine running."),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if models.models.isEmpty {
                    downloadModelButton
                } else if modelPath.isEmpty {
                    Text(loc.t("Elige un modelo traductor abajo para poder iniciarlo.",
                               "Pick a translation model below to start it."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if server.state == .stopped {
                    Button(loc.t("Iniciar motor de chat", "Start chat engine"),
                           systemImage: "play.fill") {
                        server.start(.fromDefaults())
                    }
                    .controlSize(.small)
                    .help(loc.t("Carga el modelo configurado para traducir después de transcribir.",
                                "Loads the configured model to translate after transcription."))
                }
            }
        }
    }

    private var modelCard: some View {
        AudioSidebarSection(title: "Whisper.cpp · GPU", icon: "memorychip") {
            VStack(alignment: .leading, spacing: 8) {
                Picker(loc.t("Modelo", "Model"), selection: $whisperModelID) {
                    ForEach(WhisperModel.catalog) { item in
                        Text("\(item.name) · \(item.sizeMB) MB").tag(item.id)
                    }
                }
                .help(loc.t("Turbo ofrece el mejor equilibrio; Large v3 prioriza precisión.",
                            "Turbo offers the best balance; Large v3 prioritizes accuracy."))

                Text(loc.isSpanish ? model.detailES : model.detailEN)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !models.whisperModelInstalled(model) {
                    downloadControl
                } else {
                    Label(loc.t("Modelo instalado", "Model installed"), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                Divider()
                vadControl

                if hardware.gpus.count > 1 {
                    Picker("GPU", selection: $gpuIndex) {
                        Text(loc.t("Automática", "Automatic")).tag(-1)
                        ForEach(Array(hardware.gpus.enumerated()), id: \.offset) { index, gpu in
                            Text(gpu.name).tag(index)
                        }
                    }
                    .help(loc.t("Selecciona la GPU AMD que ejecutará Whisper.",
                                "Select the AMD GPU that runs Whisper."))
                }
            }
        }
    }

    @ViewBuilder
    private var vadControl: some View {
        AudioVADCalibrationView()
        if vadMode.isEnabled && !models.whisperVADInstalled,
           let download = models.whisperVADDownload() {
            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: download.progress)
                if let error = download.error {
                    Text(loc.half(error)).font(.caption).foregroundStyle(.red)
                    Button(loc.t("Reintentar detector de voz", "Retry voice detector"),
                           systemImage: "arrow.clockwise") {
                        models.retryWhisperVADDownload(download)
                    }
                    .help(loc.t("Reinicia la descarga de Silero VAD.",
                                "Restarts the Silero VAD download."))
                } else if download.phase == .paused {
                    Button(loc.t("Reanudar detector de voz", "Resume voice detector"),
                           systemImage: "arrow.down.circle", action: download.resume)
                        .help(loc.t("Continúa la descarga de Silero VAD.",
                                    "Continues the Silero VAD download."))
                } else {
                    Text(loc.t("Descargando detector de voz…", "Downloading voice detector…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if vadMode.isEnabled && !models.whisperVADInstalled {
            VStack(alignment: .leading, spacing: 6) {
                Label(loc.t("Audio necesita detectar silencios", "Audio needs silence detection"),
                      systemImage: "waveform.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button(loc.t("Descargar Silero VAD · 864 KB", "Download Silero VAD · 864 KB"),
                       systemImage: "arrow.down.circle.fill", action: models.downloadWhisperVAD)
                    .help(loc.t("Descarga el detector que separa voz y silencio antes de ejecutar Whisper.",
                                "Downloads the detector that separates speech and silence before running Whisper."))
            }
        }
        if vadMode.isEnabled && models.whisperVADInstalled && studio.sourceURL != nil {
            Button(loc.t("Probar VAD en 30 segundos", "Preview VAD on 30 seconds"),
                   systemImage: "waveform.badge.magnifyingglass", action: previewVAD)
                .disabled(studio.isBusy)
                .help(loc.t("Analiza una muestra sin reemplazar la transcripción existente.",
                            "Analyzes a sample without replacing the existing transcript."))
            Text(loc.t("Cambia el modo o perfil y repite la prueba para comparar resultados.",
                       "Change the mode or profile and repeat the preview to compare results."))
                .font(.caption)
                .foregroundStyle(.secondary)
            vadPreviewResult
        }
    }

    @ViewBuilder
    private var vadPreviewResult: some View {
        switch studio.vadPreviewState {
        case .idle:
            EmptyView()
        case .running:
            ProgressView(loc.t("Analizando muestra…", "Analyzing sample…"))
                .controlSize(.small)
        case .ready(let count, let speech, let sample):
            VStack(alignment: .leading, spacing: 4) {
                Label(loc.t("%@ segmentos · %@ s de voz en %@ s", "%@ segments · %@ s of speech in %@ s", "\(count)", "\(Int(speech.rounded()))", "\(Int(sample.rounded()))"),
                      systemImage: count > 0 ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(count > 0 ? Color.green : Color.orange)
                if !studio.vadPreviewCues.isEmpty {
                    Text(studio.vadPreviewCues.prefix(5).map {
                        "\(MediaTime.compact($0.start))–\(MediaTime.compact($0.end))"
                    }.joined(separator: " · "))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(loc.t("Intervalos que la configuración actual considera voz.",
                                "Intervals the current configuration considers speech."))
                }
            }
        case .failed(let message):
            Label(loc.half(message), systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var downloadControl: some View {
        if let download = models.whisperDownload(model) {
            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: download.progress)
                if let error = download.error {
                    Text(loc.half(error)).font(.caption).foregroundStyle(.red)
                    Button(loc.t("Reintentar", "Retry"), systemImage: "arrow.clockwise") {
                        models.retryWhisperDownload(download)
                    }
                    .help(loc.t("Reinicia la descarga del modelo.",
                                "Restarts the model download."))
                } else if download.phase == .paused {
                    Button(loc.t("Reanudar", "Resume"), systemImage: "arrow.down.circle",
                           action: download.resume)
                        .help(loc.t("Continúa la descarga desde donde se pausó.",
                                    "Continues the download from where it paused."))
                } else {
                    Text(loc.t("Descargando %@…", "Downloading %@…", "\(model.name)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Button(loc.t("Descargar %@", "Download %@", "\(model.name)"),
                   systemImage: "arrow.down.circle.fill") {
                models.downloadWhisperModel(model)
            }
            .glassButton(prominent: true)
            .help(loc.t("Descarga el modelo en la carpeta local de modelos Whisper.",
                        "Downloads the model into the local Whisper model folder."))
        }
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            if studio.isBusy {
                ProgressView(value: studio.progress)
                HStack {
                    Label(stageText, systemImage: stageIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let remaining = studio.remaining {
                        Text(loc.t("~%@ restantes", "~%@ left", "\(MediaTime.compact(remaining))"))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Button(loc.t(server.state == .running ? "Detener ambos motores" : "Cancelar",
                             server.state == .running ? "Stop both engines" : "Cancel"),
                       systemImage: "stop.fill", action: stopProcessing)
                    .frame(maxWidth: .infinity)
                    .help(loc.t("Cancela el trabajo y libera Whisper; si el chat está activo, también lo detiene.",
                                "Cancels the job and frees Whisper; if chat is active, it stops that too."))
            } else {
                Button(action: startProcessing) {
                    Label(actionTitle, systemImage: operation == .transcribe ? "captions.bubble.fill" : "character.bubble.fill")
                        .frame(maxWidth: .infinity)
                }
                .glassButton(prominent: true)
                .controlSize(.large)
                .disabled(!canStart)
                .help(loc.t("Procesa el archivo localmente y conserva marcas de tiempo exportables.",
                            "Processes the file locally and preserves exportable timestamps."))
                if !studio.originalCues.isEmpty && operation == .translateLocal {
                    Button(loc.t("Reintentar solo la traducción", "Retry translation only"),
                           systemImage: "arrow.triangle.2.circlepath", action: retryTranslation)
                        .disabled(!canRetryTranslation)
                        .help(loc.t("Conserva la transcripción de Whisper y vuelve a ejecutar únicamente el Chat.",
                                    "Keeps the Whisper transcript and runs only Chat again."))
                }
            }

            if case .failed(let message) = studio.stage {
                Label(loc.half(message), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var canStart: Bool {
        studio.sourceURL != nil && models.whisperModelInstalled(model)
            && (!vadMode.isEnabled || models.whisperVADInstalled)
            && (operation != .translateLocal || canUseTranslationServer)
    }

    private var canRetryTranslation: Bool {
        studio.canRetryTranslation && canUseTranslationServer
    }

    private var canUseTranslationServer: Bool {
        server.state == .running
            && !targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var actionTitle: String {
        switch operation {
        case .transcribe: loc.t("Crear subtítulos", "Create subtitles")
        case .translateEnglish: loc.t("Transcribir y traducir", "Transcribe and translate")
        case .translateLocal: loc.t("Transcribir y traducir", "Transcribe and translate")
        }
    }

    private var stageText: String {
        switch studio.stage {
        case .preparing: loc.t("Preparando el audio…", "Preparing audio…")
        case .analyzingVAD: loc.t("Analizando VAD…", "Analyzing VAD…")
        case .transcribing: loc.t("Whisper está transcribiendo…", "Whisper is transcribing…")
        case .translating:
            loc.t("Traduciendo lote %@ de %@…", "Translating batch %@ of %@…", "\(studio.translatedBatchCount + 1)", "\(max(1, studio.translationBatchCount))")
        default: ""
        }
    }

    private var stageIcon: String {
        switch studio.stage {
        case .preparing: "waveform.badge.magnifyingglass"
        case .analyzingVAD: "waveform.badge.magnifyingglass"
        case .transcribing: "captions.bubble"
        case .translating: "character.bubble"
        default: "circle"
        }
    }

    private var sourceSummary: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(studio.fileSize), countStyle: .file)
        guard studio.duration > 0 else { return size }
        return "\(MediaTime.compact(studio.duration)) · \(size)"
    }

    private func pickMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        studio.select(url)
    }

    private func startProcessing() {
        studio.start(
            modelURL: model.url(in: models.whisperDirectory), vadModelURL: models.whisperVADURL,
            vadConfiguration: AudioVADPreferences.configuration(), gpuIndex: gpuIndex,
            language: language, operation: operation, targetLanguage: targetLanguage,
            chatPort: port, routerModel: selectedTranslationModel, glossary: glossary,
            restorePersistentModel: loadPolicyRaw == WhisperLoadPolicy.alwaysLoaded.rawValue && server.state == .running
        )
    }

    private var selectedTranslationModel: String? {
        guard routerMode else { return nil }
        return translationModel.isEmpty ? (routerModel.isEmpty ? nil : routerModel) : translationModel
    }

    private func selectDefaultTranslationModel() {
        guard translationModel.isEmpty else { return }
        translationModel = routerModel.isEmpty
            ? models.models.first.map { ServerSettings.routerAlias(for: $0.url.path) } ?? ""
            : routerModel
    }

    private func seedTargetLanguageIfNeeded() {
        guard operation == .translateLocal else { return }
        let current = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty {
            targetLanguage = TranslationLanguageOption.spanishValue
        } else if let match = TranslationLanguageOption.matching(current), match.value != targetLanguage {
            targetLanguage = match.value
        }
    }

    private var targetLanguageSelection: Binding<String> {
        Binding {
            if usesCustomTargetLanguage {
                return TranslationLanguageOption.customValue
            }
            return TranslationLanguageOption.matching(targetLanguage)?.value
                ?? TranslationLanguageOption.customValue
        } set: { selection in
            if selection == TranslationLanguageOption.customValue {
                usesCustomTargetLanguage = true
                targetLanguage = ""
                Task { @MainActor in
                    await Task.yield()
                    customTargetLanguageFocused = true
                }
            } else {
                usesCustomTargetLanguage = false
                customTargetLanguageFocused = false
                targetLanguage = selection
            }
        }
    }

    private var targetLanguageOptions: [ToshDropdown<String>.Option] {
        [
            .init(value: TranslationLanguageOption.customValue,
                  title: loc.t("Otro…", "Other…"),
                  systemImage: "ellipsis")
        ] + TranslationLanguageOption.all.map {
            .init(value: $0.value, title: $0.label(isSpanish: loc.isSpanish))
        }
    }

    private func syncCustomTargetLanguage() {
        let current = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return }
        usesCustomTargetLanguage = TranslationLanguageOption.matching(current) == nil
    }

    private func commitCustomTargetLanguage() {
        let current = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        targetLanguage = current
        if let match = TranslationLanguageOption.fuzzyMatch(current, minimumSimilarity: 0.80) {
            targetLanguage = match.value
            usesCustomTargetLanguage = false
        }
        customTargetLanguageFocused = false
    }

    private func retryTranslation() {
        studio.retryTranslation(targetLanguage: targetLanguage, port: port,
                                routerModel: selectedTranslationModel, glossary: glossary)
    }

    private func previewVAD() {
        studio.previewVAD(
            modelURL: model.url(in: models.whisperDirectory),
            vadModelURL: models.whisperVADURL,
            vadConfiguration: AudioVADPreferences.configuration(),
            gpuIndex: gpuIndex, language: language
        )
    }

    private func stopProcessing() {
        if server.state == .running || server.state == .starting {
            server.stop()
        } else {
            studio.cancel()
        }
    }
}

private struct TranslationLanguageOption: Identifiable {
    let id: String
    let value: String
    let spanish: String
    let english: String

    func label(isSpanish: Bool) -> String { isSpanish ? spanish : english }

    static let all: [TranslationLanguageOption] = {
        let spanishLocale = Locale(identifier: "es")
        let englishLocale = Locale(identifier: "en")
        var seen = Set<String>()
        return commonLanguageCodes.compactMap { code -> TranslationLanguageOption? in
            guard let english = englishLocale.localizedString(forLanguageCode: code),
                  let spanish = spanishLocale.localizedString(forLanguageCode: code),
                  !english.isEmpty, !spanish.isEmpty,
                  seen.insert(english.lowercased()).inserted else { return nil }
            return TranslationLanguageOption(id: code, value: english,
                                             spanish: spanish.capitalized(with: spanishLocale),
                                             english: english.capitalized(with: englishLocale))
        }
        .sorted { $0.spanish.localizedStandardCompare($1.spanish) == .orderedAscending }
    }()

    /// Everyday translation targets. Less common and constructed languages stay
    /// available through “Other” without overwhelming the dropdown.
    private static let commonLanguageCodes = [
        "af", "sq", "de", "am", "ar", "hy", "az", "bn", "be", "my", "bs", "bg",
        "ca", "cs", "zh", "ko", "hr", "da", "sk", "sl", "es", "et", "eu", "fi",
        "fil", "fr", "cy", "ka", "el", "gu", "he", "hi", "hu", "id", "en", "is",
        "it", "ja", "kn", "kk", "km", "lo", "lv", "lt", "mk", "ms", "ml", "mr",
        "mn", "ne", "nl", "no", "fa", "pl", "pt", "pa", "ro", "ru", "sr", "si",
        "sv", "sw", "ta", "te", "th", "tr", "uk", "ur", "uz", "vi"
    ]

    static var spanishValue: String {
        all.first(where: { $0.id == "es" })?.value ?? "Spanish"
    }

    static let customValue = "__toshllm_custom_language__"

    static func matching(_ value: String) -> TranslationLanguageOption? {
        all.first {
            $0.id.caseInsensitiveCompare(value) == .orderedSame
                || $0.value.caseInsensitiveCompare(value) == .orderedSame
                || $0.spanish.caseInsensitiveCompare(value) == .orderedSame
                || $0.english.caseInsensitiveCompare(value) == .orderedSame
        }
    }

    static func fuzzyMatch(_ value: String, minimumSimilarity: Double) -> TranslationLanguageOption? {
        let input = normalized(value)
        // Very short names are too ambiguous while typing (for example Ga, Ewe,
        // or Fon), so they must be chosen explicitly from the dropdown.
        guard input.count >= 4 else { return nil }

        return all.compactMap { option -> (TranslationLanguageOption, Double)? in
            let score = [option.english, option.spanish]
                .map { similarity(input, normalized($0)) }
                .max() ?? 0
            return score >= minimumSimilarity ? (option, score) : nil
        }
        .max { $0.1 < $1.1 }?
        .0
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter }
            .lowercased()
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)

        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, rightCharacter) in right.enumerated() {
                let substitution = previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    substitution
                )
            }
            previous = current
        }

        let distance = previous[right.count]
        return 1 - Double(distance) / Double(max(left.count, right.count))
    }
}

/// The same flat hierarchy used by the Images and Video sidebars. Sections keep
/// their labels and spacing without adding a separate opaque card behind each one.
private struct AudioSidebarSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
