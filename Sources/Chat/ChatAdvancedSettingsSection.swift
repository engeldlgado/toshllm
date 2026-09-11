// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct ChatAdvancedSettingsSection: View {
    let destination: ChatSettingsDestination

    @EnvironmentObject private var loc: Localizer
    @AppStorage(SettingsKeys.chatAutoCompact) private var autoCompact = true
    @AppStorage(SettingsKeys.smoothTyping) private var smoothTyping = true
    @AppStorage(SettingsKeys.agentToolsEnabled) private var agentToolsEnabled = false
    @AppStorage(SettingsKeys.toolsRuntime) private var toolsRuntime = ""
    @AppStorage(SettingsKeys.jsSandboxEnabled) private var jsSandboxEnabled = false
    @AppStorage(SettingsKeys.memoryToolsEnabled) private var memoryToolsEnabled = true
    @State private var blockedToolModels: [String] = ToolSupport.blockedModels
    @AppStorage(SettingsKeys.memoryArchiveHookURL) private var archiveHookURL = ""
    @AppStorage(SettingsKeys.memoryArchiveHookSecret) private var archiveHookSecret = ""
    @AppStorage(SettingsKeys.chatSystem) private var systemPrompt = ""
    @AppStorage(SettingsKeys.chatTopP) private var topP = 0.95
    @AppStorage(SettingsKeys.chatMinP) private var minP = 0.05
    @AppStorage(SettingsKeys.chatTopK) private var topK = 40
    @AppStorage(SettingsKeys.chatRepeatPenalty) private var repeatPenalty = 1.0
    @AppStorage(SettingsKeys.chatRepeatLastN) private var repeatLastN = 64
    @AppStorage(SettingsKeys.chatSeed) private var seed = -1
    @AppStorage(SettingsKeys.chatDynatempRange) private var dynatempRange = 0.0
    @AppStorage(SettingsKeys.chatDynatempExponent) private var dynatempExponent = 1.0
    @AppStorage(SettingsKeys.chatXTCProbability) private var xtcProbability = 0.0
    @AppStorage(SettingsKeys.chatXTCThreshold) private var xtcThreshold = 0.1
    @AppStorage(SettingsKeys.chatTypicalP) private var typicalP = 1.0
    @AppStorage(SettingsKeys.chatPresencePenalty) private var presencePenalty = 0.0
    @AppStorage(SettingsKeys.chatFrequencyPenalty) private var frequencyPenalty = 0.0
    @AppStorage(SettingsKeys.chatDryMultiplier) private var dryMultiplier = 0.0
    @AppStorage(SettingsKeys.chatDryBase) private var dryBase = 1.75
    @AppStorage(SettingsKeys.chatDryAllowedLength) private var dryAllowedLength = 2
    @AppStorage(SettingsKeys.chatDryPenaltyLastN) private var dryPenaltyLastN = 0
    @AppStorage(SettingsKeys.chatSamplers) private var samplers = ""
    @AppStorage(SettingsKeys.chatBackendSampling) private var backendSampling = false
    @AppStorage(SettingsKeys.chatCustomJSON) private var customJSON = ""
    @AppStorage(SettingsKeys.chatAgenticMaxTurns) private var agenticMaxTurns = 10
    @AppStorage(SettingsKeys.chatPasteLongTextLength) private var pasteLongTextLength = 2500
    @AppStorage(SettingsKeys.chatMaxImageMegapixels) private var maxImageMegapixels = 1.0
    @AppStorage(SettingsKeys.chatPDFAsImages) private var pdfAsImages = false
    @AppStorage(SettingsKeys.chatFontScale) private var chatFontScale = 1.0
    @State private var confirmDeleteAll = false
    @State private var promptExpanded = true
    @State private var samplingExpanded = true
    @State private var penaltiesExpanded = false
    @State private var dynamicExpanded = false
    @State private var dryExpanded = false
    @State private var agentsExpanded = false
    @State private var customExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if destination == .general {
            SettingsRowGroup {
                SettingsRow(icon: "arrow.down.right.and.arrow.up.left",
                            title: loc.t("Autocompactar conversaciones largas", "Auto-compact long conversations"),
                            help: loc.t("Cuando la conversación se acerca al límite de contexto, resume los mensajes viejos automáticamente para seguir respondiendo sin perder el hilo.",
                                        "When the conversation nears the context limit, older messages are summarized automatically so it can keep answering without losing the thread.")) {
                    SettingsToggle(isOn: $autoCompact)
                }
                SettingsRow(icon: "text.cursor",
                            title: loc.t("Animación de escritura fluida", "Smooth typing animation"),
                            help: loc.t("Anima la aparición del texto token a token. Desactívalo si prefieres que el texto aparezca de golpe o notas parpadeo.",
                                        "Animates the text appearing token by token. Turn it off if you prefer text to appear at once or notice flicker.")) {
                    SettingsToggle(isOn: $smoothTyping)
                }
                SettingsRow(icon: "textformat.size",
                            title: loc.t("Tamaño del texto del chat", "Chat text size"),
                            help: loc.t("Tamaño de los mensajes y del campo de escritura, sin tocar el resto de la interfaz. También con ⌘+ y ⌘− desde el chat, y ⌘0 para volver al 100%.",
                                        "Size of the messages and the input field, leaving the rest of the interface alone. Also ⌘+ and ⌘− from the chat, and ⌘0 to go back to 100%.")) {
                    HStack(spacing: 12) {
                        Slider(value: $chatFontScale, in: ChatFont.range, step: ChatFont.step)
                            .frame(width: 180)
                        Text("\(Int((chatFontScale * 100).rounded()))%")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 56, alignment: .trailing)
                    }
                    .frame(width: Self.controlColumn, alignment: .trailing)
                }
                SettingsRow(icon: "clock.arrow.circlepath",
                            title: loc.t("Historial", "History"),
                            help: loc.t("No se puede deshacer. Exporta antes desde el menú junto al buscador de chats si quieres una copia.",
                                        "This cannot be undone. Export first from the menu next to the chat search box if you want a copy.")) {
                    Button(role: .destructive) { confirmDeleteAll = true } label: {
                        Label(loc.t("Borrar todas…", "Delete all…"), systemImage: "trash")
                    }
                    .glassButton()
                    .tint(.red)
                }
            }
            }

            if destination == .general {
                ChatSettingsGroup(title: loc.t("Prompt de sistema global", "Global system prompt")) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(loc.t("Instrucciones permanentes para el modelo…",
                                    "Permanent instructions for the model…"),
                              text: $systemPrompt, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(5...10)
                        .textFieldStyle(.plain)
                        .padding(8)
                        .workspaceFieldSurface()
                    Text(loc.t("Se usa cuando la conversación y el proyecto no tienen un prompt propio.",
                               "Used when neither the conversation nor its project has its own prompt."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            }

            if destination == .sampling {
                ChatSettingsGroup(title: loc.t("Muestreo", "Sampling")) {
                VStack(alignment: .leading, spacing: 12) {
                    parameterSlider("Top P", value: $topP, range: 0...1,
                                    help: loc.t("Núcleo de probabilidad: solo considera los tokens más probables cuya suma llega a P. 1.0 lo desactiva; bajarlo recorta la cola improbable.",
                                                "Nucleus sampling: only the most likely tokens whose probabilities sum to P are considered. 1.0 disables it; lower trims the unlikely tail."))
                    parameterSlider("Min P", value: $minP, range: 0...1,
                                    help: loc.t("Descarta los tokens cuya probabilidad sea menor que esta fracción de la del token más probable. Alternativa más estable a Top P.",
                                                "Drops tokens whose probability is below this fraction of the top token's. A steadier alternative to Top P."))
                    parameterSlider("Typical P", value: $typicalP, range: 0...1,
                                    help: loc.t("Muestreo típico: mantiene los tokens con información cercana a la media, recortando los demasiado predecibles o demasiado raros. 1.0 lo desactiva.",
                                                "Typical sampling: keeps tokens with information near the average, trimming the too-predictable and too-rare. 1.0 disables it."))
                    integerStepper("Top K", value: $topK, range: 0...200,
                                   help: loc.t("Limita la elección a los K tokens más probables en cada paso. 0 lo desactiva.",
                                               "Limits the choice to the K most likely tokens at each step. 0 disables it."))
                    numberField(loc.t("Semilla", "Seed"), value: $seed,
                                help: loc.t("Semilla del generador aleatorio. -1 usa una distinta cada vez; fija un número para respuestas reproducibles con los mismos parámetros.",
                                            "Random seed. -1 picks a new one each time; set a number for reproducible answers with the same parameters."))
                    SettingsRow(icon: "list.number",
                                title: loc.t("Orden de muestreo", "Sampler order"),
                                help: loc.t("Orden en que se aplican los muestreadores, separados por ';'. Déjalo vacío para el orden por defecto del motor.",
                                            "Order the samplers are applied in, separated by ';'. Leave empty for the engine's default order.")) {
                        DeferredSettingsTextField("", text: $samplers,
                                                  prompt: "top_k;typ_p;top_p;min_p;temperature",
                                                  width: Self.controlColumn)
                    }
                    SettingsRow(icon: "cpu",
                                title: loc.t("Muestreo en backend", "Backend sampling"),
                                help: loc.t("Ejecuta el muestreo en la GPU en vez de la CPU. Puede ser más rápido, pero no todos los muestreadores (XTC, DRY) están soportados en backend.",
                                       "Runs sampling on the GPU instead of the CPU. Can be faster, but not every sampler (XTC, DRY) is supported on the backend.")) {
                        SettingsToggle(isOn: $backendSampling)
                    }
                }
            }
            }

            if destination == .sampling {
                ChatSettingsGroup(title: loc.t("Penalizaciones", "Penalties")) {
                VStack(alignment: .leading, spacing: 12) {
                    parameterSlider(loc.t("Repetición", "Repeat"), value: $repeatPenalty, range: 0.5...2,
                                    help: loc.t("Penaliza repetir tokens ya usados. 1.0 lo desactiva; por encima reduce la repetición, demasiado alto degrada la coherencia.",
                                                "Penalizes repeating tokens already used. 1.0 disables it; above that reduces repetition, too high hurts coherence."))
                    parameterSlider(loc.t("Presencia", "Presence"), value: $presencePenalty, range: -2...2,
                                    help: loc.t("Penaliza un token por haber aparecido ya, sin importar cuántas veces. Positivo fomenta temas nuevos; negativo los repite.",
                                                "Penalizes a token for having appeared at all, regardless of count. Positive encourages new topics; negative repeats them."))
                    parameterSlider(loc.t("Frecuencia", "Frequency"), value: $frequencyPenalty, range: -2...2,
                                    help: loc.t("Penaliza un token en proporción a cuántas veces ya apareció. Positivo reduce muletillas; negativo las favorece.",
                                                "Penalizes a token in proportion to how many times it already appeared. Positive reduces filler; negative favors it."))
                    integerStepper(loc.t("Ventana de repetición", "Repeat window"),
                                   value: $repeatLastN, range: 0...4096, step: 16,
                                   help: loc.t("Cuántos tokens recientes miran las penalizaciones de repetición. 0 lo desactiva.",
                                               "How many recent tokens the repetition penalties look at. 0 disables it."))
                }
            }
            }

            if destination == .sampling {
                ChatSettingsGroup(title: loc.t("Temperatura dinámica y XTC", "Dynamic temperature and XTC")) {
                VStack(alignment: .leading, spacing: 12) {
                    parameterSlider(loc.t("Rango dinámico", "Dynamic range"), value: $dynatempRange, range: 0...2,
                                    help: loc.t("Temperatura dinámica: varía la temperatura por token según la certeza del modelo. 0 la deja fija.",
                                                "Dynamic temperature: varies temperature per token by the model's certainty. 0 keeps it fixed."))
                    parameterSlider(loc.t("Exponente dinámico", "Dynamic exponent"), value: $dynatempExponent, range: 0.1...4,
                                    help: loc.t("Curva de la temperatura dinámica: valores altos concentran el cambio en los pasos de mayor incertidumbre.",
                                                "Dynamic temperature curve: higher values focus the change on the most uncertain steps."))
                    parameterSlider(loc.t("Probabilidad XTC", "XTC probability"), value: $xtcProbability, range: 0...1,
                                    help: loc.t("Probabilidad de aplicar XTC en cada paso, que elimina tokens de alta probabilidad para respuestas más creativas. 0 lo desactiva.",
                                                "Chance of applying XTC at each step, which removes high-probability tokens for more creative output. 0 disables it."))
                    parameterSlider(loc.t("Umbral XTC", "XTC threshold"), value: $xtcThreshold, range: 0...1,
                                    help: loc.t("Umbral mínimo de probabilidad para que XTC considere quitar un token. Solo actúa con Probabilidad XTC > 0.",
                                                "Minimum probability threshold for XTC to consider removing a token. Only active when XTC probability > 0."))
                }
            }
            }

            if destination == .sampling {
                ChatSettingsGroup(title: "DRY") {
                VStack(alignment: .leading, spacing: 12) {
                    parameterSlider(loc.t("Multiplicador", "Multiplier"), value: $dryMultiplier, range: 0...2,
                                    help: loc.t("Fuerza de la penalización DRY, que corta la repetición de secuencias enteras. 0 lo desactiva.",
                                                "Strength of the DRY penalty, which breaks repetition of whole sequences. 0 disables it."))
                    parameterSlider(loc.t("Base", "Base"), value: $dryBase, range: 1...3,
                                    help: loc.t("Base del crecimiento exponencial de la penalización DRY según la longitud de la secuencia repetida.",
                                                "Base of the DRY penalty's exponential growth with the length of the repeated sequence."))
                    integerStepper(loc.t("Longitud permitida", "Allowed length"),
                                   value: $dryAllowedLength, range: 0...32,
                                   help: loc.t("Longitud de secuencia repetida que se tolera antes de que DRY empiece a penalizar.",
                                               "Length of repeated sequence tolerated before DRY starts penalizing."))
                    integerStepper(loc.t("Ventana", "Window"), value: $dryPenaltyLastN,
                                   range: 0...32768, step: 64,
                                   help: loc.t("Cuántos tokens recientes examina DRY. 0 lo desactiva.",
                                               "How many recent tokens DRY scans. 0 disables it."))
                }
            }
            }

            if destination == .agents {
                ChatSettingsGroup(title: loc.t("Herramientas", "Tools")) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsRow(icon: "hammer",
                                title: loc.t("Herramientas locales para agentes", "Local agent tools"),
                                help: loc.t("Deja que el modelo lea o edite archivos y ejecute comandos mediante herramientas. Cada operación sensible pide permiso.",
                                       "Lets the model read or edit files and run commands via tools. Every sensitive operation asks for permission.")) {
                        SettingsToggle(isOn: $agentToolsEnabled)
                    }
                    if agentToolsEnabled {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(loc.t("Las herramientas pueden modificar archivos o ejecutar comandos; cada operación sensible solicita autorización.",
                                        "Tools can modify files or run commands; every sensitive operation requests permission."),
                                  systemImage: "exclamationmark.shield.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(loc.t("Revocar permisos permanentes", "Revoke persistent permissions"),
                                   systemImage: "lock.rotation", action: ChatToolsService.revokeAllPermissions)
                                .glassButton()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        SettingsRow(icon: "shippingbox",
                                    title: loc.t("Aislar herramientas en", "Isolate tools in"),
                                    help: loc.t("Ejecuta las herramientas fuera de tu Mac, en un contenedor o por SSH, para que no toquen tus archivos. Formatos: docker:imagen, podman:imagen, docker-container:id, ssh:destino. Vacío las ejecuta aquí mismo.",
                                                "Runs the tools off your Mac, in a container or over SSH, so they cannot touch your files. Formats: docker:image, podman:image, docker-container:id, ssh:target. Empty runs them right here.")) {
                            DeferredSettingsTextField("", text: $toolsRuntime,
                                                      prompt: "docker:alpine", width: 220)
                        }
                    }
                    SettingsRow(icon: "curlybraces",
                                title: loc.t("Sandbox JavaScript para agentes", "JavaScript sandbox for agents"),
                                help: loc.t("Añade una herramienta que ejecuta JavaScript en un entorno aislado para cálculos o transformaciones de datos.",
                                       "Adds a tool that runs JavaScript in a sandbox for calculations or data transforms.")) {
                        SettingsToggle(isOn: $jsSandboxEnabled)
                    }
                    integerStepper(loc.t("Turnos máximos del agente", "Maximum agent turns"),
                                   value: $agenticMaxTurns, range: 1...100,
                                   help: loc.t("Máximo de rondas herramienta→respuesta que el agente encadena en un turno antes de detenerse.",
                                               "Maximum tool→response rounds the agent chains in one turn before stopping."))
                    if !blockedToolModels.isEmpty {
                        SettingsRow(icon: "hammer.slash",
                                    title: loc.t("Modelos sin herramientas", "Models without tools"),
                                    help: loc.t("Modelos que escribieron mal una llamada y el motor cortó la respuesta, así que dejaron de recibir herramientas. Quita uno de la lista para volver a ofrecérselas.",
                                                "Models that wrote a call in the wrong shape, so the engine stopped the answer and they stopped receiving tools. Remove one to offer them again.")) {
                            EmptyView()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(blockedToolModels, id: \.self) { model in
                                HStack(spacing: 8) {
                                    Text((model as NSString).lastPathComponent)
                                        .font(.callout)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(model)
                                    Spacer(minLength: 8)
                                    Button {
                                        ToolSupport.unblock(model)
                                        blockedToolModels = ToolSupport.blockedModels
                                    } label: {
                                        Image(systemName: "arrow.uturn.backward")
                                    }
                                    .buttonStyle(.borderless)
                                    .help(loc.t("Volver a ofrecerle herramientas", "Offer tools to it again"))
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .onAppear { blockedToolModels = ToolSupport.blockedModels }
            }

            if destination == .agents {
                ChatSettingsGroup(title: loc.t("Memoria", "Memory")) {
                    SettingsRow(icon: "brain.head.profile",
                                title: loc.t("Memoria de la conversación", "Conversation memory"),
                                help: loc.t("Da al modelo tres herramientas para gestionar su propio contexto: listar la conversación, archivar lo terminado y recuperarlo cuando vuelve a hacer falta. Desactívalo si usas un servidor de memoria externo y el modelo confunde los dos.",
                                       "Gives the model three tools to manage its own context: list the conversation, archive what is finished and recall it when it matters again. Turn it off if you use an external memory server and the model confuses the two.")) {
                        SettingsToggle(isOn: $memoryToolsEnabled)
                    }
                    if memoryToolsEnabled {
                        SettingsRow(icon: "paperplane",
                                    title: loc.t("Enviar lo archivado a", "Send archived turns to"),
                                    help: loc.t("Cada vez que el modelo archiva turnos, se envían a esta dirección en JSON para que un índice externo los guarde. Vacío lo desactiva. Los envíos se guardan en disco y se reintentan, así que un receptor caído no pierde nada ni frena el chat.",
                                                "Every time the model archives turns they are posted to this address as JSON, so an external index can keep them. Empty turns it off. Deliveries are stored on disk and retried, so a receiver that is down loses nothing and does not hold up the chat.")) {
                            DeferredSettingsTextField("", text: $archiveHookURL,
                                                      prompt: "https://127.0.0.1:8000/hook", width: 220)
                                .autocorrectionDisabled()
                        }
                        SettingsRow(icon: "key",
                                    title: loc.t("Token del receptor (opcional)", "Receiver token (optional)"),
                                    help: loc.t("Se envía como Authorization: Bearer en cada entrega, para receptores que lo pidan.",
                                                "Sent as Authorization: Bearer with each delivery, for receivers that ask for one.")) {
                            DeferredSettingsTextField("", text: $archiveHookSecret, width: 220)
                                .autocorrectionDisabled()
                        }
                    }
                }
            }

            if destination == .general {
                ChatSettingsGroup(title: loc.t("Adjuntos", "Attachments")) {
                    integerStepper(loc.t("Texto pegado a archivo", "Paste text to file"),
                                   value: $pasteLongTextLength, range: 0...100_000, step: 500,
                                   zeroLabel: loc.t("Desactivado", "Off"),
                                   help: loc.t("Si pegas texto más largo que esto (en caracteres), se convierte en un adjunto en vez de llenar el cuadro de escritura. 0 lo desactiva.",
                                               "If you paste text longer than this (in characters), it becomes an attachment instead of filling the input box. 0 disables it."))
                    LabeledContent(loc.t("Tamaño máximo de imagen (MP)", "Maximum image size (MP)")) {
                        HStack(spacing: 8) {
                            DeferredNumberField("1", value: $maxImageMegapixels, width: 90)
                                .onChange(of: maxImageMegapixels) { _, value in
                                    let clamped = min(4, max(0.25, value))
                                    if clamped != value { maxImageMegapixels = clamped }
                                }
                            InfoTip(text: loc.t("Reduce las imágenes adjuntas a este máximo de megapíxeles antes de enviarlas, para ahorrar tokens de visión (0.25–4).",
                                                "Downsizes attached images to this megapixel maximum before sending, to save vision tokens (0.25–4)."))
                        }
                    }
                    SettingsRow(icon: "doc.richtext",
                                title: loc.t("PDF como imágenes para modelos con visión", "PDF as images for vision models"),
                                help: loc.t("Envía cada página del PDF como imagen al modelo de visión en vez de extraer su texto. Útil para PDF escaneados o con diagramas.",
                                       "Sends each PDF page as an image to the vision model instead of extracting its text. Useful for scanned or diagram-heavy PDFs.")) {
                        SettingsToggle(isOn: $pdfAsImages)
                    }
                }
            }
            }

            if destination == .advanced {
                ChatSettingsGroup(title: loc.t("Petición personalizada", "Custom request")) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(loc.t("Objeto JSON para reemplazar parámetros…",
                                    "JSON object that overrides parameters…"),
                              text: $customJSON, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(5...10)
                        .textFieldStyle(.plain)
                        .padding(8)
                        .workspaceFieldSurface()
                    if customJSONInvalid {
                        Label(loc.t("JSON inválido: debe ser un objeto {…}. Se ignorará hasta corregirlo.",
                                    "Invalid JSON: it must be an object {…}. It will be ignored until fixed."),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text(loc.t("El JSON válido reemplaza los parámetros anteriores para cada petición.",
                                   "Valid JSON overrides the parameters above for each request."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            }

            if destination == .advanced {
                Button(loc.t("Restaurar opciones avanzadas del chat", "Reset advanced chat settings"),
                       systemImage: "arrow.counterclockwise", action: reset)
                    .buttonStyle(GlassPillButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            loc.t("¿Borrar todas las conversaciones?", "Delete all conversations?"),
            isPresented: $confirmDeleteAll, titleVisibility: .visible
        ) {
            Button(loc.t("Borrar todas", "Delete all"), role: .destructive) {
                // the chat window owns the store and can be closed while this one stays open
                if let store = ChatStore.live { store.deleteAll() } else { ChatStore.eraseStoredConversations() }
            }
            Button(loc.t("Cancelar", "Cancel"), role: .cancel) {}
        } message: {
            Text(loc.t("No se puede deshacer. Tus proyectos y sus prompts se conservan.",
                       "This cannot be undone. Your projects and their prompts are kept."))
        }
    }

    private var customJSONInvalid: Bool {
        let trimmed = customJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] else { return true }
        return false
    }

    /// Every row ends its control in the same column, so sliders, steppers and
    /// fields do not each stop at a different place.
    private static let controlColumn: CGFloat = 250

    private func parameterSlider(_ title: String, icon: String = "dial.medium",
                                 value: Binding<Double>,
                                 range: ClosedRange<Double>, help: String) -> some View {
        SettingsRow(icon: icon, title: title, help: help) {
            HStack(spacing: 12) {
                Slider(value: value, in: range).frame(width: 180)
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 56, alignment: .trailing)
            }
            .frame(width: Self.controlColumn, alignment: .trailing)
        }
    }

    private func integerStepper(_ title: String, icon: String = "number",
                                value: Binding<Int>, range: ClosedRange<Int>,
                                step: Int = 1, zeroLabel: String? = nil, help: String) -> some View {
        SettingsRow(icon: icon, title: title, help: help) {
            HStack(spacing: 10) {
                Text(value.wrappedValue == 0 ? (zeroLabel ?? "0") : value.wrappedValue.formatted())
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 56, alignment: .trailing)
                Stepper(title, value: value, in: range, step: step)
                    .labelsHidden()
                    .controlSize(.regular)   // rows shrink their controls; steppers need the room
                    .fixedSize()
            }
            .frame(width: Self.controlColumn, alignment: .trailing)
        }
    }

    private func numberField(_ title: String, icon: String = "number",
                             value: Binding<Int>, help: String) -> some View {
        SettingsRow(icon: icon, title: title, help: help) {
            DeferredNumberField(title, value: value, width: 100)
                .frame(width: Self.controlColumn, alignment: .trailing)
        }
    }

    private func reset() {
        topP = 0.95; minP = 0.05; topK = 40; repeatPenalty = 1; repeatLastN = 64; seed = -1
        dynatempRange = 0; dynatempExponent = 1; xtcProbability = 0; xtcThreshold = 0.1
        typicalP = 1; presencePenalty = 0; frequencyPenalty = 0; dryMultiplier = 0
        dryBase = 1.75; dryAllowedLength = 2; dryPenaltyLastN = 0; samplers = ""
        backendSampling = false; customJSON = ""; agenticMaxTurns = 10; pasteLongTextLength = 2500
        maxImageMegapixels = 1; pdfAsImages = false
        autoCompact = true; smoothTyping = true; agentToolsEnabled = false; jsSandboxEnabled = false
        memoryToolsEnabled = true; toolsRuntime = ""
        archiveHookURL = ""; archiveHookSecret = ""
    }
}
