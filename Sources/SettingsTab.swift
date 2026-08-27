// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Charts

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var manager: ServerManager
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var profileStore: ProfileStore
    @EnvironmentObject var control: ControlPanelState
    @EnvironmentObject var models: ModelStore

    @AppStorage(SettingsKeys.engineKind) private var engineKind = ServerSettings.engineKind
    @AppStorage(SettingsKeys.serverBinary) private var serverBinary = ""
    @AppStorage(SettingsKeys.faAmd) private var faAmd = ServerSettings.defaultFaAmd
    @AppStorage(SettingsKeys.prefetchExperts) private var prefetchExperts = true
    @AppStorage(SettingsKeys.dynamicMoe) private var dynamicMoe = false
    @AppStorage(SettingsKeys.dynamicMoeSlots) private var dynamicMoeSlots = 8
    @AppStorage(SettingsKeys.dynamicMoePrefetch) private var dynamicMoePrefetch = 4
    @AppStorage(SettingsKeys.dynamicMoePolicy) private var dynamicMoePolicy = "cache"
    @AppStorage(SettingsKeys.persistCache) private var persistCache = false
    @AppStorage(SettingsKeys.port) private var port = 8080
    @AppStorage(SettingsKeys.ngl) private var ngl = 99
    @AppStorage(SettingsKeys.ncmoe) private var ncmoe = 0
    @AppStorage(SettingsKeys.ctx) private var ctx = 16384
    @AppStorage(SettingsKeys.threads) private var threads = 6
    @AppStorage(SettingsKeys.flashAttn) private var flashAttn = "auto"
    @AppStorage(SettingsKeys.noMmap) private var noMmap = true
    @AppStorage(SettingsKeys.jinja) private var jinja = true
    @AppStorage(SettingsKeys.vramReserve) private var vramReserve = 1024
    @AppStorage(SettingsKeys.gpuIndex) private var gpuIndex = -1
    @AppStorage(SettingsKeys.multiGPU) private var multiGPU = false
    @AppStorage(SettingsKeys.multiGPUCount) private var multiGPUCount = 0
    @AppStorage(SettingsKeys.splitMode) private var splitMode = "layer"
    @AppStorage(SettingsKeys.mgpuEvents) private var mgpuEvents = true
    @AppStorage(SettingsKeys.mgpuPeer) private var mgpuPeer = false
    @AppStorage(SettingsKeys.gpuList) private var gpuListCSV = ""
    @AppStorage(SettingsKeys.embeddings) private var embeddings = false
    @AppStorage(SettingsKeys.forcePrivateBuffers) private var forcePrivateBuffers = false
    @AppStorage(SettingsKeys.cacheReuse) private var cacheReuse = true
    @AppStorage(SettingsKeys.extraArgs) private var extraArgs = ""
    @AppStorage(SettingsKeys.cacheTypeK) private var cacheTypeK = "f16"
    @AppStorage(SettingsKeys.cacheTypeV) private var cacheTypeV = "f16"
    @AppStorage(SettingsKeys.mlock) private var mlock = false
    @AppStorage(SettingsKeys.cacheRAM) private var cacheRAM = 2048
    @AppStorage(SettingsKeys.imageMaxTokens) private var imageMaxTokens = 0
    @AppStorage(SettingsKeys.parallelSlots) private var parallelSlots = 1
    @AppStorage(SettingsKeys.reasoningInline) private var reasoningInline = false
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""
    @AppStorage(SettingsKeys.modelsDir) private var modelsDir = ""
    @AppStorage(SettingsKeys.menuBarIcon) private var menuBarIcon = true
    @AppStorage(SettingsKeys.updateAutoCheck) private var updateAutoCheck = true
    @AppStorage(SettingsKeys.appAccent) private var appAccentRaw = AppTheme.defaultKey
    @AppStorage(SettingsKeys.menuBarGPU) private var menuBarGPU = "panel"
    @AppStorage(SettingsKeys.autoStart) private var autoStart = false
    @AppStorage(SettingsKeys.apiKeyEnabled) private var apiKeyEnabled = false
    @AppStorage(SettingsKeys.localNetworkDiscovery) private var localNetworkDiscovery = false
    @State private var profileName = ""
    @State private var showResetConfirm = false
    @State private var settingsTransferMessage: String?

    private var availableKVTypes: [String] {
        // Only f16/q8_0/q4_0 have an FA-AMD KV kernel; the other quant types fall
        // back to a ~3.7x slower path on Intel/AMD, so don't offer them there.
        // Keep an already-selected slow type visible so a migrated config isn't blank.
        if ServerSettings.isAppleSilicon { return ["f16", "q8_0", "q4_0"] }
        var types = ["f16", "q8_0", "q4_0"]
        if !modelPath.isEmpty && ServerSettings.modelSupportsTurboKV(at: modelPath) {
            types += ["turbo4", "turbo3"]
        }
        for t in [cacheTypeK, cacheTypeV] where !types.contains(t) { types.append(t) }
        return types
    }
    /// Why the chosen Turbo combination cannot run, so the warning names the actual cause
    /// instead of listing every reason Turbo might be unavailable.
    private var turboKVIncompatibleReason: (es: String, en: String)? {
        guard turboKVSelected else { return nil }
        if ServerSettings.isAppleSilicon {
            return ("TurboQuant KV solo está disponible en tarjetas sin memoria unificada.",
                    "TurboQuant KV is only available on cards without unified memory.")
        }
        if !ServerSettings.modelSupportsTurboKV(at: modelPath) {
            return ("Este modelo no admite TurboQuant KV: sus cabezas de atención no llegan a un múltiplo de 128.",
                    "This model does not support TurboQuant KV: its attention heads do not pad to a multiple of 128.")
        }
        if cacheTypeV.hasPrefix("turbo") && !cacheTypeK.hasPrefix("turbo") &&
            ServerSettings.modelUsesMLA(at: modelPath) {
            return ("Este modelo guarda claves y valores en una sola caché, así que ambos deben llevar el mismo tipo.",
                    "This model keeps keys and values in a single cache, so both must use the same type.")
        }
        return nil
    }
    private var turboKVIncompatible: Bool { turboKVIncompatibleReason != nil }
    private var turboKVSelected: Bool {
        cacheTypeK.hasPrefix("turbo") || cacheTypeV.hasPrefix("turbo")
    }
    /// Quantizing the keys is what costs quality; values tolerate 4 bits. Measured
    /// within 0.5% of f16 on 4B, 8B and 35B, at 25% less cache than q8_0/q8_0.
    private var kvSuggestion: (k: String, v: String)? {
        guard !ServerSettings.isAppleSilicon, !modelPath.isEmpty,
              ServerSettings.modelSupportsTurboKV(at: modelPath),
              !ServerSettings.modelUsesMLA(at: modelPath) else { return nil }
        return ("q8_0", "turbo4")
    }
    private var serverIsStopped: Bool {
        if case .stopped = server.state { return true }
        if case .failed = server.state { return true }
        return false
    }
    // Networking is a launch flag, so restart the running server to apply it now.
    private func setDiscoverable(_ on: Bool) {
        localNetworkDiscovery = on
        if !serverIsStopped { server.restart(.fromDefaults()) }
    }
    private var currentModelIsVision: Bool {
        ServerSettings.mmprojPath(forModel: modelPath) != nil
    }
    private var splitSelection: [Int] { ServerSettings.gpuList(fromCSV: gpuListCSV) }
    /// macOS exposes the bridge nowhere else: linked GPUs share a Metal peer group.
    private var hasPeerLink: Bool { !hardware.peerGroups.isEmpty }
    private func toggleSplitGPU(_ i: Int) {
        var sel = Set(splitSelection)
        if sel.contains(i) { sel.remove(i) } else { sel.insert(i) }
        gpuListCSV = sel.sorted().map(String.init).joined(separator: ",")
    }
    private var kvNeedsFlashAttention: Bool { cacheTypeK != "f16" || cacheTypeV != "f16" }
    private var amdFlashActive: Bool { faAmd }
    private var dynamicMoeUIUnlocked: Bool {
        ShellWords.split(extraArgs).contains("TOSH_MOE_UI=1")
    }
    private var dynamicMoeAutoRoute: DynamicMoeAutoRoute {
        ServerSettings.fromDefaults().dynamicMoeAutoRoute
    }
    private var dynamicMoeModelInfo: DynamicMoeModelInfo? {
        ServerSettings.fromDefaults().dynamicMoeModelInfo
    }
    private var dynamicMoeProfile: DynamicMoeOptimizationProfile? {
        ServerSettings.fromDefaults().dynamicMoeOptimizationProfile
    }
    private var dynamicMoeSlotPlan: DynamicMoeSlotPlan? {
        ServerSettings.fromDefaults().dynamicMoeSlotPlan()
    }
    private var effectiveDynamicMoeSlots: Int {
        ServerSettings.fromDefaults().effectiveDynamicMoeSlots
    }
    private var dynamicMoeSlotBinding: Binding<Int> {
        Binding(
            get: { effectiveDynamicMoeSlots },
            set: { v in
                guard let info = dynamicMoeModelInfo else { dynamicMoeSlots = v; return }
                let floor = min(max(info.activeExpertCount, 1), info.expertCount)
                dynamicMoeSlots = min(max(v, floor), info.expertCount)
            })
    }
    private func gibLabel(_ bytes: UInt64) -> String {
        String(format: "%.2f GiB", Double(bytes) / 1_073_741_824)
    }
    private var dynamicMoeIsEffective: Bool {
        dynamicMoe && dynamicMoeUIUnlocked
            && (dynamicMoePolicy != "auto" || dynamicMoeAutoRoute == .cache)
    }
    private var dynamicMoeAutoMessage: String {
        switch dynamicMoeAutoRoute {
        case .cache:
            if let profile = dynamicMoeProfile {
                return profile.route == .split
                    ? loc.t("Auto usa el perfil optimizado dividido K\(profile.slots) + ring\(profile.ringSlots). El mapa seguirá adaptándose durante el uso.",
                            "Auto uses the optimized split profile K\(profile.slots) + ring\(profile.ringSlots). The map keeps adapting during use.")
                    : loc.t("Auto usa el perfil directo K\(profile.slots), porque el banco de expertos cabe en la ventana Metal.",
                            "Auto uses the direct K\(profile.slots) profile because the expert bank fits in the Metal window.")
            }
            return loc.t("Auto eligió caché dinámica: el modelo no cabe con margen en VRAM y hay RAM suficiente.",
                         "Auto selected dynamic cache: the model does not fit in VRAM with headroom and enough RAM is available.")
        case .normalDense:
            return loc.t("Auto eligió normal: el modelo no es MoE.", "Auto selected normal: the model is not MoE.")
        case .normalFitsVRAM:
            return loc.t("Auto eligió normal: el modelo cabe en VRAM con el margen configurado.",
                  "Auto selected normal: the model fits in VRAM with the configured headroom.")
        case .normalInsufficientRAM:
            return loc.t("Auto eligió normal: no hay RAM física suficiente para fijar el banco de expertos.",
                  "Auto selected normal: there is not enough physical RAM to pin the expert bank.")
        case .normalUnsupportedGPU:
            return loc.t("Auto eligió normal: se necesita una GPU discreta compatible.",
                  "Auto selected normal: a compatible discrete GPU is required.")
        case .normalMissingModel:
            return loc.t("Auto espera un modelo válido para decidir.", "Auto is waiting for a valid model before deciding.")
        case .normalSplitOrRouter:
            return loc.t("Auto eligió normal: Dynamic MoE aún no admite split ni router.",
                  "Auto selected normal: Dynamic MoE does not support split or router yet.")
        case .normalMissingMetadata:
            return loc.t("Auto eligió normal: el GGUF no declara capas, expertos totales y expertos activos.",
                  "Auto selected normal: the GGUF does not declare layers, total experts, and active experts.")
        case .normalInsufficientVRAM:
            return loc.t("Auto eligió normal: ni la caché mínima de expertos cabe con los márgenes configurados.",
                  "Auto selected normal: even the minimum expert cache does not fit with the configured headroom.")
        case .normalNoCacheBenefit:
            return loc.t("Auto eligió normal: todos los expertos de la capa están activos y la caché no reduciría VRAM.",
                  "Auto selected normal: every expert in the layer is active, so the cache would not reduce VRAM.")
        case .normalOversizedHostBank:
            return loc.t("Auto eligió normal: el banco de expertos supera la ventana Metal validada para esta GPU.",
                  "Auto selected normal: the expert bank exceeds the validated Metal window for this GPU.")
        }
    }

    private var engineSelection: Binding<String> {
        Binding(
            get: { engineKind },
            set: { kind in
                engineKind = kind
                if kind == "bundled" {
                    serverBinary = ""
                    faAmd = ServerSettings.defaultFaAmd
                } else {
                    faAmd = false
                    dynamicMoe = false
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
                if manager.servers.count > 1 {
                    Label(loc.t("Los servidores añadidos heredan estos ajustes, salvo lo que cambies en su tarjeta del Dashboard.",
                                "Added servers inherit these settings, except what you change on their Dashboard card."),
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(loc.t("Importar", "Import"), systemImage: "square.and.arrow.down") {
                    importSettings()
                }
                .buttonStyle(.bordered)
                Button(loc.t("Exportar", "Export"), systemImage: "square.and.arrow.up") {
                    exportSettings()
                }
                .buttonStyle(.bordered)
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
        .alert(loc.t("Ajustes", "Settings"),
               isPresented: Binding(get: { settingsTransferMessage != nil },
                                    set: { if !$0 { settingsTransferMessage = nil } })) {
            Button("OK") { settingsTransferMessage = nil }
        } message: {
            Text(settingsTransferMessage ?? "")
        }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ToshLLM Settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SettingsArchive.exportData().write(to: url, options: .atomic)
            settingsTransferMessage = loc.t("Ajustes exportados correctamente.",
                                            "Settings exported successfully.")
        } catch {
            settingsTransferMessage = error.localizedDescription
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try SettingsArchive.importData(Data(contentsOf: url))
            settingsTransferMessage = loc.t("Se importaron \(count) ajustes. Reinicia el servidor para aplicar los cambios del motor.",
                                            "Imported \(count) settings. Restart the server to apply engine changes.")
        } catch {
            settingsTransferMessage = error.localizedDescription
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
                Picker(selection: $appAccentRaw) {
                    ForEach(AppTheme.palette, id: \.key) { entry in
                        Label {
                            Text(AppTheme.label(entry.key, loc))
                        } icon: {
                            Image(nsImage: AppTheme.swatchImage(entry.color))
                        }
                        .tag(entry.key)
                    }
                } label: {
                    Text(loc.t("Color de la app", "App color"))
                }
                .infoTip(loc.t("Color de marca de botones, iconos y controles de toda la app. Independiente del color de acento del sistema.",
                            "Brand color for buttons, icons and controls across the app. Independent from the system accent color."))
                Toggle(loc.t("Icono en la barra de menús", "Menu bar icon"), isOn: $menuBarIcon)
                    .infoTip(loc.t("Muestra un icono en la barra de menús con el estado del servidor y controles rápidos, aunque la ventana esté cerrada.",
                                "Shows a menu bar icon with server status and quick controls, even with the window closed."))
                Picker(loc.t("VRAM de la GPU en la barra", "GPU VRAM in the menu bar"), selection: $menuBarGPU) {
                    Text(loc.t("Oculta", "Hidden")).tag("off")
                    Text(loc.t("En el icono", "In the icon")).tag("icon")
                    Text(loc.t("En el panel", "In the panel")).tag("panel")
                }
                .disabled(!menuBarIcon)
                .infoTip(loc.t("Dónde mostrar el uso de VRAM: junto al icono (porcentaje agregado) o como barras por GPU al abrir el panel.",
                            "Where to show VRAM usage: next to the icon (aggregate percentage) or as per-GPU bars when the panel opens."))
                Toggle(loc.t("Iniciar servidor al abrir la app", "Start server on app launch"), isOn: $autoStart)
                    .infoTip(loc.t("Arranca automáticamente el último modelo configurado al abrir ToshLLM.",
                                "Automatically starts the last configured model when ToshLLM opens."))
                Toggle(loc.t("Buscar actualizaciones cada hora", "Check for updates hourly"), isOn: $updateAutoCheck)
                    .infoTip(loc.t("Además del chequeo al abrir la app, revisa en silencio cada hora mientras esté abierta y enciende el aviso de actualización si hay versión nueva. No descarga ni instala nada solo.",
                                "Besides the launch check, silently re-checks every hour while the app is open and lights the update badge when a new version exists. Never downloads or installs on its own."))
                Toggle(loc.t("Proteger la API con clave", "Protect the API with a key"), isOn: $apiKeyEnabled)
                    .infoTip(loc.t("Genera una clave (guardada en el Llavero) que el servidor exige a cada petición. El chat de la app la usa automáticamente; útil en Macs compartidas.",
                                "Generates a key (stored in the Keychain) required on every request. The in-app chat uses it automatically; useful on shared Macs."))
                Toggle(loc.t("Descubrible en red local", "Discoverable on local network"),
                       isOn: Binding(get: { localNetworkDiscovery }, set: setDiscoverable))
                    .infoTip(loc.t("Hace que el servidor escuche en la red local y lo anuncia con Bonjour como 'ToshLLM API'. Actívalo solo en redes confiables; reinicia el servidor si está activo.",
                                "Makes the server listen on the local network and advertises it with Bonjour as 'ToshLLM API'. Enable only on trusted networks; restarts the server if it's running."))
                if localNetworkDiscovery && !apiKeyEnabled {
                    Label(loc.t("Recomendado: activa 'Proteger la API con clave' antes de exponer el servidor en la red local.",
                                "Recommended: enable 'Protect the API with a key' before exposing the server on the local network."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
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
                            .accessibilityLabel(loc.t("Copiar la clave", "Copy the key"))
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

            SpeechModelsSettingsSection()

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
                        Button { profileStore.delete(p) } label: { Label(loc.t("Borrar", "Delete"), systemImage: "trash") }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .accessibilityLabel(loc.t("Eliminar el perfil", "Delete the profile"))
                            .infoTip(loc.t("Eliminar este perfil.", "Delete this profile."))
                    }
                }
            }

            Section(loc.t("GPU y memoria", "GPU & memory")) {
                Picker(loc.t("GPU (Metal)", "GPU (Metal)"), selection: $gpuIndex) {
                    Text(loc.t("Predeterminada", "Default")).tag(-1)
                    ForEach(hardware.gpus) { g in
                        Text("\(g.index): \(g.name) · \(g.vramGB) GB").tag(g.index)
                    }
                }
                .infoTip(loc.t("Qué GPU usa el servidor si tienes varias. 'Predeterminada' deja elegir a Metal.",
                            "Which GPU the server uses if you have several. 'Default' lets Metal choose."))
                .disabled(multiGPU)
                if hardware.gpus.count > 1 {
                    Toggle(loc.t("Repartir el modelo entre todas las GPUs (experimental)",
                                 "Split model across all GPUs (experimental)"), isOn: $multiGPU)
                        .onChange(of: multiGPU) { _, on in
                            if !on { gpuListCSV = "" }
                        }
                        .infoTip(loc.t("Reparte el modelo entre todas las GPUs detectadas (--split-mode) en vez de usar una sola, p. ej. para cargar un modelo que no cabe en una. Anula el selector de arriba.",
                                    "Splits the model across all detected GPUs (--split-mode) instead of using one, e.g. to load a model that doesn't fit on a single card. Overrides the picker above."))
                    if multiGPU && hardware.gpus.count > 2 && splitSelection.count < 2 {
                        Picker(loc.t("GPUs a usar", "GPUs to use"), selection: $multiGPUCount) {
                            Text(loc.t("Todas (\(hardware.gpus.count))", "All (\(hardware.gpus.count))")).tag(0)
                            ForEach(2...hardware.gpus.count, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .infoTip(loc.t("Cuántas GPUs repartir. Más GPUs = prompt más rápido; menos GPUs = generación más rápida (menos sincronización entre tarjetas).",
                                    "How many GPUs to split across. More GPUs = faster prompt; fewer GPUs = faster generation (less cross-card sync)."))
                    }
                    if multiGPU {
                        LabeledContent(loc.t("GPUs del reparto", "Split GPUs")) {
                            Menu {
                                Button(loc.t("Todas", "All")) { gpuListCSV = "" }
                                Divider()
                                ForEach(hardware.gpus) { g in
                                    Toggle("\(g.name) · \(g.vramGB) GB", isOn: Binding(
                                        get: { splitSelection.contains(g.index) },
                                        set: { _ in toggleSplitGPU(g.index) }))
                                }
                            } label: {
                                Text(splitSelection.count >= 2
                                        ? loc.t("\(splitSelection.count) elegidas", "\(splitSelection.count) selected")
                                        : loc.t("Todas", "All"))
                            }
                            .fixedSize()
                        }
                        .infoTip(loc.t("Qué GPUs concretas participan en el reparto (p. ej. la 0 y la 6, saltándose las demás). Con 'Todas' se usan las primeras N del selector de arriba.",
                                    "Which specific GPUs take part in the split (e.g. 0 and 6, skipping the rest). With 'All', the first N from the picker above are used."))
                        if splitSelection.count == 1 {
                            Label(loc.t("Elige al menos 2 GPUs para el reparto; con una sola se usan todas.",
                                        "Pick at least 2 GPUs for the split; with only one, all are used."),
                                  systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Label(loc.t("⚠️ Experimental y sin validar en GPU AMD/Metal: el reparto entre GPUs es una ruta distinta que podría dar salida incorrecta o colgar el motor. Verifica que la generación sea coherente y vigila la estabilidad. Necesita más pruebas.",
                                    "⚠️ Experimental and unvalidated on AMD/Metal: cross-GPU splitting is a different path that could produce wrong output or hang the engine. Check that generation is coherent and watch stability. Needs more testing."),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .labelStyle(.titleAndIcon)
                        Picker(loc.t("Cómo repartirlo", "How to split it"), selection: $splitMode) {
                            Text(loc.t("Por capas", "By layers")).tag("layer")
                            Text(loc.t("Por tensores", "By tensors")).tag("tensor")
                        }
                        .infoTip(loc.t("Por capas: cada GPU se queda unas capas enteras y trabajan por turnos. Es lo más rápido generando y lo más probado. Por tensores: las dos GPUs trabajan a la vez dentro de cada capa, así que leen el prompt mucho más rápido, pero se ponen de acuerdo en cada capa y esa espera cuesta lo mismo por token generado: en un modelo pequeño se come la ganancia, y en uno grande (decenas de GB) sale ganando en las dos cosas.",
                                    "By layers: each GPU keeps whole layers and they take turns. Fastest at generating, and the best tested. By tensors: both GPUs work at once inside every layer, so they read the prompt much faster, but they sync up on every layer and that wait costs the same on each generated token: on a small model it eats the gain, on a big one (tens of GB) it wins at both."))
                        Toggle(loc.t("Traspaso rápido entre GPUs",
                                     "Fast hand-off between GPUs"), isOn: $mgpuEvents)
                            .infoTip(loc.t("Pasa los datos de una GPU a otra sin vaciar las colas de las dos en cada copia. Repartiendo por capas no cambia nada; repartiendo por tensores es la mayor parte de la velocidad de generación (medido +59% en dos GPUs). Apágalo solo para diagnosticar.",
                                        "Hands data from one GPU to the other without draining both queues on every copy. It changes nothing when splitting by layers; when splitting by tensors it is most of the generation speed (measured +59% on two GPUs). Turn it off only to diagnose."))
                        Toggle(loc.t("Infinity Fabric Link entre GPUs (experimental)",
                                     "Infinity Fabric Link between GPUs (experimental)"), isOn: $mgpuPeer)
                            .disabled(!hasPeerLink)
                            .infoTip(loc.t("Si dos GPUs del reparto comparten un puente Infinity Fabric (las dos mitades de una W6800X Duo o Vega II Duo), copia las activaciones directamente entre ellas en vez de pasar por la RAM del sistema. Acelera el procesamiento del prompt. Repartiendo por tensores se usa solo donde gana, leyendo el prompt, y el traspaso rápido se queda con la generación. Si el equipo no lo soporta, la copia vuelve sola al método seguro.",
                                        "If two GPUs in the split share an Infinity Fabric bridge (the two halves of a W6800X Duo or Vega II Duo, or two cards joined by the external bridge), copies activations directly between them instead of through system RAM. Speeds up prompt processing. When splitting by tensors it is used only where it wins, reading the prompt, and the fast hand-off keeps generation. If the machine doesn't support it, the copy falls back to the safe path on its own."))
                        if !hasPeerLink {
                            Label(loc.t("No se detecta ningún puente entre estas GPUs, así que no hay nada que activar. Metal las pondría en un mismo grupo de pares si lo hubiera.",
                                        "No bridge is detected between these GPUs, so there is nothing to turn on. Metal would put them in the same peer group if there were one."),
                                  systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if mgpuPeer && splitMode != "tensor" {
                            Label(loc.t("Con reparto por capas no hace nada: el puente acelera la reducción que solo existe repartiendo por tensores.",
                                        "With a layer split it does nothing: the bridge speeds up the reduction that only exists when splitting by tensors."),
                                  systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.orange)
                        }
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
                        value: Binding(get: { ncmoe }, set: { v in
                            ncmoe = v
                            ServerSettings.rememberNcmoe(v, forModel: modelPath)
                        }), in: 0...99)
                    .infoTip(loc.t("Solo modelos MoE: capas cuyos 'expertos' viven en RAM y los procesa el CPU. Se ajusta solo al elegir modelo; súbelo si la VRAM se satura, bájalo si te sobra. (Deshabilitado en modelos densos, donde el motor lo ignora.)",
                                "MoE models only: layers whose 'experts' live in RAM and run on the CPU. Auto-set when picking a model; raise if VRAM saturates, lower if you have headroom. (Disabled on dense models, where the engine ignores it.)"))
                    .disabled(!modelIsMoE || dynamicMoeIsEffective)
                if engineSelection.wrappedValue != "custom" && dynamicMoeUIUnlocked {
                    Toggle(loc.t("Dynamic MoE (experimental)", "Dynamic MoE (experimental)"),
                           isOn: $dynamicMoe)
                        .disabled(!modelIsMoE)
                        .infoTip(loc.t("Mantiene todos los expertos cuantizados en RAM y una caché pequeña en VRAM. Está apagado por defecto. Al activarlo usa ncmoe 1, mlock y el override Metal requeridos; desactívalo para volver al camino normal con el mismo binario.",
                                    "Keeps all quantized experts in RAM and a small cache in VRAM. It is off by default. Enabling it applies ncmoe 1, mlock, and the required Metal override; turn it off to return to the normal path with the same binary."))
                    if dynamicMoe {
                        Picker(loc.t("Política", "Policy"), selection: $dynamicMoePolicy) {
                            Text(loc.t("Automática", "Automatic")).tag("auto")
                            Text(loc.t("Caché manual", "Manual cache")).tag("cache")
                        }
                        .infoTip(loc.t("Auto reutiliza el perfil medido por Optimizar dMoE. Puede elegir la ruta directa cuando el banco cabe o la ruta dividida para modelos grandes. Sin perfil usa una configuración conservadora; Caché manual permite experimentar.",
                                    "Auto reuses the profile measured by Optimize dMoE. It can choose the direct route when the bank fits or the split route for large models. Without a profile it uses a conservative configuration; Manual cache remains available for experiments."))
                        if dynamicMoePolicy == "auto" {
                            Label(dynamicMoeAutoMessage,
                                  systemImage: dynamicMoeAutoRoute == .cache ? "bolt.horizontal.fill" : "checkmark.shield")
                                .font(.caption)
                                .foregroundStyle(dynamicMoeAutoRoute == .cache ? .orange : .secondary)
                            if dynamicMoeAutoRoute == .cache, let plan = dynamicMoeSlotPlan {
                                Label(loc.t("Auto usa K\(plan.automaticSlots) de \(plan.maximumSlots) expertos por capa (top-\(plan.minimumSlots)); estimado \(gibLabel(plan.estimatedVRAMBytes(slots: plan.automaticSlots))) de VRAM.",
                                            "Auto uses K\(plan.automaticSlots) of \(plan.maximumSlots) experts per layer (top-\(plan.minimumSlots)); estimated \(gibLabel(plan.estimatedVRAMBytes(slots: plan.automaticSlots))) VRAM."),
                                      systemImage: "memorychip")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            if let info = dynamicMoeModelInfo {
                                HStack {
                                    Text(loc.t("Ranuras en VRAM (K, de \(info.expertCount))",
                                               "VRAM slots (K, of \(info.expertCount))"))
                                    Spacer()
                                    TextField("", value: dynamicMoeSlotBinding,
                                              format: .number.grouping(.never))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 64)
                                        .multilineTextAlignment(.trailing)
                                    Stepper("", value: dynamicMoeSlotBinding,
                                            in: info.activeExpertCount...info.expertCount)
                                        .labelsHidden()
                                }
                                    .infoTip(loc.t("K es por capa. El mínimo es el número de expertos activos por token (top-\(info.activeExpertCount)) y el máximo es el total real del GGUF (\(info.expertCount)).",
                                                        "K is per layer. The minimum is the experts active per token (top-\(info.activeExpertCount)); the maximum is the GGUF's real total (\(info.expertCount))."))
                                if let plan = dynamicMoeSlotPlan {
                                    let overBudget = effectiveDynamicMoeSlots > plan.recommendedMaximumSlots
                                    Label(loc.t("Estimación: \(gibLabel(plan.estimatedVRAMBytes(slots: effectiveDynamicMoeSlots))) · máximo recomendado K\(plan.recommendedMaximumSlots).",
                                                "Estimate: \(gibLabel(plan.estimatedVRAMBytes(slots: effectiveDynamicMoeSlots))) · recommended maximum K\(plan.recommendedMaximumSlots)."),
                                          systemImage: overBudget ? "exclamationmark.triangle.fill" : "memorychip")
                                        .font(.caption)
                                        .foregroundStyle(overBudget ? .orange : .secondary)
                                } else {
                                    Label(loc.t("La caché mínima top-\(info.activeExpertCount) supera el presupuesto estimado; el modo manual permite probarla, pero puede agotar la VRAM.",
                                                "The minimum top-\(info.activeExpertCount) cache exceeds the estimated budget; manual mode still allows testing it, but it may exhaust VRAM."),
                                          systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            } else {
                                Label(loc.t("Este GGUF no declara los metadatos necesarios para calcular K de forma segura.",
                                            "This GGUF does not declare the metadata needed to calculate K safely."),
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            Picker(loc.t("Prefetch de Dynamic MoE", "Dynamic MoE prefetch"),
                                   selection: $dynamicMoePrefetch) {
                                ForEach([0, 1, 2, 3, 4, 5, 6, 8, 12, 16], id: \.self) { value in
                                    Text("\(value)").tag(value)
                                }
                            }
                            .infoTip(loc.t("Número de bancos anticipados durante el prompt. Cuatro fue el óptimo medido para K8; los demás valores sirven para repetir el barrido desde Benchmarks.",
                                        "Number of banks prefetched during prompt processing. Four was the measured optimum for K8; the other values let you repeat the sweep from Benchmarks."))
                        }
                        Label(dynamicMoePolicy == "auto"
                                ? loc.t("Auto: perfil medido y adaptación continua", "Auto: measured profile with continuous adaptation")
                                : loc.t("Configuración efectiva: cache · mlock · NCB8",
                                        "Effective configuration: cache · mlock · NCB8"),
                              systemImage: "flask.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
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

                Picker(loc.t("Tope de tokens por imagen", "Image token cap"), selection: $imageMaxTokens) {
                    Text(loc.t("Del modelo", "Model's")).tag(0)
                    Text("4096").tag(4096)
                    Text("2048").tag(2048)
                    Text("1024").tag(1024)
                }
                .infoTip(loc.t("Cuántos tokens puede ocupar una imagen en los modelos con visión. Por defecto manda el modelo. La memoria del codificador de visión crece con el cuadrado de este número, así que bajarlo la recorta mucho, a costa de detalle: es lo que permite cargar un modelo con visión en tarjetas donde ese buffer no cabe.",
                            "How many tokens one image may take on vision models. The model decides by default. The vision encoder's memory grows with the square of this number, so lowering it cuts memory a lot at the cost of detail: it is what makes a vision model load on cards where that buffer does not fit."))
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
                Picker(loc.t("KV cache: claves (-ctk)", "KV cache: keys (-ctk)"), selection: $cacheTypeK) {
                    ForEach(availableKVTypes, id: \.self) { Text($0).tag($0) }
                }
                .infoTip(amdFlashActive
                    ? loc.t("Cuantización de las claves del KV cache. Con el kernel Flash Attention AMD, cualquier combinación estándar (f16/q8_0/q4_0 en claves y valores) corre en GPU a velocidad plena, incluida la ruta rápida de prompts largos. Para máximo ahorro de memoria: q8_0/q8_0 (mitad, recomendado) o q4_0/q4_0 (un cuarto); para comprimir solo las claves manteniendo los valores en precisión completa: q8_0/f16 o q4_0/f16.",
                            "Quantization for KV cache keys. With the AMD Flash Attention kernel, any standard combination (f16/q8_0/q4_0 for keys and values) runs on the GPU at full speed, including the fast long-prompt route. For maximum memory savings: q8_0/q8_0 (half, recommended) or q4_0/q4_0 (a quarter); to compress only the keys while keeping values at full precision: q8_0/f16 or q4_0/f16.")
                    : loc.t("Cuantización de las claves del KV cache. En GPU AMD (sin el kernel Flash Attention AMD): q8_0 reduce las claves a la mitad casi sin costo de velocidad (recomendado), dejando los valores en f16; q4_0 a un cuarto.",
                            "Quantization for KV cache keys. On AMD GPUs (without the AMD Flash Attention kernel): q8_0 halves key memory at almost no speed cost (recommended), keeping values at f16; q4_0 quarters it."))
                Picker(loc.t("KV cache: valores (-ctv)", "KV cache: values (-ctv)"), selection: $cacheTypeV) {
                    ForEach(availableKVTypes, id: \.self) { Text($0).tag($0) }
                }
                .infoTip(amdFlashActive
                    ? loc.t("Cuantización de los valores del KV cache. Con el kernel Flash Attention AMD cualquier valor estándar (f16/q8_0/q4_0) corre en GPU a velocidad plena, incluida la ruta rápida de prompts largos. Cuantizar los valores ahorra más memoria; dejarlos en f16 (con claves cuantizadas) conserva más calidad... ambos van igual de rápidos.",
                            "Quantization for KV cache values. With the AMD Flash Attention kernel any standard value type (f16/q8_0/q4_0) runs on the GPU at full speed, including the fast long-prompt route. Quantizing values saves more memory; keeping them at f16 (with quantized keys) preserves more quality... both run equally fast.")
                    : loc.t("Cuantización de los valores del KV cache. ⚠️ En GPU AMD (sin el kernel Flash Attention AMD) esto fuerza Flash Attention en CPU: la generación baja ~3× (de ~50 a ~15-19 t/s en un 8B). Úsalo solo cuando necesites contexto enorme; si no, déjalo en f16 y cuantiza solo las claves.",
                            "Quantization for KV cache values. ⚠️ On AMD GPUs (without the AMD Flash Attention kernel) this forces Flash Attention onto the CPU: generation drops ~3× (from ~50 to ~15-19 t/s on an 8B). Use only when you need huge context; otherwise keep f16 and quantize keys only."))
                if !turboKVIncompatible, let s = kvSuggestion, cacheTypeK != s.k || cacheTypeV != s.v {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(loc.t("Sugerencia medida: claves \(s.k), valores \(s.v)",
                                       "Measured suggestion: \(s.k) keys, \(s.v) values"))
                                .font(.callout.weight(.medium))
                            Text(loc.t("Calidad indistinguible de f16 y un 25% menos de caché que q8_0 en ambos.",
                                       "Quality indistinguishable from f16, and 25% less cache than q8_0 on both."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button(loc.t("Aplicar", "Apply")) { cacheTypeK = s.k; cacheTypeV = s.v }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(loc.t("Pone las claves en \(s.k) y los valores en \(s.v).",
                                        "Sets keys to \(s.k) and values to \(s.v)."))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .glassSurface(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if let reason = turboKVIncompatibleReason {
                    HStack(alignment: .center, spacing: 12) {
                        Label(loc.t(reason.es, reason.en),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        if let s = kvSuggestion {
                            Spacer(minLength: 8)
                            Button(loc.t("Usar \(s.k) / \(s.v)", "Use \(s.k) / \(s.v)")) {
                                cacheTypeK = s.k; cacheTypeV = s.v
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(loc.t("Cambia a una combinación válida y medida.",
                                        "Switches to a valid, measured combination."))
                        }
                    }
                } else if turboKVSelected {
                    Label(loc.t("Turbo en las claves es lo que cuesta calidad, y más cuanto menor es el modelo. Con las claves en q8_0, los valores admiten Turbo4 sin pérdida apreciable en ningún tamaño, y Turbo3 casi; Turbo en ambos conviene solo en modelos grandes.",
                                "Turbo on the keys is what costs quality, the more so the smaller the model. With keys at q8_0, values take Turbo4 with no appreciable loss at any size, and Turbo3 nearly so; Turbo on both is only worth it on large models."),
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(loc.t("Reuso de caché de prompt (rápido)", "Prompt cache reuse (fast)"), isOn: $cacheReuse)
                    .infoTip(loc.t("Cuando reescribes/editas el prompt (asistentes de código) o se recorta el razonamiento entre turnos, reutiliza la caché desplazándola en vez de reprocesar — mucho más rápido. Es una aproximación: la salida sigue coherente pero puede variar levemente frente a un cálculo exacto. Desactívalo si quieres resultados idénticos y reproducibles.",
                                "When the prompt is rewritten/edited (coding assistants) or the reasoning is trimmed between turns, it reuses the cache by shifting it instead of reprocessing — much faster. It's an approximation: output stays coherent but can differ slightly from an exact recompute. Turn it off for identical, reproducible results."))
                Stepper(loc.t("Hilos de CPU: \(threads)", "CPU threads: \(threads)"),
                        value: $threads, in: 1...max(1, hardware.logicalCores))
                    .infoTip(loc.t("Hilos para la parte que corre en CPU (expertos MoE, tokenización). Tu equipo tiene \(hardware.logicalCores) hilos; los núcleos físicos (\(hardware.physicalCores)) suelen ser el óptimo; más hilos no acelera si el límite es la RAM.",
                                "Threads for the CPU side (MoE experts, tokenization). Your machine has \(hardware.logicalCores) threads; physical cores (\(hardware.physicalCores)) are usually optimal; more threads won't help if RAM bandwidth is the limit."))
                    .onAppear { if threads > hardware.logicalCores { threads = max(1, hardware.logicalCores) } }
                Picker(loc.t("Flash Attention estándar (CPU)", "Standard Flash Attention (CPU)"), selection: $flashAttn) {
                    Text("auto").tag("auto"); Text("on").tag("on"); Text("off").tag("off")
                }
                .disabled(amdFlashActive || kvNeedsFlashAttention)
                .infoTip(loc.t("Ruta Flash Attention estándar de llama.cpp. En GPU AMD cae en CPU; se fuerza a 'on' cuando el KV está cuantizado. Para atención en GPU usa el kernel AMD de abajo.",
                            "Standard llama.cpp Flash Attention path. On AMD GPUs it falls back to CPU; it is forced to 'on' when KV is quantized. For GPU attention use the AMD kernel below."))
                if engineSelection.wrappedValue != "custom" {
                    Toggle(loc.t("Kernel Flash Attention AMD (GPU)", "AMD Flash Attention kernel (GPU)"), isOn: $faAmd)
                        .infoTip(loc.t("Kernel Metal propio, activo por defecto, que ejecuta la atención (prompt y generación) en la GPU AMD: cabezas estándar 64/72/128/256/512 y TurboQuant con padding 128/256/384/512/640. Si lo apagas, el KV cuantizado sigue requiriendo Flash Attention pero usa la ruta estándar en CPU.",
                                    "Custom Metal kernel, on by default, that runs attention (prompt and generation) on the AMD GPU: standard heads 64/72/128/256/512 and TurboQuant padded heads 128/256/384/512/640. If you turn it off, quantized KV still requires Flash Attention but uses the standard CPU path."))
                    Label(amdFlashActive
                            ? loc.t("Usando kernel AMD en GPU; Flash Attention queda forzado a 'on'.",
                                    "Using the AMD GPU kernel; Flash Attention is forced to 'on'.")
                            : kvNeedsFlashAttention
                              ? loc.t("El KV cuantizado requiere Flash Attention: con el kernel AMD apagado usa el FA estándar en CPU.",
                                      "Quantized KV requires Flash Attention: with the AMD kernel off, it uses standard FA on CPU.")
                              : loc.t("Flash Attention estándar corre en la CPU en GPU AMD; activa el kernel AMD para usar la GPU.",
                                      "Standard Flash Attention runs on CPU on AMD GPUs; enable the AMD kernel to use the GPU."),
                          systemImage: amdFlashActive ? "bolt.fill" : "cpu")
                        .font(.caption).foregroundStyle(amdFlashActive ? .green : .secondary)
                }
                if !modelPath.isEmpty && ServerSettings.modelUsesMTP(at: modelPath) {
                    Label(loc.t("MTP automático activo", "Automatic MTP active"),
                          systemImage: "hare.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .infoTip(loc.t("MTP se activa automáticamente cuando el GGUF trae el cabezal, tanto en modelos densos como MoE.",
                                    "MTP turns on automatically whenever the GGUF includes the head, for both dense and MoE models."))
                }
                if engineSelection.wrappedValue != "custom" {
                    Toggle(loc.t("Prefetch de expertos MoE (prompt)", "MoE expert prefetch (prompt)"), isOn: $prefetchExperts)
                        .infoTip(loc.t("Para modelos MoE con expertos en RAM (ncmoe > 0): sube los pesos de expertos a la GPU por una cola Metal paralela, solapando la subida con el cómputo. De 1.8× a 4.4× de velocidad de prompt medida (35B, gemma-4-26B, gpt-oss) sin costo de generación; el primer prompt tras cargar el modelo es algo más lento mientras se preparan los buffers.",
                                    "For MoE models with experts in RAM (ncmoe > 0): uploads expert weights to the GPU through a parallel Metal queue, overlapping the upload with compute. Measured 1.8×-4.4× prompt speed (35B, gemma-4-26B, gpt-oss) at no generation cost; the first prompt after loading the model is slightly slower while buffers warm up."))
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
            }

            Section(loc.t("Avanzado", "Advanced")) {
                TextField(loc.t("Puerto", "Port"), value: $port, format: .number.grouping(.never))
                    .infoTip(loc.t("Puerto local del servidor (API compatible con OpenAI y chat web).",
                                "Local server port (OpenAI-compatible API and web chat)."))
                Picker(loc.t("Motor de inferencia", "Inference engine"), selection: engineSelection) {
                    Text(loc.t("Integrado (oficial)", "Bundled (official)")).tag("bundled")
                    Text(loc.t("Externo…", "External…")).tag("custom")
                }
                .infoTip(loc.t("Integrado: llama.cpp oficial con los kernels Metal para AMD, recomendado. Externo: cualquier llama-server tuyo.",
                            "Bundled: official llama.cpp with the Metal kernels for AMD, recommended. External: any llama-server of yours."))
                if engineSelection.wrappedValue != "custom" {
                    Toggle(loc.t("Recordar conversaciones (caché en disco)", "Remember conversations (disk cache)"), isOn: $persistCache)
                        .disabled(!amdFlashActive)
                        .infoTip(loc.t("Guarda en disco la caché KV de cada conversación, así al reabrir un chat o reiniciar la app no se reprocesa el prompt (en un prompt largo ahorra varios segundos por turno). Requiere el kernel Flash Attention AMD activo; con KV cuantizado (q8_0/q4_0) el archivo es más pequeño y la restauración más rápida. Los archivos viven en Application Support y se borran al eliminar la conversación.",
                                    "Saves each conversation's KV cache to disk, so reopening a chat or restarting the app skips re-processing the prompt (saves several seconds per turn on long prompts). Requires the AMD Flash Attention kernel; with quantized KV (q8_0/q4_0) the file is smaller and restore is faster. Files live in Application Support and are removed when you delete the conversation."))
                    if currentModelIsVision {
                        Label(loc.t("Con la visión activada (ojo) se omite en silencio: llama.cpp no permite guardar/restaurar slots con mmproj cargado. Con el ojo desactivado funciona normal.",
                                    "Silently skipped while vision is on (the eye): llama.cpp cannot save/restore slots with mmproj loaded. With the eye off it works normally."),
                              systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !amdFlashActive {
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
                Toggle(loc.t("Servidor de embeddings (--embeddings)",
                             "Embeddings server (--embeddings)"), isOn: $embeddings)
                    .infoTip(loc.t("Sirve /v1/embeddings para clientes RAG (p. ej. Obsidian Copilot), que sin esto reciben un error 501. Ojo: llama-server dedica el proceso a embeddings, así que actívalo con un modelo de embeddings; para chatear a la vez, añade un segundo servidor en Inicio con esta opción.",
                                "Serves /v1/embeddings for RAG clients (e.g. Obsidian Copilot), which otherwise get a 501 error. Note: llama-server dedicates the process to embeddings, so enable it with an embedding model; to keep chatting, add a second server on Home with this option."))
                TextField(loc.t("Argumentos extra", "Extra arguments"), text: $extraArgs)
                    .font(.system(.caption, design: .monospaced))
                    .infoTip(loc.t("Argumentos adicionales de llama-server separados por espacios. Un token CLAVE=VALOR se aplica como variable de entorno. Para mostrar la configuración privada de Dynamic MoE escribe TOSH_MOE_UI=1. En tarjetas GCN/Vega con texto corrupto, GGML_METAL_WAVE64_SAFEMODE=1 fuerza la ruta segura.",
                                "Additional llama-server arguments, space-separated. A KEY=VALUE token is applied as an environment variable. To reveal the private Dynamic MoE settings, enter TOSH_MOE_UI=1. On GCN/Vega cards with corrupted text, GGML_METAL_WAVE64_SAFEMODE=1 forces the safe path."))
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
