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
    @AppStorage(SettingsKeys.sympyEnabled) private var sympyEnabled = false
    @AppStorage(SettingsKeys.scientificEnabled) private var scientificEnabled = false
    @AppStorage(SettingsKeys.mathAgentEnabled) private var mathAgentEnabled = false
    @AppStorage(SettingsKeys.mathToolsAllowed) private var mathToolsAllowed = true
    @AppStorage(SettingsKeys.memoryToolsEnabled) private var memoryToolsEnabled = true
    @AppStorage(SettingsKeys.chatMapToolEnabled) private var chatMapToolEnabled = true
    @AppStorage(SettingsKeys.chatRoadRouteEnabled) private var chatRoadRouteEnabled = true
    @AppStorage(SettingsKeys.mapStyle) private var mapStyle = ""
    @AppStorage(SettingsKeys.mapFolder) private var mapFolder = ""
    @AppStorage(SettingsKeys.toolResultLimit) private var toolResultLimit = ToolResultLimit.defaultCharacters
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
                    if SymPyToolsService.runtimeDirectory() != nil {
                        SettingsRow(icon: "function",
                                    title: loc.t("Matemática simbólica (SymPy)", "Symbolic math (SymPy)"),
                                    help: loc.t("Añade herramientas de matemática exacta: simplificar, resolver ecuaciones, derivar, integrar, matrices y verificar resultados. Va incluido en la app, no ejecuta código del modelo y no escribe archivos. Apagado no consume nada; encendido, el motor mantiene un proceso auxiliar pequeño y SymPy solo se carga al usarlo. Se aplica al reiniciar el servidor.",
                                                "Adds exact math tools: simplify, solve equations, differentiate, integrate, matrices and checking results. It ships inside the app, runs no code from the model and writes no files. Off, it uses nothing; on, the engine keeps a small helper process and SymPy loads only when used. Applies when the server restarts.")) {
                            SettingsToggle(isOn: $sympyEnabled)
                        }
                        SettingsRow(icon: "waveform.path.ecg",
                                    title: loc.t("Cálculo científico (NumPy y SciPy)", "Scientific computing (NumPy and SciPy)"),
                                    help: loc.t("Añade herramientas de cálculo numérico: álgebra lineal, integración, optimización, ajuste de curvas, FFT y filtros, ecuaciones diferenciales y estadística. Va incluido en la app, no ejecuta código del modelo y no lee ni escribe archivos. Apagado no consume nada; encendido, las librerías solo se cargan al usarlas y calculan en un solo hilo para no frenar al modelo. Se aplica al reiniciar el servidor.",
                                                "Adds numerical tools: linear algebra, integration, optimization, curve fitting, FFT and filters, differential equations and statistics. It ships inside the app, runs no code from the model and neither reads nor writes files. Off, it uses nothing; on, the libraries load only when used and compute on a single thread so the model is not slowed down. Applies when the server restarts.")) {
                            SettingsToggle(isOn: $scientificEnabled)
                        }
                        if sympyEnabled || scientificEnabled {
                            SettingsRow(icon: "checkmark.shield",
                                        title: loc.t("Usar las herramientas matemáticas sin preguntar", "Use the math tools without asking"),
                                        help: loc.t("Las herramientas matemáticas solo calculan: no leen ni escriben archivos ni ejecutan comandos. Así el agente de Tosh en el motor lleva estos turnos con todas sus comprobaciones. Apagado, el chat pide permiso en cada llamada y lleva el turno él mismo, con las mismas reglas. No cambia los permisos de ninguna otra herramienta.",
                                                    "The math tools only compute: they neither read nor write files nor run commands. This way the Tosh agent in the engine runs these turns with all its checks. Off, the chat asks before each call and runs the turn itself, with the same rules. It does not change the permissions of any other tool.")) {
                                SettingsToggle(isOn: $mathToolsAllowed)
                            }
                            SettingsRow(icon: "server.rack",
                                        title: loc.t("Responder con las herramientas por la API", "Answer with the tools over the API"),
                                        help: loc.t("El agente de Tosh, el mismo que usan este chat y el chat web, responde también a los clientes de /v1/chat/completions que no lo piden con la cabecera X-Tosh-Agent: on, también en remoto y sin la app. Las peticiones que traen herramientas propias (VS Code, agentes) o X-Tosh-Agent: off siguen yendo al modelo tal cual. Se aplica al reiniciar el servidor.",
                                                    "The Tosh agent, the one this chat and the web chat use, also answers /v1/chat/completions clients that do not ask for it with the X-Tosh-Agent: on header, also remotely and without the app. Requests that bring tools of their own (VS Code, agents) or X-Tosh-Agent: off still go to the model as they are. Applies when the server restarts.")) {
                                SettingsToggle(isOn: $mathAgentEnabled)
                            }
                        }
                    }
                    integerStepper(loc.t("Turnos máximos del agente", "Maximum agent turns"),
                                   value: $agenticMaxTurns, range: 1...100,
                                   help: loc.t("Máximo de rondas herramienta→respuesta que el agente encadena en un turno antes de detenerse.",
                                               "Maximum tool→response rounds the agent chains in one turn before stopping."))
                    integerStepper(loc.t("Tope del resultado de una herramienta", "Tool result limit"),
                                   icon: "scissors",
                                   value: $toolResultLimit, range: 0...200_000, step: 5_000,
                                   zeroLabel: loc.t("Sin tope", "None"),
                                   help: loc.t("Caracteres de cada resultado de herramienta que llegan al modelo. Si se pasa, se envían el principio y el final con una nota de lo recortado; la tarjeta de la herramienta sigue mostrando el resultado entero. Evita que una página web o un listado grande llene el contexto. 0 lo envía entero.",
                                               "Characters of each tool result that reach the model. Longer results send the beginning and the end with a note of what was cut; the tool card still shows the whole result. Keeps one web page or large listing from filling the context. 0 sends it whole."))
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

            if destination == .agents {
                ChatSettingsGroup(title: loc.t("Mapa", "Map")) {
                    SettingsRow(icon: "map",
                                title: loc.t("Mapa en el chat", "Map in the chat"),
                                help: loc.t("Da al modelo una herramienta para dibujar puntos, líneas y áreas en un mapa bajo su respuesta. Lo que dibuja va con línea discontinua y marcado como posiciones aproximadas, porque las coordenadas pueden ser estimadas por el modelo; los mapas de datos que devuelve un agente, como los de un servicio GIS, no cambian.",
                                       "Gives the model a tool to draw points, lines and areas on a map under its answer. What it draws is dashed and marked as approximate positions, since the model may estimate the coordinates; maps of data an agent returns, such as a GIS service's, are unchanged.")) {
                        SettingsToggle(isOn: $chatMapToolEnabled)
                    }
                    if chatMapToolEnabled {
                        SettingsRow(icon: "car",
                                    title: loc.t("Rutas por carretera (Apple Maps)", "Road routes (Apple Maps)"),
                                    help: loc.t("Cuando pides una ruta por carretera, la app te pide permiso para enviar los puntos a Apple Maps por internet, y dibuja el recorrido real con su distancia y su tiempo. Si no das permiso, o lo apagas aquí, el modelo traza una línea recta y lo dice.",
                                                "When you ask for a route by road, the app asks your permission to send the points to Apple Maps over the internet, and draws the real route with its distance and time. Without your permission, or with this off, the model draws a straight line and says so.")) {
                            SettingsToggle(isOn: $chatRoadRouteEnabled)
                        }
                    }
                    SettingsRow(icon: "square.3.layers.3d",
                                title: loc.t("Estilo del mapa base", "Base map style"),
                                help: loc.t("Dirección de un estilo de MapLibre (style.json) para el fondo de los mapas, en la app y en el chat web. Vacío usa OpenFreeMap por internet, y none dibuja un fondo liso sin conectarse. Las rutas por carretera se dibujan siempre sobre Apple Maps.",
                                            "Address of a MapLibre style (style.json) for the background of maps, in the app and in the web chat. Empty uses OpenFreeMap over the internet, and none draws a plain background without connecting. Road routes are always drawn on Apple Maps.")) {
                        DeferredSettingsTextField("", text: $mapStyle, prompt: "OpenFreeMap", width: 220)
                            .autocorrectionDisabled()
                    }
                    SettingsRow(icon: "externaldrive",
                                title: loc.t("Mapas sin internet", "Offline maps"),
                                subtitle: mapFolder.isEmpty ? nil : mapFolder,
                                help: loc.t("Carpeta con regiones en formato PMTiles, como las que publica Protomaps. Si tiene alguna, el fondo de los mapas se dibuja con ellas sin internet, también en el chat web, y gana sobre el estilo. Los nombres de lugares necesitan las fuentes en una subcarpeta assets; sin ella el mapa sale sin rótulos.",
                                            "Folder with regions in PMTiles format, like the ones Protomaps publishes. When it holds any, the background of maps is drawn from them without internet, in the web chat too, and over the style. Place names need the fonts in an assets subfolder; without it the map shows no labels.")) {
                        HStack(spacing: 8) {
                            if !mapFolder.isEmpty {
                                Button(loc.t("Quitar", "Remove")) { mapFolder = "" }
                                    .glassButton()
                                    .help(loc.t("Vuelve al mapa en línea.", "Goes back to the online map."))
                            }
                            Button(loc.t("Elegir…", "Choose…")) { chooseMapFolder() }
                                .glassButton()
                                .help(loc.t("Elige la carpeta de regiones.", "Choose the folder of regions."))
                        }
                    }
                }
            }

            if destination == .agents {
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

    private func chooseMapFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = loc.t("Elegir", "Choose")
        if panel.runModal() == .OK, let url = panel.url { mapFolder = url.path }
    }

    private func reset() {
        topP = 0.95; minP = 0.05; topK = 40; repeatPenalty = 1; repeatLastN = 64; seed = -1
        dynatempRange = 0; dynatempExponent = 1; xtcProbability = 0; xtcThreshold = 0.1
        typicalP = 1; presencePenalty = 0; frequencyPenalty = 0; dryMultiplier = 0
        dryBase = 1.75; dryAllowedLength = 2; dryPenaltyLastN = 0; samplers = ""
        backendSampling = false; customJSON = ""; agenticMaxTurns = 10; pasteLongTextLength = 2500
        maxImageMegapixels = ProductDefaults.double(SettingsKeys.chatMaxImageMegapixels, or: 1)
        pdfAsImages = ProductDefaults.bool(SettingsKeys.chatPDFAsImages, or: false)
        autoCompact = true; smoothTyping = true; agentToolsEnabled = false; jsSandboxEnabled = false
        sympyEnabled = false; scientificEnabled = false; mathAgentEnabled = false; mathToolsAllowed = true
        memoryToolsEnabled = true; toolsRuntime = ""; toolResultLimit = ToolResultLimit.defaultCharacters
        archiveHookURL = ""; archiveHookSecret = ""
    }
}
