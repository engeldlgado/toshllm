import SwiftUI
import UniformTypeIdentifiers
import ImageIO

// Image studio, laid out to share the main window's NavigationSplitView: the
// controls live in the sidebar (ImageControls) and the canvas in the detail
// (ImageCanvas). Every generation slot is an accordion with its own full
// configuration (model, prompt, size, GPU, seed…); one shared ImageGenPool
// drives all of them so both halves see the same runs.

/// Sidebar column: one accordion per instance plus the add/generate actions.
struct ImageControls: View {
    @ObservedObject var pool: ImageGenPool
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var server: ServerController

    /// Collapsed accordions (default: expanded).
    @State private var collapsed: Set<UUID> = []
    @AppStorage(SettingsKeys.imagenCleanupOnClose) private var cleanupOnClose = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                experimentalBadge
                if server.state == .running && serverGPUOverlap { serverBusyWarning }
                ForEach($pool.configs) { $cfg in
                    instanceAccordion($cfg)
                }
                Button { pool.add() } label: {
                    Label(loc.t("Añadir instancia", "Add instance"), systemImage: "plus.circle")
                }
                .buttonStyle(.borderless).controlSize(.small)
                .disabled(pool.anyBusy)
                .help(loc.t("Añade otra generación en paralelo con su propia configuración (modelo, GPU, semilla…). Generar lanza todas a la vez.",
                            "Adds another parallel run with its own configuration (model, GPU, seed…). Generate launches them all at once."))
                if duplicatedGPU {
                    Label(loc.t("Dos instancias comparten GPU: en Macs AMD puede colgar la tarjeta.",
                                "Two instances share a GPU: on AMD Macs this can hang the card."),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                }
                generateButton
                Divider().padding(.vertical, 2)
                Toggle(isOn: $cleanupOnClose) {
                    Text(loc.t("Borrar imágenes al cerrar la app", "Delete images on app close"))
                        .font(.caption)
                }
                .toggleStyle(.switch).controlSize(.mini)
                .help(loc.t("Al salir de la app borra las imágenes generadas (toshllm_*) de la carpeta de salida, para no acumular cientos con los nombres por fecha.",
                            "On quitting the app, deletes the generated images (toshllm_*) from the output folder, so the date-named files don't pile up."))
            }
            .padding(16)
        }
        .frame(minWidth: 260)
    }

    private var experimentalBadge: some View {
        Text(loc.t("Experimental", "Experimental"))
            .font(.caption2.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(.orange)
    }

    /// Two Metal contexts at once can hang an AMD GPU, so warn while the chat
    /// engine holds a GPU that an image instance could also land on, and offer
    /// to free it before generating.
    private var serverBusyWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(loc.t("El chat comparte GPU con una instancia", "Chat shares a GPU with an instance"),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium)).foregroundStyle(.orange)
            Text(loc.t("Generar mientras el chat usa la misma GPU puede colgar la tarjeta en Macs AMD.",
                       "Generating while chat uses the same GPU can hang the card on AMD Macs."))
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

    /// True when the chat server's GPU could be the same card as an instance's:
    /// multi-GPU split, "system default" (unknown card), a matching index, or a
    /// single-GPU Mac. Chat pinned to a card no instance uses is the safe combo.
    private var serverGPUOverlap: Bool {
        guard !ServerSettings.isAppleSilicon else { return false }
        guard hardware.gpus.count > 1 else { return true }
        let s = server.effectiveSettings()
        if s.multiGPU || s.gpuIndex < 0 { return true }
        return pool.configs.contains {
            $0.gpuIndex == s.gpuIndex || $0.auxGPU(gpuCount: hardware.gpus.count) == s.gpuIndex
        }
    }

    /// Two runs on one GPU is the risky case on AMD Macs (same reason as the
    /// chat-server warning); flag it instead of blocking it. A split instance
    /// claims its encoder/VAE GPU too.
    private var duplicatedGPU: Bool {
        guard pool.configs.count > 1, !ServerSettings.isAppleSilicon else { return false }
        let all = pool.configs.flatMap { c -> [Int] in
            var g = [c.gpuIndex]
            if let aux = c.auxGPU(gpuCount: hardware.gpus.count) { g.append(aux) }
            return g
        }
        return Set(all).count < all.count
    }

    private func instanceAccordion(_ cfg: Binding<ImageInstanceConfig>) -> some View {
        let c = cfg.wrappedValue
        let n = (pool.configs.firstIndex { $0.id == c.id } ?? 0) + 1
        let model = c.resolvedModel(for: hardware)
        let gen = pool.generator(for: c.id)
        let expanded = Binding(get: { !collapsed.contains(c.id) },
                               set: { if $0 { collapsed.remove(c.id) } else { collapsed.insert(c.id) } })
        return DisclosureGroup(isExpanded: expanded) {
            ImageInstanceForm(cfg: cfg,
                              isPrimary: pool.configs.first?.id == c.id,
                              canRemove: pool.configs.count > 1,
                              busy: pool.anyBusy,
                              onRemove: { collapsed.remove(c.id); pool.remove(c.id) })
                .padding(.top, 10)
        } label: {
            HStack(spacing: 6) {
                Text(loc.t("Instancia \(n)", "Instance \(n)")).font(.callout.weight(.medium))
                Text(model.name).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if hardware.gpus.count > 1, c.gpuIndex < hardware.gpus.count {
                    Text(hardware.gpus[c.gpuIndex].name)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if gen.isBusy { ProgressView().controlSize(.mini) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    /// An instance can run: model installed, an (own or inherited) prompt, and
    /// a frame that fits its GPU(s).
    private func runnable(_ c: ImageInstanceConfig) -> Bool {
        let model = c.resolvedModel(for: hardware)
        let v = ImageControls.vram(of: c.gpuIndex)
        let aux = c.auxGPU(gpuCount: hardware.gpus.count)
        let (w, h) = c.dimensions
        return ImageGenerator.installed(model, in: models)
            && !pool.effectivePrompt(for: c).isEmpty
            && model.fitsGPU(mainVRAM: v, auxVRAM: aux.map { ImageControls.vram(of: $0) })
            && ImageGenLimits.fits(width: w, height: h, vramGB: v,
                                   residentGB: model.residentGB, attnVRAMSq: model.attnVRAMSq)
    }

    /// VRAM of a specific GPU slot, for per-instance fit checks.
    static func vram(of index: Int) -> Double {
        index >= 0 && index < hardware.gpus.count
            ? Double(hardware.gpus[index].vramMB) / 1024 : hardware.vramGB
    }

    @ViewBuilder private var generateButton: some View {
        if pool.anyBusy {
            Button(role: .cancel) { pool.cancelAll() } label: {
                Label(loc.t("Cancelar", "Cancel"), systemImage: "stop.circle").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .help(loc.t("Detiene las generaciones en curso.", "Stops the current runs."))
        } else {
            Button {
                for c in pool.configs where runnable(c) {
                    let (w, h) = c.dimensions
                    pool.generator(for: c.id).generate(
                        model: c.resolvedModel(for: hardware), models: models,
                        prompt: pool.effectivePrompt(for: c),
                        width: w, height: h, steps: c.steps,
                        seed: c.seed, format: c.formatValue, offloadToCPU: c.offloadCPU,
                        gpuIndex: c.gpuIndex,
                        auxGPUIndex: c.auxGPU(gpuCount: hardware.gpus.count) ?? -1,
                        initImagePath: c.initImagePath, strength: c.strength)
                }
            } label: {
                Label(loc.t("Generar", "Generate"), systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!pool.configs.contains { runnable($0) })
            .help(loc.t("Genera una imagen por instancia lista (modelo instalado y descripción escrita).",
                        "Generates one image per ready instance (model installed and prompt written)."))
        }
    }
}

enum ImageDetailTab { case instances, queue }

/// Queue tab: a composer (prompt + seed) over a live feed that accumulates pending,
/// in-progress and finished renders so nothing is lost when instances move on.
struct QueueFeedView: View {
    @ObservedObject var pool: ImageGenPool
    @EnvironmentObject var loc: Localizer
    @State private var draft = ""
    @State private var draftSeed = -1
    /// nil = any free instance (default).
    @State private var draftTarget: UUID? = nil
    @AppStorage(SettingsKeys.imagenQueueGrid) private var grid = false

    var body: some View {
        VStack(spacing: 12) {
            composer
            Divider()
            if pool.queue.isEmpty && pool.gallery.isEmpty && !pool.anyBusy {
                emptyState
            } else {
                if !pool.gallery.isEmpty {
                    HStack {
                        Spacer()
                        FeedLayoutPicker(grid: $grid)
                    }
                }
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(pool.queue) { pendingRow($0) }
                        ForEach(pool.configs) { c in
                            let gen = pool.generator(for: c.id)
                            if gen.isBusy { progressRow(gen, instanceLabel: pool.instanceLabel(for: c.id)) }
                        }
                        if grid {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 460), spacing: 10)],
                                      alignment: .leading, spacing: 10) {
                                ForEach(pool.gallery) { resultCard($0) }
                            }
                        } else {
                            ForEach(pool.gallery) { resultRow($0) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// Prompt on top, then one row with the send options (target instance and
    /// seed) and Add, then the queue controls. Keeps related controls together
    /// instead of scattering them around the field.
    private var composer: some View {
        VStack(spacing: 8) {
            TextField(loc.t("Prompt para la cola…", "Prompt for the queue…"), text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...6).onSubmit(add)
            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    Text(loc.t("Destino", "Target")).font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $draftTarget) {
                        Text(loc.t("Cualquiera", "Any")).tag(nil as UUID?)
                        ForEach(pool.configs) { c in
                            Text(pool.instanceLabel(for: c.id) ?? "").tag(c.id as UUID?)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .help(loc.t("Instancia que debe generar este prompt. \"Cualquiera\" toma la siguiente libre; si eliges una y está ocupada, el prompt espera por ella sin bloquear a los demás.",
                                "Instance that must render this prompt. \"Any\" takes the next free one; if you pick one and it's busy, this prompt waits for it without blocking the others."))
                    .onChange(of: pool.configs.map(\.id)) {
                        if let t = draftTarget, !pool.configs.contains(where: { $0.id == t }) { draftTarget = nil }
                    }
                }
                HStack(spacing: 4) {
                    Text(loc.t("Semilla", "Seed")).font(.caption).foregroundStyle(.secondary)
                    TextField("-1", value: $draftSeed, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 68)
                }
                Spacer()
                Button(action: add) { Label(loc.t("Añadir", "Add"), systemImage: "plus") }
                    .buttonStyle(.bordered)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !pool.queue.isEmpty || pool.queueActive {
                HStack {
                    if !pool.queue.isEmpty {
                        Text(loc.t("\(pool.queue.count) en cola", "\(pool.queue.count) queued"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: toggle) {
                        Label(pool.queueActive ? loc.t("Detener", "Stop") : loc.t("Procesar cola", "Process queue"),
                              systemImage: pool.queueActive ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(!pool.queueActive && pool.queue.isEmpty)
                }
            }
        }
        .help(loc.t("Cada prompt (con su semilla) lo genera la siguiente instancia libre, una generación por GPU. Los resultados se acumulan abajo con nombre único.",
                    "Each prompt (with its seed) is rendered by the next free instance, one run per GPU. Results accumulate below, each with a unique name."))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(loc.t("Añade prompts a la cola y pulsa Procesar. Cada resultado aparece aquí.",
                       "Add prompts to the queue and press Process. Each result shows up here."))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pendingRow(_ q: QueuedPrompt) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(q.text).font(.callout).lineLimit(2)
                if q.seed >= 0 {
                    Text("#\(q.seed)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            // A removed target falls back to "any", so only badge it while it still exists.
            if let target = q.targetInstanceID, let label = pool.instanceLabel(for: target) {
                instanceBadge(label)
            }
            Text(loc.t("En cola", "Queued")).font(.caption).foregroundStyle(.secondary)
            Button { pool.removeFromQueue(q.id) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(12).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
    }

    private func progressRow(_ gen: ImageGenerator, instanceLabel: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(gen.lastPrompt.isEmpty ? loc.t("Generando…", "Generating…") : gen.lastPrompt)
                        .font(.callout).lineLimit(2)
                    if let instanceLabel { instanceBadge(instanceLabel) }
                }
                HStack(spacing: 8) {
                    if gen.lastSeed >= 0 {
                        Text("#\(gen.lastSeed)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    Text("\(gen.elapsed)s").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    if let eta = gen.etaSeconds {
                        Text(loc.t("~\(eta)s", "~\(eta)s")).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: gen.progress > 0 ? gen.progress : nil)
                    .progressViewStyle(.linear).frame(maxWidth: 240)
            }
            Spacer()
        }
        .padding(12).background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private func resultRow(_ g: GeneratedImage) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: g.image).resizable().scaledToFit()
                .containerRelativeFrame(.horizontal) { w, _ in min(w * 0.55, 460) }
                .frame(maxHeight: 520)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(g.prompt.isEmpty ? loc.t("(sin prompt)", "(no prompt)") : g.prompt)
                        .font(.callout).lineLimit(3)
                    if let label = g.instanceLabel { instanceBadge(label) }
                }
                Text("\(g.width)×\(g.height) · \(g.duration)s" + (g.seed >= 0 ? " · #\(g.seed)" : ""))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button { save(g) } label: { Label(loc.t("Guardar…", "Save…"), systemImage: "square.and.arrow.down") }
                        .help(loc.t("Guarda una copia donde elijas.", "Save a copy wherever you choose."))
                    Button { NSWorkspace.shared.activateFileViewerSelecting([g.url]) } label: {
                        Label(loc.t("Finder", "Finder"), systemImage: "folder")
                    }
                    .help(loc.t("Abre el archivo en el Finder.", "Reveal the file in Finder."))
                }
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(12).background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Grid tile: image on top, prompt excerpt and metadata below. Hovering the
    /// prompt shows the full text.
    private func resultCard(_ g: GeneratedImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(nsImage: g.image).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(g.prompt.isEmpty ? loc.t("(sin prompt)", "(no prompt)") : g.prompt)
                .font(.caption).lineLimit(2)
                .help(g.prompt)
            HStack(spacing: 6) {
                Text("\(g.width)×\(g.height) · \(g.duration)s" + (g.seed >= 0 ? " · #\(g.seed)" : ""))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let label = g.instanceLabel { instanceBadge(label) }
            }
            HStack(spacing: 10) {
                Button { save(g) } label: { Label(loc.t("Guardar…", "Save…"), systemImage: "square.and.arrow.down") }
                    .help(loc.t("Guarda una copia donde elijas.", "Save a copy wherever you choose."))
                Button { NSWorkspace.shared.activateFileViewerSelecting([g.url]) } label: {
                    Label(loc.t("Finder", "Finder"), systemImage: "folder")
                }
                .help(loc.t("Abre el archivo en el Finder.", "Reveal the file in Finder."))
            }
            .controlSize(.small)
        }
        .padding(10).background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }

    private func add() {
        pool.enqueue(draft, seed: draftSeed, targetInstanceID: draftTarget)
        draft = ""
    }

    /// Subtle capsule tag naming an instance, matching the experimental badge style.
    private func instanceBadge(_ label: String) -> some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }

    private func toggle() {
        pool.queueActive ? pool.stopQueue() : pool.startQueue()
    }
    private func save(_ g: GeneratedImage) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = g.url.lastPathComponent
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: g.url, to: dest)
        }
    }
}

/// Segmented list/grid switch shared by the queue feed and the instances canvas.
struct FeedLayoutPicker: View {
    @Binding var grid: Bool
    @EnvironmentObject var loc: Localizer

    var body: some View {
        Picker("", selection: $grid) {
            Label(loc.t("Lista", "List"), systemImage: "list.bullet").tag(false)
            Label(loc.t("Cuadrícula", "Grid"), systemImage: "square.grid.2x2").tag(true)
        }
        .pickerStyle(.segmented).labelsHidden().labelStyle(.iconOnly).fixedSize()
        .help(loc.t("Resultados en lista o en cuadrícula.", "Results as a list or a grid."))
    }
}

/// Full configuration form of one instance: model (with inline install), prompt,
/// img2img, size, GPU, steps, seed, format and offload.
struct ImageInstanceForm: View {
    @Binding var cfg: ImageInstanceConfig
    let isPrimary: Bool
    let canRemove: Bool
    let busy: Bool
    let onRemove: () -> Void

    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var models: ModelStore

    private var model: ImageGenModel { cfg.resolvedModel(for: hardware) }
    private var installed: Bool { ImageGenerator.installed(model, in: models) }
    private var targetVRAM: Double { ImageControls.vram(of: cfg.gpuIndex) }
    private var auxGPU: Int? { cfg.auxGPU(gpuCount: hardware.gpus.count) }
    private var modelFitsGPU: Bool {
        model.fitsGPU(mainVRAM: targetVRAM, auxVRAM: auxGPU.map { ImageControls.vram(of: $0) })
    }
    private var baseSizes: [Int] {
        let sizes = ImageGenLimits.baseSizes(vramGB: targetVRAM, residentGB: model.residentGB,
                                             attnVRAMSq: model.attnVRAMSq, maxLongEdge: model.maxLongEdge)
        return sizes.isEmpty ? [512] : sizes
    }
    private var fitsVRAM: Bool {
        let (w, h) = cfg.dimensions
        return ImageGenLimits.fits(width: w, height: h, vramGB: targetVRAM,
                                   residentGB: model.residentGB, attnVRAMSq: model.attnVRAMSq)
    }
    /// Fits, but close enough to the VRAM ceiling that a freeze or crash is possible.
    private var nearVRAMLimit: Bool {
        let (w, h) = cfg.dimensions
        return fitsVRAM && ImageGenLimits.vramFraction(width: w, height: h, vramGB: targetVRAM,
                                                       residentGB: model.residentGB,
                                                       attnVRAMSq: model.attnVRAMSq) >= 0.8
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            modelPicker
            if cfg.isCustom { customSetup }
            if !cfg.isCustom && !modelFitsGPU {
                Label(loc.t("Necesita \(Int(model.minVRAMGB)) GB de VRAM; no corre en esta GPU.",
                            "Needs \(Int(model.minVRAMGB)) GB of VRAM; it won't run on this GPU."),
                      systemImage: "xmark.octagon.fill")
                    .font(.caption2).foregroundStyle(.red)
            } else if !cfg.isCustom && !installed {
                installBox
            } else {
                Text(loc.t("Descripción", "Prompt")).font(.headline)
                promptEditor
                img2imgSection
                settingsGrid
                if !fitsVRAM { vramWarning }
                else if nearVRAMLimit { nearLimitNote }
                dimensionsFootnote
            }
            if canRemove {
                Button(role: .destructive, action: onRemove) {
                    Label(loc.t("Quitar instancia", "Remove instance"), systemImage: "trash")
                }
                .buttonStyle(.borderless).controlSize(.small)
                .disabled(busy)
                .help(loc.t("Elimina esta instancia.", "Removes this instance."))
            }
        }
    }

    // MARK: model

    /// Model chooser: every catalog model, with a note on ones too big for this
    /// GPU. Switching resets the step count to the new model's tuned default.
    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(loc.t("Modelo", "Model")).font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $cfg.modelID) {
                ForEach(ImageGenCatalog.models) { m in
                    let fits = targetVRAM >= m.minVRAMGB
                    Text(fits ? m.name : "\(m.name) · \(Int(m.minVRAMGB)) GB+").tag(m.id)
                }
                Divider()
                Text(loc.t("Personalizado…", "Custom…")).tag(ImageGenCatalog.customID)
            }
            .labelsHidden()
            .onChange(of: cfg.modelID) {
                if !cfg.isCustom { cfg.steps = model.defaultSteps }
                clampBaseSize()
            }
            .onChange(of: cfg.gpuIndex) { clampBaseSize() }
            .onAppear {
                if ImageGenCatalog.model(id: cfg.modelID) == nil && !cfg.isCustom {
                    cfg.modelID = model.id
                }
                clampBaseSize()
            }
            Text(model.detail(loc.isSpanish)).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Keep the base size within what the target GPU can hold (a smaller card,
    /// or a GPU switch, can drop the previously chosen size).
    private func clampBaseSize() {
        if !baseSizes.contains(cfg.baseSize) { cfg.baseSize = baseSizes.max() ?? 512 }
    }

    /// Inline install: the missing components with their sizes/progress and one
    /// download action, right where the model was picked.
    private var installBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.components) { componentRow($0) }
            Button {
                for comp in model.components {
                    models.downloadImageComponent(urlString: comp.urlString, fileName: comp.fileName)
                }
            } label: {
                Label(loc.t("Descargar todo (%.1f GB)", "Download all (%.1f GB)")
                        .replacingOccurrences(of: "%.1f", with: String(format: "%.1f", model.totalGB)),
                      systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .help(loc.t("Descarga los componentes del modelo.", "Download the model's components."))
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private func componentRow(_ comp: ImageGenComponent) -> some View {
        let present = FileManager.default.fileExists(
            atPath: comp.path(in: models.imagenDirectory).path)
        return HStack(spacing: 8) {
            Image(systemName: present ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(present ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(comp.label(loc.isSpanish)).font(.caption)
                Text(comp.fileName).font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let item = models.imageDownload(fileName: comp.fileName) {
                InlineDownloadProgress(item: item)
            } else if !present {
                Text(String(format: "%.1f GB", comp.sizeGB))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    /// Custom model setup: point the app at a checkpoint (and optional VAE) the
    /// user downloaded themselves, plus the CFG their model expects.
    private var customSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            filePickRow(loc.t("Archivo del modelo", "Model file"), path: $cfg.customModelPath,
                        types: ["safetensors", "gguf", "ckpt"])
            filePickRow(loc.t("VAE (opcional)", "VAE (optional)"), path: $cfg.customVAEPath,
                        types: ["safetensors", "gguf"])
            HStack(spacing: 6) {
                Text("CFG").font(.callout)
                Spacer(minLength: 8)
                TextField("", value: $cfg.customCfg, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 70)
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

    // MARK: prompt & settings

    private var promptEditor: some View {
        TextEditor(text: $cfg.prompt)
            .font(.body).frame(minHeight: 96)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topLeading) {
                if cfg.prompt.isEmpty {
                    Text(isPrimary
                         ? loc.t("Un zorro fotorrealista en un bosque nevado al atardecer…",
                                 "A photorealistic fox in a snowy forest at golden hour…")
                         : loc.t("Vacío: usa la descripción de la Instancia 1. Escribe aquí para personalizarla…",
                                 "Empty: uses Instance 1's prompt. Type here to customize it…"))
                        .font(.body).foregroundStyle(.tertiary)
                        .padding(.horizontal, 13).padding(.vertical, 16).allowsHitTesting(false)
                }
            }
    }

    /// img2img: optionally seed generation from an existing image. Strength shows
    /// only once an image is chosen (how much to transform it).
    private var img2imgSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            filePickRow(loc.t("Imagen inicial (img2img)", "Init image (img2img)"),
                        path: $cfg.initImagePath, types: ["png", "jpg", "jpeg", "webp"])
            if !cfg.initImagePath.isEmpty {
                let strengthTip = loc.t("Cuánto cambia la imagen inicial. Bajo (~0.3) conserva la composición; alto (~0.8) la reinventa.",
                                        "How much the init image changes. Low (~0.3) keeps the composition; high (~0.8) reinvents it.")
                HStack(spacing: 6) {
                    Text(loc.t("Intensidad", "Strength")).font(.caption).help(strengthTip)
                    Slider(value: $cfg.strength, in: 0.1...1.0).help(strengthTip)
                    Text(String(format: "%.2f", cfg.strength))
                        .font(.system(size: 11, design: .monospaced)).frame(width: 34).help(strengthTip)
                }
                if initImageRatioMismatch {
                    Label(loc.t("La imagen inicial tiene otra proporción que el marco elegido; puede recortar o deformar (p. ej. cabezas cortadas). Usa una referencia con la misma proporción.",
                                "The init image has a different ratio than the chosen frame; it may crop or distort (e.g. cut-off heads). Use a reference with the same ratio."),
                          systemImage: "aspectratio")
                        .font(.caption2).foregroundStyle(.yellow)
                }
            }
        }
    }

    /// The init image's pixel ratio vs the chosen frame's; a big gap warns about
    /// img2img cropping (cut-off subjects). Reads only the header, not the pixels.
    private var initImageRatioMismatch: Bool {
        guard !cfg.initImagePath.isEmpty,
              let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: cfg.initImagePath) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Double,
              let ph = props[kCGImagePropertyPixelHeight] as? Double, pw > 0, ph > 0 else { return false }
        let (w, h) = cfg.dimensions
        let target = Double(w) / Double(h)
        return abs(target - pw / ph) / target > 0.08
    }

    private var settingsGrid: some View {
        VStack(spacing: 12) {
            row(loc.t("Proporción", "Aspect ratio"),
                loc.t("Marco de la imagen. Se ajusta a múltiplos de 64 px.",
                      "Image framing. Snapped to multiples of 64 px.")) {
                Picker("", selection: $cfg.aspect) {
                    ForEach(ImageAspect.allCases) { a in
                        Text(a == .custom ? loc.t("Personalizado", "Custom") : a.rawValue).tag(a.rawValue)
                    }
                }.labelsHidden().frame(width: 96)
            }
            if cfg.aspectValue == .custom {
                row(loc.t("Proporción W:H", "Ratio W:H"),
                    loc.t("Proporción libre como 21:9 (cine) o 3:2. El lado largo respeta el Tamaño base y la VRAM: no fija píxeles arbitrarios, así no cuelga la GPU.",
                          "Free ratio like 21:9 (cinema) or 3:2. The long edge respects the Base size and VRAM: it sets no arbitrary pixel count, so the GPU can't hang.")) {
                    TextField("21:9", text: $cfg.customAspect)
                        .textFieldStyle(.roundedBorder).frame(width: 96)
                }
            }
            row(loc.t("Tamaño base", "Base size"),
                loc.t("Lado largo en píxeles. El máximo se ajusta a la VRAM de la GPU.",
                      "Long edge in pixels. The maximum adapts to the GPU's VRAM.")) {
                Picker("", selection: $cfg.baseSize) {
                    ForEach(baseSizes, id: \.self) { Text("\($0) px").tag($0) }
                }.labelsHidden().frame(width: 96)
            }
            if !hardware.gpus.isEmpty {
                row("GPU",
                    loc.t("GPU que hará la generación de esta instancia.",
                          "GPU that runs this instance's generation.")) {
                    if hardware.gpus.count > 1 {
                        Picker("", selection: $cfg.gpuIndex) {
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
            if hardware.gpus.count > 1 {
                row(loc.t("Encoder/VAE en GPU", "Encoder/VAE on GPU"),
                    loc.t("Manda el text-encoder y el VAE a otra GPU y deja esta libre para el modelo de difusión: caben modelos más grandes o imágenes mayores.",
                          "Moves the text encoder and VAE to another GPU, leaving this one to the diffusion model: bigger models or larger frames fit.")) {
                    Picker("", selection: $cfg.auxGPUIndex) {
                        Text(loc.t("Misma GPU", "Same GPU")).tag(-1)
                        ForEach(Array(hardware.gpus.enumerated()), id: \.offset) { i, g in
                            if i != cfg.gpuIndex { Text(g.name).tag(i) }
                        }
                    }.labelsHidden().frame(width: 140)
                    .onChange(of: cfg.gpuIndex) {
                        if cfg.auxGPUIndex == cfg.gpuIndex { cfg.auxGPUIndex = -1 }
                    }
                }
            }
            row(loc.t("Pasos", "Steps"),
                loc.t("Iteraciones de muestreo. Los modelos turbo/distilled están afinados para pocos pasos.",
                      "Sampling iterations. Turbo/distilled models are tuned for few steps.")) {
                Stepper(value: $cfg.steps, in: 4...30) { Text("\(cfg.steps)").monospacedDigit() }.frame(width: 96)
            }
            row(loc.t("Semilla", "Seed"),
                loc.t("-1 = aleatoria. Fija un número para reproducir la misma imagen; distinta semilla = variación.",
                      "-1 = random. Set a number to reproduce the same image; a different seed = a variation.")) {
                TextField("", value: $cfg.seed, format: .number).textFieldStyle(.roundedBorder).frame(width: 96)
            }
            row(loc.t("Formato", "Format"),
                loc.t("JPG pesa mucho menos; PNG es sin pérdida.",
                      "JPG is far lighter; PNG is lossless.")) {
                Picker("", selection: $cfg.format) {
                    ForEach(ImageFormat.allCases) { Text($0.rawValue.uppercased()).tag($0.rawValue) }
                }.labelsHidden().frame(width: 96)
            }
            row(loc.t("Descargar a CPU", "Offload to CPU"),
                loc.t("Mantiene los pesos en RAM y los sube a VRAM por etapas. Más lento; solo si falta VRAM.",
                      "Keeps weights in RAM and streams them to VRAM per stage. Slower; only if VRAM is tight.")) {
                Toggle("", isOn: $cfg.offloadCPU).labelsHidden().toggleStyle(.switch)
            }
        }
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

    private var dimensionsFootnote: some View {
        let (w, h) = cfg.dimensions
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
}

/// Turn the engine's failure sentinel into a bilingual, actionable message.
private func imageFailureText(_ raw: String, _ loc: Localizer) -> String {
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

/// Detail column: single canvas for one instance, a tile grid for several.
struct ImageCanvas: View {
    @ObservedObject var pool: ImageGenPool
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var models: ModelStore
    @State private var detailTab: ImageDetailTab = .instances
    @AppStorage(SettingsKeys.imagenCanvasGrid) private var canvasGrid = false

    var body: some View {
        Group {
            if !ImageGenerator.engineInstalled {
                centered { engineMissingCard }
            } else {
                VStack(spacing: 14) {
                    Picker("", selection: $detailTab) {
                        Text(loc.t("Instancias", "Instances")).tag(ImageDetailTab.instances)
                        Text(pool.queue.isEmpty ? loc.t("Cola", "Queue")
                                                : loc.t("Cola (\(pool.queue.count))", "Queue (\(pool.queue.count))"))
                            .tag(ImageDetailTab.queue)
                    }
                    .pickerStyle(.segmented).fixedSize()

                    if detailTab == .instances {
                        instancesCanvas
                    } else {
                        QueueFeedView(pool: pool)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    @ViewBuilder private var instancesCanvas: some View {
        if pool.configs.count == 1, let cfg = pool.configs.first {
            singleCanvas(cfg)
        } else {
            multiCanvas
        }
    }

    // MARK: single instance

    @ViewBuilder private func singleCanvas(_ cfg: ImageInstanceConfig) -> some View {
        let gen = pool.generator(for: cfg.id)
        if let img = gen.resultImage, !gen.isBusy {
            resultCanvas(img, gen: gen, format: cfg.formatValue)
        } else if gen.isBusy {
            progressCanvas(gen)
        } else {
            idleCanvas(gen)
        }
    }

    private func idleCanvas(_ gen: ImageGenerator) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 46)).foregroundStyle(.tertiary)
            Text(loc.t("Elige un modelo, escribe una descripción y pulsa Generar",
                       "Pick a model, type a prompt and press Generate")).foregroundStyle(.secondary)
            if case .failed(let msg) = gen.state, !msg.isEmpty {
                Label(imageFailureText(msg, loc), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).frame(maxWidth: 380)
            }
        }
    }

    private func progressCanvas(_ gen: ImageGenerator) -> some View {
        VStack(spacing: 18) {
            ProgressView(value: gen.progress > 0 ? gen.progress : nil)
                .progressViewStyle(.linear).frame(width: 260)
            Text(stageLabel(gen)).font(.headline)
            HStack(spacing: 14) {
                Label("\(gen.elapsed)s", systemImage: "clock")
                if let eta = gen.etaSeconds {
                    Label(loc.t("~\(eta)s restantes", "~\(eta)s left"), systemImage: "hourglass")
                }
            }
            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private func stageLabel(_ gen: ImageGenerator) -> String {
        switch gen.stage {
        case .loading:  return loc.t("Cargando modelos…", "Loading models…")
        case .sampling: return loc.t("Generando · paso \(gen.stepText)", "Sampling · step \(gen.stepText)")
        case .decoding: return loc.t("Decodificando imagen…", "Decoding image…")
        }
    }

    private func resultCanvas(_ img: NSImage, gen: ImageGenerator, format: ImageFormat) -> some View {
        VStack(spacing: 12) {
            Image(nsImage: img)
                .resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 6) {
                if !gen.lastPrompt.isEmpty {
                    Text(gen.lastPrompt)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).help(gen.lastPrompt)
                }
                HStack(spacing: 14) {
                    if gen.lastDuration > 0 {
                        Label(loc.t("Generado en \(gen.lastDuration)s", "Generated in \(gen.lastDuration)s"),
                              systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
                    }
                    Text("\(gen.lastWidth) × \(gen.lastHeight) · \(format.rawValue.uppercased())"
                         + (gen.lastSeed >= 0 ? " · #\(gen.lastSeed)" : ""))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Button { if let url = gen.resultURL { saveAs(url, format: format) } } label: {
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: several instances

    /// Canvas with one tile per instance: full-width rows (image left, info
    /// right) or an adaptive grid whose column count follows the window width.
    private var multiCanvas: some View {
        VStack(spacing: 12) {
            let savable = pool.configs.compactMap { pool.generator(for: $0.id).resultURL }
            HStack(spacing: 12) {
                Spacer()
                FeedLayoutPicker(grid: $canvasGrid)
                if savable.count > 1 {
                    Button { saveAll(savable) } label: {
                        Label(loc.t("Guardar todas…", "Save all…"), systemImage: "square.and.arrow.down.on.square")
                    }
                    .help(loc.t("Copia todas las imágenes generadas a una carpeta que elijas.",
                                "Copies every generated image into a folder you choose."))
                }
            }
            ScrollView {
                if canvasGrid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 14)],
                              alignment: .leading, spacing: 14) {
                        ForEach(pool.configs) { instanceTile($0, grid: true) }
                    }
                    .padding(4)
                } else {
                    VStack(spacing: 14) {
                        ForEach(pool.configs) { instanceTile($0, grid: false) }
                    }
                    .padding(4)
                }
            }
        }
    }

    private func instanceTile(_ cfg: ImageInstanceConfig, grid: Bool) -> some View {
        ImageInstanceRow(gen: pool.generator(for: cfg.id), title: tileTitle(cfg),
                         dims: cfg.dimensions, format: cfg.formatValue, grid: grid,
                         onSave: { saveAs($0, format: cfg.formatValue) })
    }

    /// Instance number, model and GPU. Seed and dimensions live in the tile's
    /// metadata line, next to the run they actually belong to.
    private func tileTitle(_ cfg: ImageInstanceConfig) -> String {
        let n = (pool.configs.firstIndex { $0.id == cfg.id } ?? 0) + 1
        var parts = ["\(n) · \(cfg.resolvedModel(for: hardware).name)"]
        if hardware.gpus.count > 1, cfg.gpuIndex < hardware.gpus.count {
            parts.append(hardware.gpus[cfg.gpuIndex].name)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: gates & helpers

    private var engineMissingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(loc.t("Motor de imagen no incluido en esta build",
                        "Image engine not in this build"), systemImage: "exclamationmark.triangle")
                .font(.headline).foregroundStyle(.orange)
            Text(loc.t("Compila los motores (`./scripts/build-engines.sh`) para incluir la generación de imágenes.",
                       "Build the engines (`./scripts/build-engines.sh`) to include image generation."))
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { content() }.frame(maxWidth: 560)
    }

    private func saveAs(_ source: URL, format: ImageFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "toshllm.\(format.ext)"
        panel.allowedContentTypes = [format == .jpg ? .jpeg : .png]
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: source, to: dest)
        }
    }

    /// Copies every result into one folder the user picks. Output names are unique
    /// (timestamp + token), so nothing clobbers inside the destination.
    private func saveAll(_ urls: [URL]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = loc.t("Guardar aquí", "Save here")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        for src in urls {
            try? FileManager.default.copyItem(at: src, to: dir.appendingPathComponent(src.lastPathComponent))
        }
    }
}

/// One tile on the multi-instance canvas. As a list row the image fills the
/// width with the info panel on the right; as a grid card the info sits under
/// the image. Both show the run's prompt and full metadata.
struct ImageInstanceRow: View {
    @ObservedObject var gen: ImageGenerator
    let title: String
    let dims: (Int, Int)
    let format: ImageFormat
    let grid: Bool
    let onSave: (URL) -> Void
    @EnvironmentObject var loc: Localizer

    var body: some View {
        Group {
            if grid {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(.callout.weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                    imageArea
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 180, maxHeight: 320)
                    infoPanel
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    imageArea
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 240, maxHeight: 460)
                    sidePanel
                        .frame(width: 220, alignment: .leading)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var imageArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3))
            if let img = gen.resultImage, !gen.isBusy {
                Image(nsImage: img).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if gen.isBusy {
                VStack(spacing: 10) {
                    ProgressView(value: gen.progress > 0 ? gen.progress : nil)
                        .progressViewStyle(.linear).frame(width: 180)
                    Text(gen.stepText.isEmpty ? "…" : gen.stepText)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            } else if case .failed(let msg) = gen.state, !msg.isEmpty {
                Label(imageFailureText(msg, loc), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red).padding(10)
            } else {
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary)
            }
        }
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            infoPanel
            Spacer(minLength: 0)
        }
    }

    /// Prompt, dimensions, seed and timing of the last run, plus save/reveal.
    @ViewBuilder private var infoPanel: some View {
        if gen.isBusy {
            Label("\(gen.elapsed)s", systemImage: "clock")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            if let eta = gen.etaSeconds {
                Label(loc.t("~\(eta)s restantes", "~\(eta)s left"), systemImage: "hourglass")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        } else if let url = gen.resultURL, gen.resultImage != nil {
            if !gen.lastPrompt.isEmpty {
                Text(gen.lastPrompt)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(grid ? 2 : 4)
                    .help(gen.lastPrompt)
            }
            Text(metaLine)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            if gen.lastDuration > 0 {
                Label(loc.t("Generado en \(gen.lastDuration)s", "Generated in \(gen.lastDuration)s"),
                      systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
            }
            if grid {
                HStack(spacing: 10) {
                    saveButton(url)
                    revealButton(url)
                }
                .controlSize(.small)
            } else {
                saveButton(url)
                revealButton(url)
            }
        } else if case .failed = gen.state {
            EmptyView()
        } else {
            Text(loc.t("En espera", "Idle")).font(.caption).foregroundStyle(.tertiary)
        }
    }

    /// Real output size when the run recorded one, the configured size otherwise.
    private var metaLine: String {
        let w = gen.lastWidth > 0 ? gen.lastWidth : dims.0
        let h = gen.lastHeight > 0 ? gen.lastHeight : dims.1
        var s = "\(w) × \(h) · \(format.rawValue.uppercased())"
        if gen.lastSeed >= 0 { s += " · #\(gen.lastSeed)" }
        return s
    }

    private func saveButton(_ url: URL) -> some View {
        Button { onSave(url) } label: {
            Label(loc.t("Guardar como…", "Save as…"), systemImage: "square.and.arrow.down")
        }
        .help(loc.t("Guarda una copia donde elijas.", "Save a copy wherever you choose."))
    }

    private func revealButton(_ url: URL) -> some View {
        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
            Label(loc.t("Mostrar en Finder", "Reveal in Finder"), systemImage: "folder")
        }
        .help(loc.t("Abre el archivo en el Finder.", "Reveal the file in Finder."))
    }
}
