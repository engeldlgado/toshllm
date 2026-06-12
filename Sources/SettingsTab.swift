import SwiftUI
import Charts

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var profileStore: ProfileStore

    @AppStorage(SettingsKeys.serverBinary) private var serverBinary = ServerSettings.defaultBinary
    @AppStorage(SettingsKeys.port) private var port = 8080
    @AppStorage(SettingsKeys.ngl) private var ngl = 99
    @AppStorage(SettingsKeys.ncmoe) private var ncmoe = 0
    @AppStorage(SettingsKeys.ctx) private var ctx = 16384
    @AppStorage(SettingsKeys.chatAutoCompact) private var chatAutoCompact = true
    @AppStorage(SettingsKeys.threads) private var threads = 6
    @AppStorage(SettingsKeys.flashAttn) private var flashAttn = "auto"
    @AppStorage(SettingsKeys.noMmap) private var noMmap = true
    @AppStorage(SettingsKeys.jinja) private var jinja = true
    @AppStorage(SettingsKeys.concurrencyDisable) private var concurrencyDisable = ServerSettings.defaultConcurrencyDisable
    @AppStorage(SettingsKeys.vramReserve) private var vramReserve = 1024
    @AppStorage(SettingsKeys.gpuIndex) private var gpuIndex = -1
    @AppStorage(SettingsKeys.extraArgs) private var extraArgs = ""
    @AppStorage(SettingsKeys.cacheTypeK) private var cacheTypeK = "f16"
    @AppStorage(SettingsKeys.cacheTypeV) private var cacheTypeV = "f16"
    @AppStorage(SettingsKeys.mlock) private var mlock = false
    @AppStorage(SettingsKeys.cacheRAM) private var cacheRAM = 2048
    @AppStorage(SettingsKeys.reasoningInline) private var reasoningInline = false
    @AppStorage(SettingsKeys.specMTP) private var specMTP = false
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""
    @AppStorage(SettingsKeys.menuBarIcon) private var menuBarIcon = true
    @AppStorage(SettingsKeys.autoStart) private var autoStart = false
    @AppStorage(SettingsKeys.apiKeyEnabled) private var apiKeyEnabled = false
    @State private var profileName = ""

    // TurboQuant KV types only exist in the experimental engine (llama.cpp PR 23962) or external builds
    private var availableKVTypes: [String] {
        serverBinary == ServerSettings.defaultBinary
            ? ServerSettings.kvCacheTypes
            : ServerSettings.kvCacheTypes + ["turbo4", "turbo3", "turbo2"]
    }

    private var engineSelection: Binding<String> {
        Binding(
            get: {
                if serverBinary == ServerSettings.defaultBinary { return "bundled" }
                if serverBinary == ServerSettings.turboBinary { return "turbo" }
                return "custom"
            },
            set: { kind in
                switch kind {
                case "bundled": serverBinary = ServerSettings.defaultBinary
                case "turbo": serverBinary = ServerSettings.turboBinary ?? ServerSettings.defaultBinary
                default: serverBinary = ""
                }
            })
    }

    var body: some View {
        Form {
            Section(loc.t("Aplicación", "Application")) {
                Picker(loc.t("Idioma", "Language"), selection: $loc.isSpanish) {
                    Text("Español").tag(true)
                    Text("English").tag(false)
                }
                .help(loc.t("Idioma de toda la interfaz de ToshLLM.",
                            "Language for the entire ToshLLM interface."))
                Toggle(loc.t("Icono en la barra de menús", "Menu bar icon"), isOn: $menuBarIcon)
                    .help(loc.t("Muestra un icono en la barra de menús con el estado del servidor y controles rápidos, aunque la ventana esté cerrada.",
                                "Shows a menu bar icon with server status and quick controls, even with the window closed."))
                Toggle(loc.t("Iniciar servidor al abrir la app", "Start server on app launch"), isOn: $autoStart)
                    .help(loc.t("Arranca automáticamente el último modelo configurado al abrir ToshLLM.",
                                "Automatically starts the last configured model when ToshLLM opens."))
                Toggle(loc.t("Proteger la API con clave", "Protect the API with a key"), isOn: $apiKeyEnabled)
                    .help(loc.t("Genera una clave (guardada en el Llavero) que el servidor exige a cada petición. El chat de la app la usa automáticamente; útil en Macs compartidas.",
                                "Generates a key (stored in the Keychain) required on every request. The in-app chat uses it automatically; useful on shared Macs."))
                if apiKeyEnabled {
                    HStack {
                        Text(loc.t("Clave", "Key")).foregroundStyle(.secondary)
                        Text(Keychain.apiKey())
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Keychain.apiKey(), forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help(loc.t("Copiar para usarla desde otros clientes (Authorization: Bearer …).",
                                        "Copy to use from other clients (Authorization: Bearer …)."))
                    }
                    .font(.caption)
                }
            }

            Section(loc.t("Perfiles", "Profiles")) {
                HStack {
                    TextField(loc.t("Nombre del perfil (p. ej. Código, Chat rápido)",
                                    "Profile name (e.g. Coding, Quick chat)"), text: $profileName)
                        .textFieldStyle(.roundedBorder)
                    Button(loc.t("Guardar actual", "Save current")) {
                        profileStore.saveCurrent(name: profileName.trimmingCharacters(in: .whitespaces))
                        profileName = ""
                    }
                    .disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help(loc.t("Guarda toda la configuración actual (modelo incluido) con este nombre.",
                                "Saves the entire current configuration (model included) under this name."))
                }
                ForEach(profileStore.profiles) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).fontWeight(.medium)
                            Text(URL(fileURLWithPath: p.modelPath).lastPathComponent)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(loc.t("Aplicar", "Apply")) { profileStore.apply(p) }
                            .help(loc.t("Carga esta configuración. Reinicia el servidor para usarla.",
                                        "Loads this configuration. Restart the server to use it."))
                        Button { profileStore.delete(p) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .help(loc.t("Eliminar este perfil.", "Delete this profile."))
                    }
                }
            }

            Section(loc.t("GPU y memoria", "GPU & memory")) {
                Picker(loc.t("GPU (Metal)", "GPU (Metal)"), selection: $gpuIndex) {
                    Text(loc.t("Predeterminada", "Default")).tag(-1)
                    ForEach(hardware.gpus) { g in
                        Text("\(g.index): \(g.name) · \(g.vramMB / 1024) GB").tag(g.index)
                    }
                }
                .help(loc.t("Qué GPU usa el servidor si tienes varias. 'Predeterminada' deja elegir a Metal.",
                            "Which GPU the server uses if you have several. 'Default' lets Metal choose."))
                Stepper(loc.t("Capas en GPU (-ngl): \(ngl)", "GPU layers (-ngl): \(ngl)"),
                        value: $ngl, in: 0...99)
                    .help(loc.t("Cuántas capas del modelo van a la GPU. 99 = todas (recomendado si caben en VRAM); bájalo solo si la VRAM se desborda.",
                                "How many model layers go to the GPU. 99 = all (recommended if they fit in VRAM); lower it only if VRAM overflows."))
                Stepper(loc.t("Expertos MoE en CPU: \(ncmoe)", "MoE experts on CPU: \(ncmoe)"),
                        value: $ncmoe, in: 0...99)
                    .help(loc.t("Solo modelos MoE: capas cuyos 'expertos' viven en RAM y los procesa el CPU. Se ajusta solo al elegir modelo; súbelo si la VRAM se satura, bájalo si te sobra.",
                                "MoE models only: layers whose 'experts' live in RAM and run on the CPU. Auto-set when picking a model; raise if VRAM saturates, lower if you have headroom."))
                Stepper(loc.t("Reserva de VRAM: \(vramReserve) MB", "VRAM reserve: \(vramReserve) MB"),
                        value: $vramReserve, in: 256...4096, step: 256)
                    .help(loc.t("VRAM que se deja libre para el sistema y la interfaz. 1024 MB es un margen seguro.",
                                "VRAM left free for the system and UI. 1024 MB is a safe margin."))
                Toggle(loc.t("Copiar pesos a VRAM (--no-mmap, recomendado)",
                             "Copy weights to VRAM (--no-mmap, recommended)"), isOn: $noMmap)
                    .help(loc.t("Copia los pesos a la VRAM en vez de leerlos por PCIe en cada token. En GPU dedicada multiplica la velocidad (~6×). Desactívalo solo para depurar.",
                                "Copies weights into VRAM instead of reading them over PCIe per token. On a discrete GPU this multiplies speed (~6×). Disable only for debugging."))
                Toggle(loc.t("Bloquear modelo en RAM (--mlock)", "Lock model in RAM (--mlock)"), isOn: $mlock)
                    .help(loc.t("Impide que macOS mueva el modelo a swap o lo comprima: estabilidad de velocidad constante. Útil con modelos MoE grandes; requiere RAM suficiente.",
                                "Prevents macOS from swapping or compressing the model: consistent speed. Useful with large MoE models; requires enough free RAM."))
                Picker(loc.t("Caché de prompts en RAM", "Prompt cache in RAM"), selection: $cacheRAM) {
                    Text(loc.t("Desactivada", "Disabled")).tag(0)
                    Text("1 GB").tag(1024)
                    Text("2 GB").tag(2048)
                    Text("4 GB").tag(4096)
                    Text("8 GB").tag(8192)
                }
                .help(loc.t("RAM extra donde el motor recuerda conversaciones recientes para no reprocesarlas al cambiar de chat o cliente. Sin límite el motor usa hasta 8 GB: junto a un modelo grande lleva al equipo a swap y la velocidad se degrada con el uso. 2 GB es un buen equilibrio.",
                            "Extra RAM where the engine remembers recent conversations to avoid reprocessing them when switching chats or clients. Unlimited, the engine uses up to 8 GB: next to a large model that pushes the machine into swap and speed degrades over time. 2 GB is a good balance."))
            }

            Section(loc.t("Inferencia y contexto", "Inference & context")) {
                Picker(loc.t("Contexto", "Context"), selection: $ctx) {
                    ForEach([4096, 8192, 16384, 32768, 65536], id: \.self) { Text("\($0) tokens").tag($0) }
                }
                .help(loc.t("Tamaño máximo de la conversación en tokens. Más contexto = más memoria para el KV cache (mira los tipos de abajo para compensar).",
                            "Maximum conversation size in tokens. More context = more KV cache memory (see the types below to compensate)."))
                Toggle(loc.t("Autocompactar conversaciones largas", "Auto-compact long conversations"), isOn: $chatAutoCompact)
                    .help(loc.t("Al superar ~70% del contexto, el chat resume los mensajes antiguos con el propio modelo y envía solo el resumen + los mensajes recientes. La conversación completa sigue visible y guardada.",
                                "Past ~70% of the context, the chat summarizes older messages with the model itself and sends only the summary + recent messages. The full conversation stays visible and saved."))
                Picker(loc.t("KV cache: claves (-ctk)", "KV cache: keys (-ctk)"), selection: $cacheTypeK) {
                    ForEach(availableKVTypes, id: \.self) { Text($0).tag($0) }
                }
                .help(loc.t("Cuantización de las claves del KV cache. En GPU AMD: q8_0 reduce las claves a la mitad casi sin costo de velocidad (recomendado); q4_0 a un cuarto. Los tipos turbo* (TurboQuant) requieren el motor externo experimental.",
                            "Quantization for KV cache keys. On AMD GPUs: q8_0 halves key memory at almost no speed cost (recommended); q4_0 quarters it. turbo* types (TurboQuant) require the experimental external engine."))
                Picker(loc.t("KV cache: valores (-ctv)", "KV cache: values (-ctv)"), selection: $cacheTypeV) {
                    ForEach(availableKVTypes, id: \.self) { Text($0).tag($0) }
                }
                .help(loc.t("Cuantización de los valores del KV cache. ⚠️ En GPU AMD esto fuerza Flash Attention en CPU: la generación baja ~3× (de ~50 a ~15-19 t/s en un 8B). Úsalo solo cuando necesites contexto enorme; si no, déjalo en f16 y cuantiza solo las claves.",
                            "Quantization for KV cache values. ⚠️ On AMD GPUs this forces Flash Attention onto the CPU: generation drops ~3× (from ~50 to ~15-19 t/s on an 8B). Use only when you need huge context; otherwise keep f16 and quantize keys only."))
                Stepper(loc.t("Hilos de CPU: \(threads)", "CPU threads: \(threads)"),
                        value: $threads, in: 1...16)
                    .help(loc.t("Hilos para la parte que corre en CPU (expertos MoE, tokenización). Los núcleos físicos (\(hardware.physicalCores)) suelen ser el óptimo; más hilos no acelera si el límite es la RAM.",
                                "Threads for the CPU side (MoE experts, tokenization). Physical cores (\(hardware.physicalCores)) are usually optimal; more threads won't help if RAM bandwidth is the limit."))
                Picker("Flash Attention", selection: $flashAttn) {
                    Text("auto").tag("auto"); Text("on").tag("on"); Text("off").tag("off")
                }
                .help(loc.t("Atención optimizada en memoria. 'auto' la activa solo donde el backend la soporta bien (recomendado en GPU AMD). Necesaria para cuantizar los valores del KV cache.",
                            "Memory-efficient attention. 'auto' enables it only where the backend supports it well (recommended on AMD GPUs). Required for quantized KV cache values."))
                Toggle(loc.t("Aceleración MTP (especulativa)", "MTP acceleration (speculative)"), isOn: $specMTP)
                    .help(loc.t("Multi-token prediction: ~+30% de generación sin pérdida de calidad. Requiere un GGUF con cabezal MTP (variantes '-MTP-'); con otros modelos se ignora automáticamente.",
                                "Multi-token prediction: ~+30% generation with zero quality loss. Requires a GGUF with the MTP head ('-MTP-' variants); silently skipped for other models."))
                if specMTP && !modelPath.isEmpty && !ServerSettings.modelHasMTP(at: modelPath) {
                    Label(loc.t("El modelo actual no trae cabezal MTP: la opción se ignorará.",
                                "Current model has no MTP head: the option will be ignored."),
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle(loc.t("Razonamiento como texto (clientes externos)",
                             "Reasoning as plain text (external clients)"), isOn: $reasoningInline)
                    .help(loc.t("Envía el razonamiento dentro de la respuesta (<think>…) en vez del campo aparte reasoning_content. Actívalo si un cliente externo (VS Code, plugins) se queda 'pensando' sin mostrar nada. El chat de la app entiende ambos formatos.",
                                "Sends the reasoning inline in the response (<think>…) instead of the separate reasoning_content field. Enable it if an external client (VS Code, plugins) appears stuck 'thinking' showing nothing. The in-app chat understands both formats."))
                Toggle(loc.t("Plantilla de chat (--jinja)", "Chat template (--jinja)"), isOn: $jinja)
                    .help(loc.t("Usa la plantilla de chat oficial del modelo (formato de mensajes, herramientas). Déjalo activado salvo problemas con un modelo concreto.",
                                "Uses the model's official chat template (message format, tools). Keep it on unless a specific model misbehaves."))
                Toggle(loc.t("Estabilidad AMD dGPU (concurrencia desactivada)",
                             "AMD dGPU stability (concurrency disabled)"), isOn: $concurrencyDisable)
                    .help(loc.t("Imprescindible en GPUs AMD discretas: sin esto la salida se corrompe (texto basura).",
                                "Required on discrete AMD GPUs: output corrupts (garbage text) without it."))
            }

            Section(loc.t("Avanzado", "Advanced")) {
                TextField(loc.t("Puerto", "Port"), value: $port, format: .number)
                    .help(loc.t("Puerto local del servidor (API compatible con OpenAI y chat web).",
                                "Local server port (OpenAI-compatible API and web chat)."))
                Picker(loc.t("Motor de inferencia", "Inference engine"), selection: engineSelection) {
                    Text(loc.t("Integrado (oficial)", "Bundled (official)")).tag("bundled")
                    if ServerSettings.turboBinary != nil {
                        Text("TurboQuant (experimental)").tag("turbo")
                    }
                    Text(loc.t("Externo…", "External…")).tag("custom")
                }
                .help(loc.t("Integrado: llama.cpp oficial, recomendado. TurboQuant: motor experimental con KV cache turbo2/3/4 (~6× más contexto, pero la generación baja ~3× en GPU AMD). Externo: cualquier llama-server tuyo.",
                            "Bundled: official llama.cpp, recommended. TurboQuant: experimental engine with turbo2/3/4 KV cache (~6× more context, but generation drops ~3× on AMD GPUs). External: any llama-server of yours."))
                if engineSelection.wrappedValue == "custom" {
                    TextField(loc.t("Ruta del llama-server externo", "External llama-server path"), text: $serverBinary)
                        .font(.system(.caption, design: .monospaced))
                        .help(loc.t("Ruta a un llama-server alternativo para probar otras builds.",
                                    "Path to an alternative llama-server to test other builds."))
                }
                TextField(loc.t("Argumentos extra", "Extra arguments"), text: $extraArgs)
                    .font(.system(.caption, design: .monospaced))
                    .help(loc.t("Argumentos adicionales de llama-server separados por espacios (para opciones que la app no expone).",
                                "Additional llama-server arguments, space-separated (for options the app doesn't expose)."))
                Text(loc.t("Los cambios se aplican al reiniciar el servidor.",
                           "Changes take effect when the server restarts."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(loc.t("Registro del servidor", "Server log")) {
                HStack {
                    Button {
                        exportDiagnostics()
                    } label: {
                        Label(loc.t("Exportar diagnóstico…", "Export diagnostics…"),
                              systemImage: "square.and.arrow.up")
                    }
                    .help(loc.t("Genera un archivo con tu hardware, configuración y el registro reciente, listo para adjuntar a un reporte de problema.",
                                "Creates a file with your hardware, settings and recent log, ready to attach to an issue report."))
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([server.logFileURL])
                    } label: {
                        Label(loc.t("Log completo en Finder", "Full log in Finder"),
                              systemImage: "doc.text.magnifyingglass")
                    }
                    .help(loc.t("El registro completo persiste en disco con rotación automática.",
                                "The complete log persists on disk with automatic rotation."))
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(server.log.isEmpty ? loc.t("(sin salida todavía)", "(no output yet)") : server.log)
                            .font(.system(size: 10.5, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id("logEnd")
                    }
                    .frame(height: 200)
                    .onChange(of: server.log) { _, _ in proxy.scrollTo("logEnd", anchor: .bottom) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func exportDiagnostics() {
        let settings = ServerSettings.fromDefaults()
        let logTail = (try? String(contentsOf: server.logFileURL, encoding: .utf8))?
            .split(separator: "\n").suffix(250).joined(separator: "\n") ?? server.log
        let gpu = hardware.bestGPU.map { "\($0.name) (\($0.vramMB) MB VRAM)" } ?? "—"
        let report = """
        ToshLLM \(AppInfo.version) — diagnostics
        Date: \(Date().formatted(.iso8601))

        ## Hardware
        CPU: \(hardware.cpuBrand) (\(hardware.physicalCores)c/\(hardware.logicalCores)t)
        RAM: \(Int(hardware.ramGB)) GB
        GPU: \(gpu)
        Arch: \(hardware.arch)

        ## Configuration
        model: \(URL(fileURLWithPath: settings.modelPath).lastPathComponent)
        engine: \(settings.serverBinary)
        args: \(settings.arguments.joined(separator: " "))

        ## Recent log
        \(logTail)
        """
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "toshllm-diagnostics.txt"
        if panel.runModal() == .OK, let url = panel.url {
            try? report.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
