import SwiftUI
import Charts

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var profileStore: ProfileStore
    @EnvironmentObject var control: ControlPanelState
    @EnvironmentObject var models: ModelStore

    @AppStorage(SettingsKeys.serverBinary) private var serverBinary = ServerSettings.defaultBinary
    @AppStorage(SettingsKeys.faAmd) private var faAmd = false
    @AppStorage(SettingsKeys.persistCache) private var persistCache = false
    @AppStorage(SettingsKeys.port) private var port = 8080
    @AppStorage(SettingsKeys.ngl) private var ngl = 99
    @AppStorage(SettingsKeys.ncmoe) private var ncmoe = 0
    @AppStorage(SettingsKeys.ctx) private var ctx = 16384
    @AppStorage(SettingsKeys.chatAutoCompact) private var chatAutoCompact = true
    @AppStorage(SettingsKeys.smoothTyping) private var smoothTyping = true
    @AppStorage(SettingsKeys.threads) private var threads = 6
    @AppStorage(SettingsKeys.flashAttn) private var flashAttn = "auto"
    @AppStorage(SettingsKeys.noMmap) private var noMmap = true
    @AppStorage(SettingsKeys.jinja) private var jinja = true
    @AppStorage(SettingsKeys.concurrencyDisable) private var concurrencyDisable = ServerSettings.defaultConcurrencyDisable
    @AppStorage(SettingsKeys.vramReserve) private var vramReserve = 1024
    @AppStorage(SettingsKeys.gpuIndex) private var gpuIndex = -1
    @AppStorage(SettingsKeys.multiGPU) private var multiGPU = false
    @AppStorage(SettingsKeys.forcePrivateBuffers) private var forcePrivateBuffers = false
    @AppStorage(SettingsKeys.cacheReuse) private var cacheReuse = true
    @AppStorage(SettingsKeys.extraArgs) private var extraArgs = ""
    @AppStorage(SettingsKeys.cacheTypeK) private var cacheTypeK = "f16"
    @AppStorage(SettingsKeys.cacheTypeV) private var cacheTypeV = "f16"
    @AppStorage(SettingsKeys.mlock) private var mlock = false
    @AppStorage(SettingsKeys.cacheRAM) private var cacheRAM = 2048
    @AppStorage(SettingsKeys.parallelSlots) private var parallelSlots = 1
    @AppStorage(SettingsKeys.reasoningInline) private var reasoningInline = false
    @AppStorage(SettingsKeys.specMTP) private var specMTP = false
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""
    @AppStorage(SettingsKeys.modelsDir) private var modelsDir = ""
    @AppStorage(SettingsKeys.menuBarIcon) private var menuBarIcon = true
    @AppStorage(SettingsKeys.autoStart) private var autoStart = false
    @AppStorage(SettingsKeys.apiKeyEnabled) private var apiKeyEnabled = false
    @AppStorage(SettingsKeys.localNetworkDiscovery) private var localNetworkDiscovery = false
    @State private var profileName = ""
    @State private var showResetConfirm = false

    // TurboQuant KV types only exist in the experimental engine (llama.cpp PR 23962) or external builds
    private var availableKVTypes: [String] {
        let base = serverBinary == ServerSettings.defaultBinary
            ? ServerSettings.kvCacheTypes
            : ServerSettings.kvCacheTypes + ["turbo4", "turbo3", "turbo2"]
        // cache-reuse crashes with turbo KV (no f32->turbo requantize kernel),
        // so the turbo types aren't offered while cache-reuse is on.
        return cacheReuse ? base.filter { !$0.hasPrefix("turbo") } : base
    }
    private var turboKVAvailable: Bool {
        serverBinary != ServerSettings.defaultBinary
    }
    private var serverIsStopped: Bool {
        if case .stopped = server.state { return true }
        if case .failed = server.state { return true }
        return false
    }
    private var currentModelIsVision: Bool {
        ServerSettings.mmprojPath(forModel: modelPath) != nil
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
                case "turbo": serverBinary = ServerSettings.turboBinary ?? ServerSettings.defaultBinary
                case "bundled": serverBinary = ServerSettings.defaultBinary; faAmd = false
                default: serverBinary = ""; faAmd = false
                }
            })
    }

    private func chooseModelsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = loc.t("Elegir", "Choose")
        panel.directoryURL = models.directory
        if panel.runModal() == .OK, let url = panel.url {
            modelsDir = url.path
            models.refresh()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(role: .destructive) { showResetConfirm = true } label: {
                    Label(loc.t("Restablecer opciones por defecto", "Reset options to defaults"),
                          systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .help(loc.t("Devuelve todas las opciones (motor, GPU, inferencia, chat) a sus valores por defecto. No elimina modelos ni cambia la carpeta de modelos.",
                            "Returns every option (engine, GPU, inference, chat) to its default value. It does not delete models or change the models folder."))
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 4)

            settingsForm
        }
        .confirmationDialog(
            loc.t("¿Restablecer todas las opciones a sus valores por defecto?",
                  "Reset all options to their defaults?"),
            isPresented: $showResetConfirm, titleVisibility: .visible
        ) {
            Button(loc.t("Restablecer", "Reset"), role: .destructive) {
                SettingsKeys.resetOptionsToDefaults()
            }
            Button(loc.t("Cancelar", "Cancel"), role: .cancel) {}
        } message: {
            Text(loc.t("Tus modelos descargados y la carpeta de modelos se conservan.",
                       "Your downloaded models and models folder are kept."))
        }
    }

    private var settingsForm: some View {
        Form {
            Section(loc.t("Aplicación", "Application")) {
                Picker(loc.t("Idioma", "Language"), selection: $loc.language) {
                    ForEach(loc.availableLanguages, id: \.self) { code in
                        Text(loc.displayName(code)).tag(code)
                    }
                }
                .infoTip(loc.t("Idioma de toda la interfaz de ToshLLM. Los idiomas aportados por la comunidad aparecen automáticamente.",
                            "Language for the entire ToshLLM interface. Community-contributed languages appear here automatically."))
                Toggle(loc.t("Icono en la barra de menús", "Menu bar icon"), isOn: $menuBarIcon)
                    .infoTip(loc.t("Muestra un icono en la barra de menús con el estado del servidor y controles rápidos, aunque la ventana esté cerrada.",
                                "Shows a menu bar icon with server status and quick controls, even with the window closed."))
                Toggle(loc.t("Iniciar servidor al abrir la app", "Start server on app launch"), isOn: $autoStart)
                    .infoTip(loc.t("Arranca automáticamente el último modelo configurado al abrir ToshLLM.",
                                "Automatically starts the last configured model when ToshLLM opens."))
                Toggle(loc.t("Proteger la API con clave", "Protect the API with a key"), isOn: $apiKeyEnabled)
                    .infoTip(loc.t("Genera una clave (guardada en el Llavero) que el servidor exige a cada petición. El chat de la app la usa automáticamente; útil en Macs compartidas.",
                                "Generates a key (stored in the Keychain) required on every request. The in-app chat uses it automatically; useful on shared Macs."))
                Toggle(loc.t("Descubrible en red local", "Discoverable on local network"), isOn: $localNetworkDiscovery)
                    .disabled(!serverIsStopped)
                    .infoTip(loc.t("Hace que el servidor escuche en la red local y lo anuncia con Bonjour como 'ToshLLM API'. Actívalo solo en redes confiables; se aplica al reiniciar el servidor.",
                                "Makes the server listen on the local network and advertises it with Bonjour as 'ToshLLM API'. Enable only on trusted networks; takes effect when the server restarts."))
                if localNetworkDiscovery && !apiKeyEnabled {
                    Label(loc.t("Recomendado: activa 'Proteger la API con clave' antes de exponer el servidor en la red local.",
                                "Recommended: enable 'Protect the API with a key' before exposing the server on the local network."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !serverIsStopped {
                    Label(loc.t("Los cambios de red se aplican al reiniciar el servidor.",
                                "Network changes take effect after restarting the server."),
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                            .infoTip(loc.t("Copiar para usarla desde otros clientes (Authorization: Bearer …).",
                                        "Copy to use from other clients (Authorization: Bearer …)."))
                    }
                    .font(.caption)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(loc.t("Carpeta de modelos", "Models folder"))
                        Spacer()
                        Button(loc.t("Cambiar…", "Change…")) { chooseModelsFolder() }
                        if !modelsDir.isEmpty {
                            Button(loc.t("Restablecer", "Reset")) {
                                modelsDir = ""
                                models.refresh()
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .infoTip(loc.t("Carpeta donde se descargan, buscan y eliminan los modelos .gguf. Por defecto es ~/models. Al cambiarla, los modelos ya descargados en la carpeta anterior no se mueven; muévelos a mano si los quieres en la nueva.",
                                "Folder where .gguf models are downloaded, scanned and deleted. Defaults to ~/models. When you change it, models already in the old folder are not moved; move them yourself if you want them in the new one."))
                    Text(models.directory.path)
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
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
                    .infoTip(loc.t("Guarda toda la configuración actual (modelo incluido) con este nombre.",
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
                            .infoTip(loc.t("Carga esta configuración. Reinicia el servidor para usarla.",
                                        "Loads this configuration. Restart the server to use it."))
                        Button { profileStore.delete(p) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .infoTip(loc.t("Eliminar este perfil.", "Delete this profile."))
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
                .infoTip(loc.t("Qué GPU usa el servidor si tienes varias. 'Predeterminada' deja elegir a Metal.",
                            "Which GPU the server uses if you have several. 'Default' lets Metal choose."))
                .disabled(multiGPU)
                if hardware.gpus.count > 1 {
                    Toggle(loc.t("Repartir el modelo entre todas las GPUs (experimental)",
                                 "Split model across all GPUs (experimental)"), isOn: $multiGPU)
                        .infoTip(loc.t("Divide las capas del modelo entre todas las GPUs detectadas (--split-mode layer) en vez de usar una sola, p. ej. para cargar un modelo que no cabe en una. Anula el selector de arriba.",
                                    "Splits the model's layers across all detected GPUs (--split-mode layer) instead of using one, e.g. to load a model that doesn't fit on a single card. Overrides the picker above."))
                    if multiGPU {
                        Label(loc.t("⚠️ Experimental y sin validar en GPU AMD/Metal: el reparto entre GPUs es una ruta distinta que podría dar salida incorrecta o colgar el motor. Verifica que la generación sea coherente y vigila la estabilidad. Necesita más pruebas.",
                                    "⚠️ Experimental and unvalidated on AMD/Metal: cross-GPU splitting is a different path that could produce wrong output or hang the engine. Check that generation is coherent and watch stability. Needs more testing."),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .labelStyle(.titleAndIcon)
                    }
                }
                // eGPU fix: shown only when an external GPU is present. When the user
                // pins the picker to an eGPU it's automatic; this covers the default
                // case (macOS picks the eGPU and the app can't tell).
                if ServerController.hasExternalGPU() {
                    Toggle(loc.t("Pesos residentes en VRAM (recomendado para eGPU)",
                                 "VRAM-resident weights (recommended for eGPU)"), isOn: $forcePrivateBuffers)
                        .infoTip(loc.t("El motor Metal usa memoria compartida (del sistema) en GPUs externas, lo que transfiere los pesos por Thunderbolt en cada operación y desploma la velocidad (~0.8 t/s). Esto fuerza buffers privados en VRAM. Si fijas una eGPU en el selector de arriba ya se activa solo; usa esto cuando dejas 'Predeterminada' y macOS elige la eGPU.",
                                    "The Metal backend uses shared (system) memory on external GPUs, which streams weights over Thunderbolt every op and tanks speed (~0.8 t/s). This forces private VRAM buffers. If you pin an eGPU in the picker above it's automatic; use this when you leave 'Default' and macOS picks the eGPU."))
                }
                Stepper(loc.t("Capas en GPU (-ngl): \(ngl)", "GPU layers (-ngl): \(ngl)"),
                        value: $ngl, in: 0...99)
                    .infoTip(loc.t("Cuántas capas del modelo van a la GPU. 99 = todas (recomendado si caben en VRAM); bájalo solo si la VRAM se desborda.",
                                "How many model layers go to the GPU. 99 = all (recommended if they fit in VRAM); lower it only if VRAM overflows."))
                let modelIsMoE = modelPath.isEmpty || ServerSettings.modelIsMoE(at: modelPath)
                Stepper(modelIsMoE
                            ? loc.t("Expertos MoE en CPU: \(ncmoe)", "MoE experts on CPU: \(ncmoe)")
                            : loc.t("Expertos MoE en CPU: no aplica (modelo denso)", "MoE experts on CPU: N/A (dense model)"),
                        value: $ncmoe, in: 0...99)
                    .disabled(!modelIsMoE)
                    .infoTip(loc.t("Solo modelos MoE: capas cuyos 'expertos' viven en RAM y los procesa el CPU. Se ajusta solo al elegir modelo; súbelo si la VRAM se satura, bájalo si te sobra. (Deshabilitado en modelos densos, donde el motor lo ignora.)",
                                "MoE models only: layers whose 'experts' live in RAM and run on the CPU. Auto-set when picking a model; raise if VRAM saturates, lower if you have headroom. (Disabled on dense models, where the engine ignores it.)"))
                Stepper(loc.t("Reserva de VRAM: \(vramReserve) MB", "VRAM reserve: \(vramReserve) MB"),
                        value: $vramReserve, in: 256...4096, step: 256)
                    .infoTip(loc.t("VRAM que se deja libre para el sistema y la interfaz. 1024 MB es un margen seguro.",
                                "VRAM left free for the system and UI. 1024 MB is a safe margin."))
                Toggle(loc.t("Copiar pesos a VRAM (--no-mmap, recomendado)",
                             "Copy weights to VRAM (--no-mmap, recommended)"), isOn: $noMmap)
                    .infoTip(loc.t("Copia los pesos a la VRAM en vez de leerlos por PCIe en cada token. En GPU dedicada multiplica la velocidad (~6×). Desactívalo solo para depurar.",
                                "Copies weights into VRAM instead of reading them over PCIe per token. On a discrete GPU this multiplies speed (~6×). Disable only for debugging."))
                Toggle(loc.t("Bloquear modelo en RAM (--mlock)", "Lock model in RAM (--mlock)"), isOn: $mlock)
                    .infoTip(loc.t("Impide que macOS mueva el modelo a swap o lo comprima: estabilidad de velocidad constante. Útil con modelos MoE grandes; requiere RAM suficiente.",
                                "Prevents macOS from swapping or compressing the model: consistent speed. Useful with large MoE models; requires enough free RAM."))
                Picker(loc.t("Caché de prompts en RAM", "Prompt cache in RAM"), selection: $cacheRAM) {
                    Text(loc.t("Desactivada", "Disabled")).tag(0)
                    Text("1 GB").tag(1024)
                    Text("2 GB").tag(2048)
                    Text("4 GB").tag(4096)
                    Text("8 GB").tag(8192)
                }
                .infoTip(loc.t("RAM extra donde el motor recuerda conversaciones recientes para no reprocesarlas al cambiar de chat o cliente. Sin límite el motor usa hasta 8 GB: junto a un modelo grande lleva al equipo a swap y la velocidad se degrada con el uso. 2 GB es un buen equilibrio.",
                            "Extra RAM where the engine remembers recent conversations to avoid reprocessing them when switching chats or clients. Unlimited, the engine uses up to 8 GB: next to a large model that pushes the machine into swap and speed degrades over time. 2 GB is a good balance."))
            }

            Section(loc.t("Inferencia y contexto", "Inference & context")) {
                Picker(loc.t("Contexto", "Context"), selection: $ctx) {
                    ForEach([4096, 8192, 16384, 32768, 65536, 131072, 262144], id: \.self) { n in
                        Text("\(n / 1024)k tokens").tag(n)
                    }
                }
                .infoTip(loc.t("Tamaño máximo de la conversación en tokens. Más contexto = más memoria para el KV cache (mira los tipos de abajo para compensar).",
                            "Maximum conversation size in tokens. More context = more KV cache memory (see the types below to compensate)."))
                if ctx >= 131072 {
                    Label(loc.t("Contexto muy grande (para pruebas). El KV cache puede no caber en VRAM/RAM; en GPU AMD sin Flash Attention la generación se ralentiza con la profundidad. Cuantiza las claves (q8_0) para compensar; para uso normal 16–32k.",
                                "Very large context (for testing). The KV cache may not fit in VRAM/RAM; on AMD GPUs without Flash Attention generation slows with depth. Quantize keys (q8_0) to compensate; 16–32k is fine for normal use."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(loc.t("Autocompactar conversaciones largas", "Auto-compact long conversations"), isOn: $chatAutoCompact)
                    .infoTip(loc.t("Al superar ~70% del contexto, el chat resume los mensajes antiguos con el propio modelo y envía solo el resumen + los mensajes recientes. La conversación completa sigue visible y guardada.",
                                "Past ~70% of the context, the chat summarizes older messages with the model itself and sends only the summary + recent messages. The full conversation stays visible and saved."))
                Toggle(loc.t("Animación de escritura fluida", "Smooth typing animation"), isOn: $smoothTyping)
                    .infoTip(loc.t("Revela la respuesta carácter a carácter a ritmo constante (efecto máquina de escribir), en vez de a saltos según llegan los tokens. Si notas que la generación se ralentiza en tu GPU, desactívalo para volver al renderizado directo (más rápido).",
                                "Reveals the answer character by character at a steady rate (typewriter effect) instead of in bursts as tokens arrive. If you notice generation slowing on your GPU, turn it off to return to direct rendering (faster)."))
                Picker(loc.t("KV cache: claves (-ctk)", "KV cache: keys (-ctk)"), selection: $cacheTypeK) {
                    ForEach(availableKVTypes, id: \.self) { Text($0).tag($0) }
                }
                .infoTip(faAmd
                    ? loc.t("Cuantización de las claves del KV cache. Con el kernel Flash Attention AMD, cualquier combinación estándar (f16/q8_0/q4_0 en claves y valores) corre en GPU a velocidad plena. Para máximo ahorro de memoria: q8_0/q8_0 (mitad, recomendado) o q4_0/q4_0 (un cuarto); para comprimir solo las claves manteniendo los valores en precisión completa: q8_0/f16 o q4_0/f16.",
                            "Quantization for KV cache keys. With the AMD Flash Attention kernel, any standard combination (f16/q8_0/q4_0 for keys and values) runs on the GPU at full speed. For maximum memory savings: q8_0/q8_0 (half, recommended) or q4_0/q4_0 (a quarter); to compress only the keys while keeping values at full precision: q8_0/f16 or q4_0/f16.")
                    : loc.t("Cuantización de las claves del KV cache. En GPU AMD (sin el kernel Flash Attention AMD): q8_0 reduce las claves a la mitad casi sin costo de velocidad (recomendado), dejando los valores en f16; q4_0 a un cuarto. Los tipos turbo* (TurboQuant) requieren el motor experimental.",
                            "Quantization for KV cache keys. On AMD GPUs (without the AMD Flash Attention kernel): q8_0 halves key memory at almost no speed cost (recommended), keeping values at f16; q4_0 quarters it. turbo* types (TurboQuant) require the experimental engine."))
                Picker(loc.t("KV cache: valores (-ctv)", "KV cache: values (-ctv)"), selection: $cacheTypeV) {
                    ForEach(availableKVTypes, id: \.self) { Text($0).tag($0) }
                }
                .infoTip(faAmd
                    ? loc.t("Cuantización de los valores del KV cache. Con el kernel Flash Attention AMD cualquier valor estándar (f16/q8_0/q4_0) corre en GPU a velocidad plena, en cualquier combinación con las claves. Cuantizar los valores ahorra más memoria; dejarlos en f16 (con claves cuantizadas) conserva más calidad — ambos van igual de rápidos.",
                            "Quantization for KV cache values. With the AMD Flash Attention kernel any standard value type (f16/q8_0/q4_0) runs on the GPU at full speed, in any combination with the keys. Quantizing values saves more memory; keeping them at f16 (with quantized keys) preserves more quality — both run equally fast.")
                    : loc.t("Cuantización de los valores del KV cache. ⚠️ En GPU AMD (sin el kernel Flash Attention AMD) esto fuerza Flash Attention en CPU: la generación baja ~3× (de ~50 a ~15-19 t/s en un 8B). Úsalo solo cuando necesites contexto enorme; si no, déjalo en f16 y cuantiza solo las claves.",
                            "Quantization for KV cache values. ⚠️ On AMD GPUs (without the AMD Flash Attention kernel) this forces Flash Attention onto the CPU: generation drops ~3× (from ~50 to ~15-19 t/s on an 8B). Use only when you need huge context; otherwise keep f16 and quantize keys only."))
                Toggle(loc.t("Reuso de caché de prompt (rápido)", "Prompt cache reuse (fast)"), isOn: $cacheReuse)
                    .onChange(of: cacheReuse) { _, on in
                        // Turbo KV is incompatible with cache-reuse; snap a stale
                        // turbo selection back to safe types when it's turned on.
                        if on {
                            if cacheTypeK.hasPrefix("turbo") { cacheTypeK = "q8_0" }
                            if cacheTypeV.hasPrefix("turbo") { cacheTypeV = "f16" }
                        }
                    }
                    .infoTip(loc.t("Cuando reescribes/editas el prompt (asistentes de código) o se recorta el razonamiento entre turnos, reutiliza la caché desplazándola en vez de reprocesar — mucho más rápido. Es una aproximación: la salida sigue coherente pero puede variar levemente frente a un cálculo exacto. Desactívalo si quieres resultados idénticos y reproducibles. Incompatible con los tipos KV turbo2/3/4.",
                                "When the prompt is rewritten/edited (coding assistants) or the reasoning is trimmed between turns, it reuses the cache by shifting it instead of reprocessing — much faster. It's an approximation: output stays coherent but can differ slightly from an exact recompute. Turn it off for identical, reproducible results. Incompatible with the turbo2/3/4 KV types."))
                if cacheReuse && turboKVAvailable {
                    Label(loc.t("Los tipos KV turbo2/3/4 no aparecen mientras el reuso de caché está activo (son incompatibles). Desactívalo para usarlos.",
                                "The turbo2/3/4 KV types are hidden while cache reuse is on (incompatible). Turn it off to use them."),
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Stepper(loc.t("Hilos de CPU: \(threads)", "CPU threads: \(threads)"),
                        value: $threads, in: 1...max(1, hardware.logicalCores))
                    .infoTip(loc.t("Hilos para la parte que corre en CPU (expertos MoE, tokenización). Tu equipo tiene \(hardware.logicalCores) hilos; los núcleos físicos (\(hardware.physicalCores)) suelen ser el óptimo; más hilos no acelera si el límite es la RAM.",
                                "Threads for the CPU side (MoE experts, tokenization). Your machine has \(hardware.logicalCores) threads; physical cores (\(hardware.physicalCores)) are usually optimal; more threads won't help if RAM bandwidth is the limit."))
                    .onAppear { if threads > hardware.logicalCores { threads = max(1, hardware.logicalCores) } }
                Picker("Flash Attention", selection: $flashAttn) {
                    Text("auto").tag("auto"); Text("on").tag("on"); Text("off").tag("off")
                }
                .disabled(faAmd)
                .infoTip(loc.t("Atención optimizada en memoria. 'auto' la activa solo donde el backend la soporta bien (recomendado en GPU AMD). Necesaria para cuantizar los valores del KV cache.",
                            "Memory-efficient attention. 'auto' enables it only where the backend supports it well (recommended on AMD GPUs). Required for quantized KV cache values."))
                if faAmd {
                    Label(loc.t("El kernel Flash Attention AMD lo fuerza a 'on'.",
                                "The AMD Flash Attention kernel forces this to 'on'."),
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(loc.t("Aceleración MTP (especulativa)", "MTP acceleration (speculative)"), isOn: $specMTP)
                    .infoTip(loc.t("Multi-token prediction: ~+30% de generación sin pérdida de calidad. Requiere un GGUF con cabezal MTP (variantes '-MTP-'); con otros modelos se ignora automáticamente.",
                                "Multi-token prediction: ~+30% generation with zero quality loss. Requires a GGUF with the MTP head ('-MTP-' variants); silently skipped for other models."))
                if specMTP && !modelPath.isEmpty && !ServerSettings.modelHasMTP(at: modelPath) {
                    Label(loc.t("El modelo actual no trae cabezal MTP: la opción se ignorará.",
                                "Current model has no MTP head: the option will be ignored."),
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Picker(loc.t("Peticiones simultáneas", "Concurrent requests"), selection: $parallelSlots) {
                    Text(loc.t("1 (recomendado)", "1 (recommended)")).tag(1)
                    Text("2").tag(2)
                    Text("4").tag(4)
                    Text("Auto").tag(0)
                }
                .infoTip(loc.t("Cuántas peticiones procesa el motor a la vez. Con 1, las peticiones hacen cola en vez de competir por la GPU, y un prompt enorme interrumpido por el timeout de un cliente (VS Code) se retoma donde iba al reintentar. Sube el valor solo si varios clientes usan el servidor a la vez.",
                            "How many requests the engine processes at once. With 1, requests queue instead of competing for the GPU, and a huge prompt interrupted by a client timeout (VS Code) resumes where it was on retry. Raise it only if several clients use the server at the same time."))
                Toggle(loc.t("Razonamiento como texto (clientes externos)",
                             "Reasoning as plain text (external clients)"), isOn: $reasoningInline)
                    .infoTip(loc.t("Envía el razonamiento dentro de la respuesta (<think>…) en vez del campo aparte reasoning_content. Actívalo si un cliente externo (VS Code, plugins) se queda 'pensando' sin mostrar nada. El chat de la app entiende ambos formatos.",
                                "Sends the reasoning inline in the response (<think>…) instead of the separate reasoning_content field. Enable it if an external client (VS Code, plugins) appears stuck 'thinking' showing nothing. The in-app chat understands both formats."))
                Toggle(loc.t("Plantilla de chat (--jinja)", "Chat template (--jinja)"), isOn: $jinja)
                    .infoTip(loc.t("Usa la plantilla de chat oficial del modelo (formato de mensajes, herramientas). Déjalo activado salvo problemas con un modelo concreto.",
                                "Uses the model's official chat template (message format, tools). Keep it on unless a specific model misbehaves."))
                Toggle(loc.t("Estabilidad AMD dGPU (concurrencia desactivada)",
                             "AMD dGPU stability (concurrency disabled)"), isOn: $concurrencyDisable)
                    .infoTip(loc.t("Imprescindible en GPUs AMD discretas: sin esto la salida se corrompe (texto basura).",
                                "Required on discrete AMD GPUs: output corrupts (garbage text) without it."))
            }

            Section(loc.t("Avanzado", "Advanced")) {
                TextField(loc.t("Puerto", "Port"), value: $port, format: .number.grouping(.never))
                    .infoTip(loc.t("Puerto local del servidor (API compatible con OpenAI y chat web).",
                                "Local server port (OpenAI-compatible API and web chat)."))
                Picker(loc.t("Motor de inferencia", "Inference engine"), selection: engineSelection) {
                    Text(loc.t("Integrado (oficial)", "Bundled (official)")).tag("bundled")
                    if ServerSettings.turboBinary != nil {
                        Text(loc.t("Experimental (TurboQuant)", "Experimental (TurboQuant)")).tag("turbo")
                    }
                    Text(loc.t("Externo…", "External…")).tag("custom")
                }
                .infoTip(loc.t("Integrado: llama.cpp oficial, recomendado. Experimental (TurboQuant): motor experimental con KV cache turbo2/3/4 (~6× más contexto, pero la generación baja ~3× en GPU AMD) e incluye el kernel Flash Attention AMD activable abajo. Externo: cualquier llama-server tuyo.",
                            "Bundled: official llama.cpp, recommended. Experimental (TurboQuant): experimental engine with turbo2/3/4 KV cache (~6× more context, but generation drops ~3× on AMD GPUs); also bundles the AMD Flash Attention kernel you can enable below. External: any llama-server of yours."))
                if engineSelection.wrappedValue == "turbo" {
                    Toggle(loc.t("Kernel Flash Attention AMD", "AMD Flash Attention kernel"), isOn: $faAmd)
                        .infoTip(loc.t("Activa un kernel Metal propio que ejecuta la atención —tanto el procesamiento del prompt como la generación— en la GPU AMD (define TOSH_FA_AMD y fuerza -fa activado), para cabezas de 128, 256 y 512 (cubre Gemma 4). Imprescindible con KV cuantizado/turbo: como ese KV obliga a -fa, sin este kernel la atención cae a CPU y se desploma (p. ej. prefill turbo ~6 → ~100 t/s; generación ~4 → ~30 t/s). Cubre cualquier KV estándar (f16/q8_0/q4_0) en cualquier combinación claves/valores.",
                                    "Enables a custom Metal kernel that runs attention — both prompt processing and generation — on the AMD GPU (sets TOSH_FA_AMD and forces -fa on), for head dim 128, 256 and 512 (covers Gemma 4). Essential with quantized/turbo KV: since that KV requires -fa, without this kernel attention falls back to CPU and collapses (e.g. turbo prefill ~6 → ~100 t/s; generation ~4 → ~30 t/s). Covers any standard KV (f16/q8_0/q4_0) in any keys/values combination."))
                    Toggle(loc.t("Recordar conversaciones (caché en disco)", "Remember conversations (disk cache)"), isOn: $persistCache)
                        .disabled(!faAmd || currentModelIsVision)
                        .infoTip(loc.t("Guarda en disco la caché KV de cada conversación, así al reabrir un chat o reiniciar la app no se reprocesa el prompt (en un prompt largo ahorra varios segundos por turno). Requiere el kernel Flash Attention AMD activo; con KV cuantizado (q8_0/q4_0) el archivo es más pequeño y la restauración más rápida. Los archivos viven en Application Support y se borran al eliminar la conversación.",
                                    "Saves each conversation's KV cache to disk, so reopening a chat or restarting the app skips re-processing the prompt (saves several seconds per turn on long prompts). Requires the AMD Flash Attention kernel; with quantized KV (q8_0/q4_0) the file is smaller and restore is faster. Files live in Application Support and are removed when you delete the conversation."))
                    if currentModelIsVision {
                        Label(loc.t("No disponible con modelos de visión: llama.cpp no permite guardar/restaurar slots cuando hay mmproj.",
                                    "Not available with vision models: llama.cpp cannot save/restore slots when mmproj is loaded."),
                              systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !faAmd {
                        Label(loc.t("Requiere activar el kernel Flash Attention AMD (arriba).",
                                    "Requires enabling the AMD Flash Attention kernel (above)."),
                              systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if engineSelection.wrappedValue == "custom" {
                    TextField(loc.t("Ruta del llama-server externo", "External llama-server path"), text: $serverBinary)
                        .font(.system(.caption, design: .monospaced))
                        .infoTip(loc.t("Ruta a un llama-server alternativo para probar otras builds.",
                                    "Path to an alternative llama-server to test other builds."))
                }
                TextField(loc.t("Argumentos extra", "Extra arguments"), text: $extraArgs)
                    .font(.system(.caption, design: .monospaced))
                    .infoTip(loc.t("Argumentos adicionales de llama-server separados por espacios (para opciones que la app no expone). Un token con forma CLAVE=VALOR se aplica como variable de entorno del motor, no como argumento. Ej.: en tarjetas AMD GCN/Vega (Vega 56/64, RX 580, Radeon VII) que dan texto corrupto, escribe GGML_METAL_WAVE64_SAFEMODE=1 para forzar salida coherente (más lento).",
                                "Additional llama-server arguments, space-separated (for options the app doesn't expose). A token shaped like KEY=VALUE is applied as an engine environment variable instead of an argument. E.g. on AMD GCN/Vega cards (Vega 56/64, RX 580, Radeon VII) that produce garbled text, type GGML_METAL_WAVE64_SAFEMODE=1 to force coherent output (slower)."))
                Text(loc.t("Los cambios se aplican al reiniciar el servidor.",
                           "Changes take effect when the server restarts."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(loc.t("Registro del servidor", "Server log")) {
                Button {
                    control.section = .logs
                } label: {
                    Label(loc.t("Abrir registro completo", "Open full log"),
                          systemImage: "list.bullet.rectangle")
                }
                .infoTip(loc.t("El registro del servidor, con búsqueda, filtros y exportación, está en la pestaña Registro.",
                            "The server log — with search, filters and export — lives in the Logs tab."))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - InfoTip

/// A small ⓘ next to a setting that reveals a styled explanation. Shows on a
/// short hover and can be pinned open with a click (click again or click away to
/// dismiss). Replaces the unstyleable native `.help()` tooltip.
struct InfoTip: View {
    let text: String
    /// When false (hover-reveal mode) the ⓘ is hidden until the host row is hovered
    /// or the popover is open — used outside Settings so the icon doesn't clutter.
    var forceVisible: Bool = true
    @State private var shown = false
    @State private var pinned = false
    @State private var hoverWork: DispatchWorkItem?

    var body: some View {
        Image(systemName: "info.circle")
            .imageScale(.medium)
            .foregroundStyle(shown ? Color.accentColor : .secondary)
            .opacity(forceVisible || shown ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: forceVisible)
            .contentShape(Rectangle())
            .onHover { inside in
                hoverWork?.cancel()
                if inside {
                    let work = DispatchWorkItem { shown = true }
                    hoverWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)  // short hover
                } else if !pinned {
                    shown = false
                }
            }
            .onTapGesture {
                hoverWork?.cancel()
                pinned.toggle()
                shown = pinned
            }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(width: 320)
                    .onDisappear { pinned = false }
            }
            .accessibilityLabel(Text(text))
    }
}

extension View {
    /// Drop-in replacement for `.help(_:)` that shows a styled, pinnable popover via
    /// an ⓘ button at the trailing edge of the row. In Settings the ⓘ is always
    /// visible; pass `revealOnHover: true` elsewhere so the ⓘ only fades in while the
    /// row is hovered (the styled tooltip without a permanent icon cluttering the UI).
    func infoTip(_ text: String, revealOnHover: Bool = false) -> some View {
        InfoTipRow(text: text, revealOnHover: revealOnHover) { self }
    }
}

/// Hosts a view plus its ⓘ, tracking row hover so the icon can be revealed on demand.
private struct InfoTipRow<Content: View>: View {
    let text: String
    let revealOnHover: Bool
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            content
            InfoTip(text: text, forceVisible: !revealOnHover || hovering)
        }
        .onHover { hovering = $0 }
    }
}
