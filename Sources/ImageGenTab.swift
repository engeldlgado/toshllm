import SwiftUI
import UniformTypeIdentifiers

// Image studio, laid out to share the main window's NavigationSplitView: the
// controls live in the sidebar (ImageControls) and the canvas in the detail
// (ImageCanvas), both driven by one shared ImageGenerator. Reusing the split
// keeps the window chrome fixed, so switching Chat/Images doesn't jump.

/// Sidebar column: prompt, settings and the generate action. Falls back to a
/// short hint when the engine or model isn't ready (the canvas shows the detail).
struct ImageControls: View {
    @ObservedObject var gen: ImageGenerator
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var server: ServerController

    @AppStorage(SettingsKeys.imagenPrompt) private var prompt = ""
    @AppStorage(SettingsKeys.imagenAspect) private var aspect = ImageAspect.square.rawValue
    @AppStorage(SettingsKeys.imagenBaseSize) private var baseSize = 1024
    @AppStorage(SettingsKeys.imagenSteps) private var steps = 8
    @AppStorage(SettingsKeys.imagenSeed) private var seed = -1
    @AppStorage(SettingsKeys.imagenFormat) private var format = ImageFormat.png.rawValue
    @AppStorage(SettingsKeys.imagenOffloadCPU) private var offloadCPU = false
    @AppStorage(SettingsKeys.imagenGPU) private var gpuIndex = 0
    @AppStorage(SettingsKeys.imagenModel) private var modelID = ""
    @AppStorage(SettingsKeys.imagenCustomModel) private var customModelPath = ""
    @AppStorage(SettingsKeys.imagenCustomVAE) private var customVAEPath = ""
    @AppStorage(SettingsKeys.imagenCustomCfg) private var customCfg = 7.0
    @AppStorage(SettingsKeys.imagenInitImage) private var initImagePath = ""
    @AppStorage(SettingsKeys.imagenStrength) private var strength = 0.6

    private var isCustom: Bool { modelID == ImageGenCatalog.customID }

    /// The selected model: a catalog entry, the user's own files, or the best pick.
    private var model: ImageGenModel {
        if isCustom {
            return ImageGenCatalog.custom(modelPath: customModelPath, vaePath: customVAEPath,
                                          steps: steps, cfg: customCfg)
        }
        return ImageGenCatalog.model(id: modelID)
            ?? ImageGenCatalog.recommended(for: hardware)
            ?? ImageGenCatalog.zImageTurbo
    }
    private var ready: Bool { ImageGenerator.engineInstalled && ImageGenerator.installed(model, in: models) }
    private var aspectValue: ImageAspect { ImageAspect(rawValue: aspect) ?? .square }
    private var formatValue: ImageFormat { ImageFormat(rawValue: format) ?? .png }

    /// VRAM of the GPU the run will use (the picked one, else the best detected).
    private var targetVRAM: Double {
        if gpuIndex < hardware.gpus.count { return Double(hardware.gpus[gpuIndex].vramMB) / 1024 }
        return hardware.vramGB
    }
    /// The GPU has enough VRAM to load this model at all.
    private var modelFitsGPU: Bool { targetVRAM >= model.minVRAMGB }
    private var baseSizes: [Int] {
        let sizes = ImageGenLimits.baseSizes(vramGB: targetVRAM, residentGB: model.residentGB)
        return sizes.isEmpty ? [512] : sizes
    }
    private var currentDimensions: (Int, Int) { aspectValue.dimensions(base: baseSize) }
    private var fitsVRAM: Bool {
        ImageGenLimits.fits(width: currentDimensions.0, height: currentDimensions.1,
                            vramGB: targetVRAM, residentGB: model.residentGB)
    }
    /// Fits, but close enough to the VRAM ceiling that a freeze or crash is possible.
    private var nearVRAMLimit: Bool {
        let px = currentDimensions.0 * currentDimensions.1
        return fitsVRAM && Double(px) >= 0.8 *
            Double(ImageGenLimits.maxPixels(vramGB: targetVRAM, residentGB: model.residentGB))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                experimentalBadge
                modelPicker
                if !isCustom && !modelFitsGPU {
                    // The picker already shows why; no run controls for a model
                    // this GPU can't load.
                    EmptyView()
                } else if ready {
                    if server.state == .running { serverBusyWarning }
                    Text(loc.t("Descripción", "Prompt")).font(.headline)
                    promptEditor
                    img2imgSection
                    settingsGrid
                    if !fitsVRAM { vramWarning }
                    else if nearVRAMLimit { nearLimitNote }
                    generateButton
                    dimensionsFootnote
                } else if !isCustom {
                    notReadyHint
                }
            }
            .padding(16)
        }
        .frame(minWidth: 260)
        // Keep the base size within what the target GPU can hold (a smaller card,
        // or a GPU switch, can drop the previously chosen size).
        .onAppear {
            if ImageGenCatalog.model(id: modelID) == nil { modelID = model.id }
            clampBaseSize()
        }
        .onChange(of: gpuIndex) { clampBaseSize() }
    }

    /// Model chooser: every catalog model, with a note on ones too big for this GPU.
    /// Switching resets the step count to the new model's tuned default.
    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(loc.t("Modelo", "Model")).font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $modelID) {
                ForEach(ImageGenCatalog.models) { m in
                    let fits = targetVRAM >= m.minVRAMGB
                    Text(fits ? m.name : "\(m.name) · \(Int(m.minVRAMGB)) GB+").tag(m.id)
                }
                Divider()
                Text(loc.t("Personalizado…", "Custom…")).tag(ImageGenCatalog.customID)
            }
            .labelsHidden()
            .onChange(of: modelID) {
                if !isCustom { steps = model.defaultSteps }
                clampBaseSize()
            }
            Text(model.detail(loc.isSpanish)).font(.caption2).foregroundStyle(.secondary)
            if isCustom { customSetup }
            if !isCustom && !modelFitsGPU {
                Label(loc.t("Necesita \(Int(model.minVRAMGB)) GB de VRAM; no corre en esta GPU.",
                            "Needs \(Int(model.minVRAMGB)) GB of VRAM; it won't run on this GPU."),
                      systemImage: "xmark.octagon.fill")
                    .font(.caption2).foregroundStyle(.red)
            }
        }
    }

    /// Custom model setup: point the app at a checkpoint (and optional VAE) the
    /// user downloaded themselves, plus the CFG their model expects.
    private var customSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            filePickRow(loc.t("Archivo del modelo", "Model file"), path: $customModelPath,
                        types: ["safetensors", "gguf", "ckpt"])
            filePickRow(loc.t("VAE (opcional)", "VAE (optional)"), path: $customVAEPath,
                        types: ["safetensors", "gguf"])
            HStack(spacing: 6) {
                Text("CFG").font(.callout)
                Spacer(minLength: 8)
                TextField("", value: $customCfg, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                    .help(loc.t("Guía. Modelos turbo ~1, normales ~7. Según la ficha del modelo.",
                                "Guidance. Turbo models ~1, normal ~7. Per the model's card."))
            }
            Text(loc.t("Formatos: .safetensors / .gguf. Ajusta pasos y CFG según tu modelo.",
                       "Formats: .safetensors / .gguf. Set steps and CFG to match your model."))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private func filePickRow(_ title: String, path: Binding<String>, types: [String]) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption)
            Spacer(minLength: 6)
            Button(path.wrappedValue.isEmpty
                   ? loc.t("Elegir…", "Choose…")
                   : (path.wrappedValue as NSString).lastPathComponent) {
                pickFile(types: types) { path.wrappedValue = $0 }
            }
            .font(.caption).lineLimit(1).truncationMode(.middle).frame(maxWidth: 150, alignment: .trailing)
            if !path.wrappedValue.isEmpty {
                Button { path.wrappedValue = "" } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
    }

    private func pickFile(types: [String], onPick: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { onPick(url.path) }
    }

    private func clampBaseSize() {
        if !baseSizes.contains(baseSize) { baseSize = baseSizes.max() ?? 512 }
    }

    private var experimentalBadge: some View {
        Text(loc.t("Experimental", "Experimental"))
            .font(.caption2.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(.orange)
    }

    /// The frame fits but sits near the VRAM ceiling; nudge the user to step down
    /// if the GPU freezes or the run crashes.
    private var nearLimitNote: some View {
        Label(loc.t("Cerca del límite de VRAM. Si hay tirones o un crash, baja el tamaño.",
                    "Near the VRAM limit. If it freezes or crashes, lower the size."),
              systemImage: "gauge.with.dots.needle.67percent")
            .font(.caption).foregroundStyle(.yellow)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    /// A square at a large base can exceed VRAM even when the engine is ready.
    private var vramWarning: some View {
        Label(loc.t("Ese tamaño no cabe en la VRAM de esta GPU. Usa un formato no cuadrado o un tamaño menor.",
                    "That size does not fit this GPU's VRAM. Use a non-square ratio or a smaller size."),
              systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.orange)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var notReadyHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title).foregroundStyle(.tertiary)
            Text(loc.t("Instala el modelo para empezar",
                       "Install the model to get started")).font(.headline)
            Text(loc.t("Sigue los pasos en el panel de la derecha.",
                       "Follow the steps in the panel on the right."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Two Metal contexts at once can hang an AMD GPU, so warn while the chat
    /// engine holds it and offer to free it before generating.
    private var serverBusyWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(loc.t("Un modelo de chat usa la GPU", "A chat model is using the GPU"),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium)).foregroundStyle(.orange)
            Text(loc.t("Generar mientras el chat ocupa la GPU puede colgar la tarjeta en Macs AMD.",
                       "Generating while chat holds the GPU can hang the card on AMD Macs."))
                .font(.caption).foregroundStyle(.secondary)
            Button { server.stop() } label: {
                Label(loc.t("Detener el chat", "Stop chat"), systemImage: "stop.circle")
            }
            .controlSize(.small)
            .help(loc.t("Libera la GPU deteniendo el servidor de chat.",
                        "Frees the GPU by stopping the chat server."))
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    /// img2img: optionally seed generation from an existing image. Strength shows
    /// only once an image is chosen (how much to transform it).
    private var img2imgSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            filePickRow(loc.t("Imagen inicial (img2img)", "Init image (img2img)"),
                        path: $initImagePath, types: ["png", "jpg", "jpeg", "webp"])
            if !initImagePath.isEmpty {
                HStack(spacing: 6) {
                    Text(loc.t("Intensidad", "Strength")).font(.caption)
                    Slider(value: $strength, in: 0.1...1.0)
                    Text(String(format: "%.2f", strength))
                        .font(.system(size: 11, design: .monospaced)).frame(width: 34)
                }
                .help(loc.t("Cuánto cambia la imagen inicial. Bajo = se parece más; alto = la reinventa.",
                            "How much the init image changes. Low = closer to it; high = reinvents it."))
            }
        }
    }

    private var promptEditor: some View {
        TextEditor(text: $prompt)
            .font(.body).frame(minHeight: 110)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text(loc.t("Un zorro fotorrealista en un bosque nevado al atardecer…",
                               "A photorealistic fox in a snowy forest at golden hour…"))
                        .font(.body).foregroundStyle(.tertiary)
                        .padding(.horizontal, 13).padding(.vertical, 16).allowsHitTesting(false)
                }
            }
    }

    private var settingsGrid: some View {
        VStack(spacing: 12) {
            row(loc.t("Proporción", "Aspect ratio"),
                loc.t("Marco de la imagen. Se ajusta a múltiplos de 64 px.",
                      "Image framing. Snapped to multiples of 64 px.")) {
                Picker("", selection: $aspect) {
                    ForEach(ImageAspect.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }.labelsHidden().frame(width: 96)
            }
            row(loc.t("Tamaño base", "Base size"),
                loc.t("Lado largo en píxeles. El máximo se ajusta a la VRAM de la GPU.",
                      "Long edge in pixels. The maximum adapts to the GPU's VRAM.")) {
                Picker("", selection: $baseSize) {
                    ForEach(baseSizes, id: \.self) { Text("\($0) px").tag($0) }
                }.labelsHidden().frame(width: 96)
            }
            if !hardware.gpus.isEmpty {
                row("GPU",
                    loc.t("GPU que hará la generación.", "GPU that runs the generation.")) {
                    if hardware.gpus.count > 1 {
                        Picker("", selection: $gpuIndex) {
                            ForEach(Array(hardware.gpus.enumerated()), id: \.offset) { i, g in
                                Text(g.name).tag(i)
                            }
                        }.labelsHidden().frame(width: 140)
                    } else {
                        // A single GPU: show which one, without a redundant picker.
                        Text(hardware.gpus[0].name)
                            .font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail).frame(width: 140, alignment: .trailing)
                    }
                }
            }
            row(loc.t("Pasos", "Steps"),
                loc.t("Iteraciones de muestreo. Z-Image Turbo está afinado para 8.",
                      "Sampling iterations. Z-Image Turbo is tuned for 8.")) {
                Stepper(value: $steps, in: 4...30) { Text("\(steps)").monospacedDigit() }.frame(width: 96)
            }
            row(loc.t("Semilla", "Seed"),
                loc.t("-1 = aleatoria. Fija un número para reproducir la misma imagen.",
                      "-1 = random. Set a number to reproduce the same image.")) {
                TextField("", value: $seed, format: .number).textFieldStyle(.roundedBorder).frame(width: 96)
            }
            row(loc.t("Formato", "Format"),
                loc.t("JPG pesa mucho menos; PNG es sin pérdida.",
                      "JPG is far lighter; PNG is lossless.")) {
                Picker("", selection: $format) {
                    ForEach(ImageFormat.allCases) { Text($0.rawValue.uppercased()).tag($0.rawValue) }
                }.labelsHidden().frame(width: 96)
            }
            row(loc.t("VAE en CPU", "VAE on CPU"),
                loc.t("Descarga a CPU para ahorrar VRAM. Más lento; solo si falta memoria.",
                      "Offload to CPU to save VRAM. Slower; only if memory is tight.")) {
                Toggle("", isOn: $offloadCPU).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    @ViewBuilder private var generateButton: some View {
        if gen.isBusy {
            Button(role: .cancel) { gen.cancel() } label: {
                Label(loc.t("Cancelar", "Cancel"), systemImage: "stop.circle").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .help(loc.t("Detiene la generación en curso.", "Stops the current run."))
        } else {
            Button {
                let (w, h) = currentDimensions
                gen.generate(model: model, models: models, prompt: prompt,
                             width: w, height: h, steps: steps,
                             seed: seed, format: formatValue, offloadToCPU: offloadCPU,
                             gpuIndex: gpuIndex, initImagePath: initImagePath, strength: strength)
            } label: {
                Label(loc.t("Generar", "Generate"), systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || !fitsVRAM)
            .help(loc.t("Genera una imagen a partir de la descripción.",
                        "Generate an image from the prompt."))
        }
    }

    private var dimensionsFootnote: some View {
        let (w, h) = aspectValue.dimensions(base: baseSize)
        return Text("\(w) × \(h) px")
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }

    private func row<Content: View>(_ title: String, _ help: String,
                                    @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.callout)
            Spacer(minLength: 8)
            content().help(help)
        }
    }
}

/// Detail column: the live canvas plus the engine/model install gates.
struct ImageCanvas: View {
    @ObservedObject var gen: ImageGenerator
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var models: ModelStore

    private var isCustom: Bool {
        UserDefaults.standard.string(forKey: SettingsKeys.imagenModel) == ImageGenCatalog.customID
    }
    private var model: ImageGenModel {
        ImageGenCatalog.model(id: UserDefaults.standard.string(forKey: SettingsKeys.imagenModel) ?? "")
            ?? ImageGenCatalog.recommended(for: hardware)
            ?? ImageGenCatalog.zImageTurbo
    }
    private var recommended: Bool { ImageGenCatalog.recommended(for: hardware)?.id == model.id }
    private var formatValue: ImageFormat {
        ImageFormat(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.imagenFormat) ?? "png") ?? .png
    }

    var body: some View {
        Group {
            if !ImageGenerator.engineInstalled {
                centered { engineMissingCard }
            } else if !isCustom && !ImageGenerator.installed(model, in: models) {
                // Custom models are set up with file pickers in the sidebar, not downloaded.
                centered { modelInstallCard }
            } else if let img = gen.resultImage, !gen.isBusy {
                resultCanvas(img)
            } else if gen.isBusy {
                progressCanvas
            } else {
                idleCanvas
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var idleCanvas: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 46)).foregroundStyle(.tertiary)
            Text(loc.t("Escribe una descripción y pulsa Generar",
                       "Type a prompt and press Generate")).foregroundStyle(.secondary)
            if case .failed(let msg) = gen.state, !msg.isEmpty {
                Label(failureMessage(msg), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).frame(maxWidth: 380)
            }
        }
    }

    private var progressCanvas: some View {
        VStack(spacing: 18) {
            ProgressView(value: gen.progress > 0 ? gen.progress : nil)
                .progressViewStyle(.linear).frame(width: 260)
            Text(stageLabel).font(.headline)
            HStack(spacing: 14) {
                Label("\(gen.elapsed)s", systemImage: "clock")
                if let eta = gen.etaSeconds {
                    Label(loc.t("~\(eta)s restantes", "~\(eta)s left"), systemImage: "hourglass")
                }
            }
            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private var stageLabel: String {
        switch gen.stage {
        case .loading:  return loc.t("Cargando modelos…", "Loading models…")
        case .sampling: return loc.t("Generando · paso \(gen.stepText)", "Sampling · step \(gen.stepText)")
        case .decoding: return loc.t("Decodificando imagen…", "Decoding image…")
        }
    }

    private func resultCanvas(_ img: NSImage) -> some View {
        VStack(spacing: 12) {
            Image(nsImage: img)
                .resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            HStack(spacing: 14) {
                if gen.lastDuration > 0 {
                    Label(loc.t("Generado en \(gen.lastDuration)s", "Generated in \(gen.lastDuration)s"),
                          systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
                }
                Spacer()
                Button { if let url = gen.resultURL { saveAs(url) } } label: {
                    Label(loc.t("Guardar como…", "Save as…"), systemImage: "square.and.arrow.down")
                }
                .help(loc.t("Guarda una copia donde elijas.", "Save a copy wherever you choose."))
                if let url = gen.resultURL {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        Label(loc.t("Mostrar en Finder", "Reveal in Finder"), systemImage: "folder")
                    }
                    .help(loc.t("Abre el archivo en el Finder.", "Reveal the file in Finder."))
                }
            }
        }
    }

    /// Turn the engine's failure sentinel into a bilingual, actionable message.
    private func failureMessage(_ raw: String) -> String {
        switch raw {
        case "OOM":
            return loc.t("No hay VRAM suficiente para ese tamaño. Usa un formato no cuadrado o un tamaño menor.",
                         "Not enough VRAM for that size. Use a non-square ratio or a smaller size.")
        case "TIMEOUT":
            return loc.t("La GPU agotó el tiempo: la imagen es muy grande. Reduce el tamaño base.",
                         "The GPU timed out: the image is too large. Lower the base size.")
        default:
            return loc.t("La generación falló (\(raw)).", "Generation failed (\(raw)).")
        }
    }

    // MARK: - Gates

    private var engineMissingCard: some View {
        cardStack {
            Label(loc.t("Motor de imagen no incluido en esta build",
                        "Image engine not in this build"), systemImage: "exclamationmark.triangle")
                .font(.headline).foregroundStyle(.orange)
            Text(loc.t("Compila los motores (`./scripts/build-engines.sh`) para incluir la generación de imágenes.",
                       "Build the engines (`./scripts/build-engines.sh`) to include image generation."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var modelInstallCard: some View {
        cardStack {
            HStack(spacing: 8) {
                Text(model.name).font(.title3.bold())
                if recommended {
                    Text(loc.t("Recomendado", "Recommended"))
                        .font(.caption2.bold())
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.tint.opacity(0.18), in: Capsule())
                }
                Spacer()
                Text(String(format: "%.1f GB", model.totalGB))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text(model.detail(loc.isSpanish)).font(.callout).foregroundStyle(.secondary)
            Divider()
            ForEach(model.components) { componentRow($0) }
            if !modelFitsGPU {
                Label(loc.t("Necesita \(Int(model.minVRAMGB)) GB de VRAM; no corre en esta GPU.",
                            "Needs \(Int(model.minVRAMGB)) GB of VRAM; it won't run on this GPU."),
                      systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            Button {
                for comp in model.components {
                    models.downloadImageComponent(urlString: comp.urlString, fileName: comp.fileName)
                }
            } label: {
                Label(loc.t("Descargar todo", "Download all"), systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!modelFitsGPU)   // don't let the user fetch GBs for a model that can't run
            .help(loc.t("Descarga los componentes del modelo.", "Download the model's components."))
        }
        .frame(maxWidth: 460)
    }

    /// The detected GPU can load this model.
    private var modelFitsGPU: Bool { hardware.vramGB >= model.minVRAMGB }

    private func componentRow(_ comp: ImageGenComponent) -> some View {
        let present = FileManager.default.fileExists(
            atPath: comp.path(in: models.imagenDirectory).path)
        return HStack(spacing: 10) {
            Image(systemName: present ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(present ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(comp.label(loc.isSpanish)).font(.callout)
                Text(comp.fileName).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let item = models.imageDownload(fileName: comp.fileName) {
                InlineDownloadProgress(item: item)
            } else if !present {
                Text(String(format: "%.1f GB", comp.sizeGB))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func cardStack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { content() }.frame(maxWidth: 560)
    }

    private func saveAs(_ source: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "toshllm.\(formatValue.ext)"
        panel.allowedContentTypes = [formatValue == .jpg ? .jpeg : .png]
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: source, to: dest)
        }
    }
}
