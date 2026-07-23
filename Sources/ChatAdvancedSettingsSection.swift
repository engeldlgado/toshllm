import SwiftUI

struct ChatAdvancedSettingsSection: View {
    @EnvironmentObject private var loc: Localizer
    @AppStorage(SettingsKeys.chatAutoCompact) private var autoCompact = true
    @AppStorage(SettingsKeys.smoothTyping) private var smoothTyping = true
    @AppStorage(SettingsKeys.agentToolsEnabled) private var agentToolsEnabled = false
    @AppStorage(SettingsKeys.jsSandboxEnabled) private var jsSandboxEnabled = false
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
    @AppStorage(SettingsKeys.chatDryPenaltyLastN) private var dryPenaltyLastN = -1
    @AppStorage(SettingsKeys.chatSamplers) private var samplers = ""
    @AppStorage(SettingsKeys.chatBackendSampling) private var backendSampling = false
    @AppStorage(SettingsKeys.chatCustomJSON) private var customJSON = ""
    @AppStorage(SettingsKeys.chatAgenticMaxTurns) private var agenticMaxTurns = 10
    @AppStorage(SettingsKeys.chatPasteLongTextLength) private var pasteLongTextLength = 2500
    @AppStorage(SettingsKeys.chatMaxImageMegapixels) private var maxImageMegapixels = 1.0
    @AppStorage(SettingsKeys.chatPDFAsImages) private var pdfAsImages = false
    @State private var promptExpanded = true
    @State private var samplingExpanded = true
    @State private var penaltiesExpanded = false
    @State private var dynamicExpanded = false
    @State private var dryExpanded = false
    @State private var agentsExpanded = false
    @State private var customExpanded = false

    var body: some View {
        Section {
            Toggle(loc.t("Autocompactar conversaciones largas", "Auto-compact long conversations"),
                   isOn: $autoCompact)
                .infoTip(loc.t("Cuando la conversación se acerca al límite de contexto, resume los mensajes viejos automáticamente para seguir respondiendo sin perder el hilo.",
                               "When the conversation nears the context limit, older messages are summarized automatically so it can keep answering without losing the thread."))
            Toggle(loc.t("Animación de escritura fluida", "Smooth typing animation"),
                   isOn: $smoothTyping)
                .infoTip(loc.t("Anima la aparición del texto token a token. Desactívalo si prefieres que el texto aparezca de golpe o notas parpadeo.",
                               "Animates the text appearing token by token. Turn it off if you prefer text to appear at once or notice flicker."))

            ChatSettingsDisclosureGroup(
                title: loc.t("Prompt de sistema global", "Global system prompt"),
                isExpanded: $promptExpanded
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(loc.t("Instrucciones permanentes para el modelo…",
                                    "Permanent instructions for the model…"),
                              text: $systemPrompt, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(5...10)
                        .textFieldStyle(.roundedBorder)
                    Text(loc.t("Se usa cuando la conversación y el proyecto no tienen un prompt propio.",
                               "Used when neither the conversation nor its project has its own prompt."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ChatSettingsDisclosureGroup(
                title: loc.t("Muestreo", "Sampling"),
                isExpanded: $samplingExpanded
            ) {
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
                    TextField(loc.t("Orden de muestreo", "Sampler order"), text: $samplers,
                              prompt: Text("top_k;typ_p;top_p;min_p;temperature"))
                        .textFieldStyle(.roundedBorder)
                        .infoTip(loc.t("Orden en que se aplican los muestreadores, separados por ';'. Déjalo vacío para el orden por defecto del motor.",
                                       "Order the samplers are applied in, separated by ';'. Leave empty for the engine's default order."))
                    Toggle(loc.t("Muestreo en backend", "Backend sampling"), isOn: $backendSampling)
                        .infoTip(loc.t("Ejecuta el muestreo en la GPU en vez de la CPU. Puede ser más rápido, pero no todos los muestreadores (XTC, DRY) están soportados en backend.",
                                       "Runs sampling on the GPU instead of the CPU. Can be faster, but not every sampler (XTC, DRY) is supported on the backend."))
                }
                .padding(.top, 10)
            }

            ChatSettingsDisclosureGroup(
                title: loc.t("Penalizaciones", "Penalties"),
                isExpanded: $penaltiesExpanded
            ) {
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
                                   value: $repeatLastN, range: -1...4096, step: 16,
                                   help: loc.t("Cuántos tokens recientes miran las penalizaciones de repetición. 0 lo desactiva; -1 usa todo el contexto.",
                                               "How many recent tokens the repetition penalties look at. 0 disables it; -1 uses the whole context."))
                }
                .padding(.top, 10)
            }

            ChatSettingsDisclosureGroup(
                title: loc.t("Temperatura dinámica y XTC", "Dynamic temperature and XTC"),
                isExpanded: $dynamicExpanded
            ) {
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
                .padding(.top, 10)
            }

            ChatSettingsDisclosureGroup(title: "DRY", isExpanded: $dryExpanded) {
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
                                   range: -1...32768, step: 64,
                                   help: loc.t("Cuántos tokens recientes examina DRY. -1 usa todo el contexto.",
                                               "How many recent tokens DRY scans. -1 uses the whole context."))
                }
                .padding(.top, 10)
            }

            ChatSettingsDisclosureGroup(
                title: loc.t("Agentes y adjuntos", "Agents and attachments"),
                isExpanded: $agentsExpanded
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(loc.t("Herramientas locales para agentes", "Local agent tools"),
                           isOn: $agentToolsEnabled)
                        .infoTip(loc.t("Deja que el modelo lea o edite archivos y ejecute comandos mediante herramientas. Cada operación sensible pide permiso.",
                                       "Lets the model read or edit files and run commands via tools. Every sensitive operation asks for permission."))
                    if agentToolsEnabled {
                        Label(loc.t("Las herramientas pueden modificar archivos o ejecutar comandos; cada operación sensible solicita autorización.",
                                    "Tools can modify files or run commands; every sensitive operation requests permission."),
                              systemImage: "exclamationmark.shield.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button(loc.t("Revocar permisos permanentes", "Revoke persistent permissions"),
                               systemImage: "lock.rotation", action: ChatToolsService.revokeAllPermissions)
                    }
                    Toggle(loc.t("Sandbox JavaScript para agentes", "JavaScript sandbox for agents"),
                           isOn: $jsSandboxEnabled)
                        .infoTip(loc.t("Añade una herramienta que ejecuta JavaScript en un entorno aislado para cálculos o transformaciones de datos.",
                                       "Adds a tool that runs JavaScript in a sandbox for calculations or data transforms."))
                    integerStepper(loc.t("Turnos máximos del agente", "Maximum agent turns"),
                                   value: $agenticMaxTurns, range: 1...100,
                                   help: loc.t("Máximo de rondas herramienta→respuesta que el agente encadena en un turno antes de detenerse.",
                                               "Maximum tool→response rounds the agent chains in one turn before stopping."))
                    integerStepper(loc.t("Texto pegado a archivo", "Paste text to file"),
                                   value: $pasteLongTextLength, range: 0...100_000, step: 500,
                                   zeroLabel: loc.t("Desactivado", "Off"),
                                   help: loc.t("Si pegas texto más largo que esto (en caracteres), se convierte en un adjunto en vez de llenar el cuadro de escritura. 0 lo desactiva.",
                                               "If you paste text longer than this (in characters), it becomes an attachment instead of filling the input box. 0 disables it."))
                    LabeledContent(loc.t("Tamaño máximo de imagen (MP)", "Maximum image size (MP)")) {
                        HStack(spacing: 8) {
                            TextField("1", value: $maxImageMegapixels, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                                .onChange(of: maxImageMegapixels) { _, value in
                                    let clamped = min(4, max(0.25, value))
                                    if clamped != value { maxImageMegapixels = clamped }
                                }
                            InfoTip(text: loc.t("Reduce las imágenes adjuntas a este máximo de megapíxeles antes de enviarlas, para ahorrar tokens de visión (0.25–4).",
                                                "Downsizes attached images to this megapixel maximum before sending, to save vision tokens (0.25–4)."))
                        }
                    }
                    Toggle(loc.t("PDF como imágenes para modelos con visión", "PDF as images for vision models"),
                           isOn: $pdfAsImages)
                        .infoTip(loc.t("Envía cada página del PDF como imagen al modelo de visión en vez de extraer su texto. Útil para PDF escaneados o con diagramas.",
                                       "Sends each PDF page as an image to the vision model instead of extracting its text. Useful for scanned or diagram-heavy PDFs."))
                }
                .padding(.top, 10)
            }

            ChatSettingsDisclosureGroup(
                title: loc.t("Petición personalizada", "Custom request"),
                isExpanded: $customExpanded
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(loc.t("Objeto JSON para reemplazar parámetros…",
                                    "JSON object that overrides parameters…"),
                              text: $customJSON, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(5...10)
                        .textFieldStyle(.roundedBorder)
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
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(loc.t("Restaurar opciones avanzadas del chat", "Reset advanced chat settings"),
                   systemImage: "arrow.counterclockwise", action: reset)
                .buttonStyle(GlassPillButtonStyle())
        } header: {
            Label(loc.t("Chat", "Chat"), systemImage: "bubble.left.and.bubble.right")
        } footer: {
            Text(loc.t("Los controles habituales permanecen junto al chat; aquí están los ajustes de uso menos frecuente.",
                       "Common controls remain beside the chat; less frequently used options live here."))
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

    private func parameterSlider(_ title: String, value: Binding<Double>,
                                 range: ClosedRange<Double>, help: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Slider(value: value, in: range)
                    .frame(minWidth: 160, idealWidth: 260, maxWidth: 340)
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 56, alignment: .trailing)
                InfoTip(text: help)
            }
        }
    }

    private func integerStepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>,
                                step: Int = 1, zeroLabel: String? = nil, help: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Text(value.wrappedValue == 0 ? (zeroLabel ?? "0") : value.wrappedValue.formatted())
                    .monospacedDigit()
                    .frame(minWidth: 72, alignment: .trailing)
                Stepper(title, value: value, in: range, step: step)
                    .labelsHidden()
                    .fixedSize()
                InfoTip(text: help)
            }
        }
    }

    private func numberField(_ title: String, value: Binding<Int>, help: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                TextField(title, value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                InfoTip(text: help)
            }
        }
    }

    private func reset() {
        topP = 0.95; minP = 0.05; topK = 40; repeatPenalty = 1; repeatLastN = 64; seed = -1
        dynatempRange = 0; dynatempExponent = 1; xtcProbability = 0; xtcThreshold = 0.1
        typicalP = 1; presencePenalty = 0; frequencyPenalty = 0; dryMultiplier = 0
        dryBase = 1.75; dryAllowedLength = 2; dryPenaltyLastN = -1; samplers = ""
        backendSampling = false; customJSON = ""; agenticMaxTurns = 10; pasteLongTextLength = 2500
        maxImageMegapixels = 1; pdfAsImages = false
        autoCompact = true; smoothTyping = true; agentToolsEnabled = false; jsSandboxEnabled = false
    }
}
