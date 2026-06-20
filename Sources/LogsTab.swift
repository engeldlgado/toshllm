import SwiftUI

// MARK: - Logs

/// Dedicated, full-height server-log viewer with search, severity filtering,
/// toggleable auto-follow, copy and diagnostics export — replacing the cramped
/// 200 px panel that used to live inside Settings.
struct LogsView: View {
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""
    @AppStorage(SettingsKeys.ncmoe) private var ncmoe = 0

    @State private var query = ""
    /// Minimum severity to show: 0 = everything, 1 = warnings+, 2 = errors only.
    @State private var minLevel = 0
    @State private var autoFollow = true
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            logBody
        }
    }

    // MARK: controls

    private var controls: some View {
        VStack(spacing: 8) {
            serverControls
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField(loc.t("Filtrar en el registro…", "Filter the log…"), text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))

                Picker("", selection: $minLevel) {
                    Text(loc.t("Todo", "All")).tag(0)
                    Text(loc.t("Avisos", "Warnings")).tag(1)
                    Text(loc.t("Errores", "Errors")).tag(2)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help(loc.t("Filtra por severidad mínima de cada línea.",
                            "Filter by each line's minimum severity."))
            }

            HStack(spacing: 12) {
                Toggle(isOn: $autoFollow) {
                    Label(loc.t("Seguir", "Follow"), systemImage: "arrow.down.to.line")
                }
                .toggleStyle(.button)
                .help(loc.t("Sigue automáticamente las líneas nuevas al final.",
                            "Automatically follow new lines at the bottom."))

                Spacer()

                Text(loc.t("\(matchCount) líneas", "\(matchCount) lines"))
                    .font(.caption2).foregroundStyle(.tertiary)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(filteredLog, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? loc.t("Copiado", "Copied") : loc.t("Copiar", "Copy"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help(loc.t("Copia lo que se muestra (con los filtros aplicados).",
                            "Copies what's shown (with filters applied)."))

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([server.logFileURL])
                } label: {
                    Label(loc.t("Archivo en Finder", "File in Finder"), systemImage: "doc.text.magnifyingglass")
                }
                .help(loc.t("Cada sesión del servidor se guarda en su propio archivo con fecha y hora, así un cierre inesperado o un cuelgue de la Mac conserva el registro. Se borran solos a los 3 días.",
                            "Each server session is saved to its own date-and-time file, so an unexpected quit or a Mac freeze keeps the log. They auto-delete after 3 days."))

                Button { exportDiagnostics() } label: {
                    Label(loc.t("Exportar diagnóstico…", "Export diagnostics…"), systemImage: "square.and.arrow.up")
                }
                .help(loc.t("Genera un archivo con tu hardware, configuración y el registro reciente, listo para adjuntar a un reporte.",
                            "Creates a file with your hardware, settings and recent log, ready to attach to a report."))

                Button(role: .destructive) { server.log = "" } label: {
                    Label(loc.t("Limpiar", "Clear"), systemImage: "trash")
                }
                .help(loc.t("Vacía el registro en pantalla (el archivo en disco se conserva).",
                            "Clears the on-screen log (the file on disk is kept)."))
            }
            .font(.callout)
            .buttonStyle(.borderless)
        }
        .padding(12)
    }

    // MARK: server controls

    /// Start/stop the server and pick a model right here, so you can drive a debug
    /// session without leaving the log you're watching.
    private var serverControls: some View {
        HStack(spacing: 10) {
            Menu {
                if models.models.isEmpty {
                    Text(loc.t("No hay modelos descargados", "No downloaded models"))
                } else {
                    ForEach(models.models) { m in
                        Button {
                            modelPath = m.url.path
                            ncmoe = Estimator.estimateCurrent(spec: Catalog.spec(forLocal: m), hw: hardware).suggestedNcmoe
                        } label: {
                            Label(m.name, systemImage: modelPath == m.url.path ? "checkmark" : "cpu")
                        }
                    }
                }
            } label: {
                Label(selectedModelName, systemImage: "cpu")
                    .lineLimit(1).truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .help(loc.t("Selecciona el modelo a cargar.", "Pick the model to load."))

            Spacer()

            statusDot
            switch server.state {
            case .running, .starting:
                Button(role: .destructive) { server.stop() } label: {
                    Label(loc.t("Detener", "Stop"), systemImage: "stop.fill")
                }
            default:
                Button { server.start(.fromDefaults()) } label: {
                    Label(loc.t("Iniciar servidor", "Start server"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(modelPath.isEmpty)
            }
        }
        .font(.callout)
        .padding(.bottom, 2)
    }

    private var selectedModelName: String {
        guard !modelPath.isEmpty else { return loc.t("Seleccionar modelo…", "Select model…") }
        return URL(fileURLWithPath: modelPath).lastPathComponent
    }

    @ViewBuilder private var statusDot: some View {
        switch server.state {
        case .running:  Circle().fill(.green).frame(width: 8, height: 8)
        case .starting: Circle().fill(.orange).frame(width: 8, height: 8)
        case .failed:   Circle().fill(.red).frame(width: 8, height: 8)
        case .stopped:  Circle().fill(.secondary).frame(width: 8, height: 8)
        }
    }

    // MARK: log body

    private var logBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(filteredLog.isEmpty
                     ? loc.t("(sin coincidencias)", "(no matches)")
                     : filteredLog)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
                    .id("logEnd")
            }
            .background(.black.opacity(0.18))
            .onChange(of: server.log) { _, _ in
                if autoFollow { proxy.scrollTo("logEnd", anchor: .bottom) }
            }
            .onChange(of: autoFollow) { _, on in
                if on { proxy.scrollTo("logEnd", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("logEnd", anchor: .bottom) }
        }
    }

    // MARK: filtering

    /// llama-server prefixes each line with a timestamp then a severity char
    /// (`I`/`W`/`E`). Continuation lines (multi-line dumps, app stdout) have no
    /// such marker; they count as info so they only show in the "All" view.
    private func rank(_ line: Substring) -> Int {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return 0 }
        switch parts[1] {
        case "E": return 2
        case "W": return 1
        default:  return 0
        }
    }

    private var filteredLog: String {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard minLevel > 0 || !q.isEmpty else { return server.log }
        let lines = server.log.split(separator: "\n", omittingEmptySubsequences: false)
        let out = lines.filter { line in
            if minLevel > 0, rank(line) < minLevel { return false }
            if !q.isEmpty, !line.lowercased().contains(q) { return false }
            return true
        }
        return out.joined(separator: "\n")
    }

    private var matchCount: Int {
        filteredLog.isEmpty ? 0 : filteredLog.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    // MARK: diagnostics

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
