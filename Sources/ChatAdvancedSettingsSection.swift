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
            Toggle(loc.t("Animación de escritura fluida", "Smooth typing animation"),
                   isOn: $smoothTyping)

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
                    parameterSlider("Top P", value: $topP, range: 0...1)
                    parameterSlider("Min P", value: $minP, range: 0...1)
                    parameterSlider("Typical P", value: $typicalP, range: 0...1)
                    integerStepper("Top K", value: $topK, range: 0...200)
                    numberField(loc.t("Semilla", "Seed"), value: $seed)
                    TextField(loc.t("Orden de muestreo", "Sampler order"), text: $samplers,
                              prompt: Text("top_k;typ_p;top_p;min_p;temperature"))
                        .textFieldStyle(.roundedBorder)
                    Toggle(loc.t("Muestreo en backend", "Backend sampling"), isOn: $backendSampling)
                }
                .padding(.top, 10)
            }

            ChatSettingsDisclosureGroup(
                title: loc.t("Penalizaciones", "Penalties"),
                isExpanded: $penaltiesExpanded
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    parameterSlider(loc.t("Repetición", "Repeat"), value: $repeatPenalty, range: 0.5...2)
                    parameterSlider(loc.t("Presencia", "Presence"), value: $presencePenalty, range: -2...2)
                    parameterSlider(loc.t("Frecuencia", "Frequency"), value: $frequencyPenalty, range: -2...2)
                    integerStepper(loc.t("Ventana de repetición", "Repeat window"),
                                   value: $repeatLastN, range: 0...4096, step: 16)
                }
                .padding(.top, 10)
            }

            ChatSettingsDisclosureGroup(
                title: loc.t("Temperatura dinámica y XTC", "Dynamic temperature and XTC"),
                isExpanded: $dynamicExpanded
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    parameterSlider(loc.t("Rango dinámico", "Dynamic range"), value: $dynatempRange, range: 0...2)
                    parameterSlider(loc.t("Exponente dinámico", "Dynamic exponent"), value: $dynatempExponent, range: 0.1...4)
                    parameterSlider(loc.t("Probabilidad XTC", "XTC probability"), value: $xtcProbability, range: 0...1)
                    parameterSlider(loc.t("Umbral XTC", "XTC threshold"), value: $xtcThreshold, range: 0...1)
                }
                .padding(.top, 10)
            }

            ChatSettingsDisclosureGroup(title: "DRY", isExpanded: $dryExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    parameterSlider(loc.t("Multiplicador", "Multiplier"), value: $dryMultiplier, range: 0...2)
                    parameterSlider(loc.t("Base", "Base"), value: $dryBase, range: 1...3)
                    integerStepper(loc.t("Longitud permitida", "Allowed length"),
                                   value: $dryAllowedLength, range: 0...32)
                    integerStepper(loc.t("Ventana", "Window"), value: $dryPenaltyLastN,
                                   range: -1...32768, step: 64)
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
                    integerStepper(loc.t("Turnos máximos del agente", "Maximum agent turns"),
                                   value: $agenticMaxTurns, range: 1...100)
                    integerStepper(loc.t("Texto pegado a archivo", "Paste text to file"),
                                   value: $pasteLongTextLength, range: 0...100_000, step: 500,
                                   zeroLabel: loc.t("Desactivado", "Off"))
                    LabeledContent(loc.t("Tamaño máximo de imagen (MP)", "Maximum image size (MP)")) {
                        TextField("1", value: $maxImageMegapixels, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    Toggle(loc.t("PDF como imágenes para modelos con visión", "PDF as images for vision models"),
                           isOn: $pdfAsImages)
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
                    Text(loc.t("El JSON válido reemplaza los parámetros anteriores para cada petición.",
                               "Valid JSON overrides the parameters above for each request."))
                        .font(.caption).foregroundStyle(.secondary)
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

    private func parameterSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Slider(value: value, in: range)
                    .frame(minWidth: 180, idealWidth: 280, maxWidth: 360)
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }

    private func integerStepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>,
                                step: Int = 1, zeroLabel: String? = nil) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Text(value.wrappedValue == 0 ? (zeroLabel ?? "0") : value.wrappedValue.formatted())
                    .monospacedDigit()
                    .frame(minWidth: 72, alignment: .trailing)
                Stepper(title, value: value, in: range, step: step)
                    .labelsHidden()
                    .fixedSize()
            }
        }
    }

    private func numberField(_ title: String, value: Binding<Int>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
        }
    }

    private func reset() {
        topP = 0.95; minP = 0.05; topK = 40; repeatPenalty = 1; repeatLastN = 64; seed = -1
        dynatempRange = 0; dynatempExponent = 1; xtcProbability = 0; xtcThreshold = 0.1
        typicalP = 1; presencePenalty = 0; frequencyPenalty = 0; dryMultiplier = 0
        dryBase = 1.75; dryAllowedLength = 2; dryPenaltyLastN = -1; samplers = ""
        backendSampling = false; customJSON = ""; agenticMaxTurns = 10; pasteLongTextLength = 2500
        maxImageMegapixels = 1; pdfAsImages = false
    }
}
