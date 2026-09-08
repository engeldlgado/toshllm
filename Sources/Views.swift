// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Reveal a file in Finder, falling back to opening its folder when the file
/// doesn't exist yet (a fresh session writes its file lazily, so selecting a
/// not-yet-created path would otherwise drop the user in their home folder).
@MainActor func revealInFinder(file: URL, folder: URL) {
    if FileManager.default.fileExists(atPath: file.path) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
    } else {
        NSWorkspace.shared.open(folder)
    }
}

enum Section_: String, CaseIterable, Identifiable {
    case dashboard, chat, models, benchmarks, docs, logs, chatSettings, settings, about
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: return "house"
        case .chat: return "bubble.left.and.bubble.right"
        case .models: return "shippingbox"
        case .benchmarks: return "speedometer"
        case .docs: return "book"
        case .logs: return "list.bullet.rectangle"
        case .chatSettings: return "bubble.left.and.text.bubble.right"
        case .settings: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }
    func title(_ loc: Localizer) -> String {
        switch self {
        case .dashboard: return loc.t("Inicio", "Home")
        case .chat: return "Chat"
        case .models: return loc.t("Modelos", "Models")
        case .benchmarks: return "Benchmarks"
        case .docs: return loc.t("Documentación", "Docs")
        case .logs: return loc.t("Registro", "Logs")
        case .chatSettings: return loc.t("Ajustes del chat", "Chat Settings")
        case .settings: return loc.t("Ajustes", "Settings")
        case .about: return loc.t("Acerca de", "About")
        }
    }
}

let hardware = HardwareInfo.detect()

/// The management window: hardware dashboard, models, benchmarks, docs and
/// settings. The chat lives in its own (main) window.
struct ControlPanelView: View {
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var control: ControlPanelState
    @EnvironmentObject private var manager: ServerManager
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @AppStorage(SettingsKeys.appAccent) private var accentRaw = AppTheme.defaultKey
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WorkspaceSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 244, max: 290)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    if selectedServer != nil {
                        Button {
                            control.serverAnchor = nil
                        } label: {
                            Label(loc.t("Volver a servidores", "Back to servers"), systemImage: "chevron.left")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                    } else {
                        SectionGlyph(systemName: control.section.icon)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedServerTitle).font(.title2.bold())
                            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 12)
                    ServerStatsToolbar().environmentObject(selectedServer ?? manager.servers[0])
                }
                .padding(.horizontal, 24).padding(.vertical, 16)
                Divider().padding(.horizontal, 24)
                WorkspaceDestinationView(section: control.section, serverID: control.serverAnchor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollContentBackground(.hidden)
            }
            .background(WorkspaceStyle.canvas)
        }
        .tint(AppTheme.accent(accentRaw))
        .id(accentRaw)
        .navigationTitle("ToshLLM")
    }

    private var selectedServer: ServerController? {
        guard control.section == .dashboard, let id = control.serverAnchor else { return nil }
        return manager.servers.first { $0.id == id }
    }

    private var selectedServerTitle: String {
        selectedServer.map { manager.displayName(for: $0, loc: loc) }
            ?? control.section.title(loc)
    }

    private var subtitle: String {
        if selectedServer != nil { return loc.t("Modelo y configuración de esta instancia.", "Model and settings for this instance.") }
        switch control.section {
        case .dashboard, .chat: return loc.t("Tu equipo y tu IA, de un vistazo.", "Your machine and AI status at a glance.")
        case .models: return loc.t("Encuentra, descarga y gestiona tus modelos locales.", "Discover, download and manage your local models.")
        case .benchmarks: return loc.t("Mide el rendimiento de tu equipo.", "Measure performance on your hardware.")
        case .settings, .chatSettings: return loc.t("Control completo sobre tu experiencia local.", "Fine-tune your local AI experience.")
        case .logs: return loc.t("Actividad y diagnóstico de los motores.", "Engine activity and diagnostics.")
        case .docs: return loc.t("Guías y referencia de ToshLLM.", "ToshLLM guides and reference.")
        case .about: return loc.t("IA local, hecha para tu Mac.", "Local AI, built for your Mac.")
        }
    }

}

/// First-run guidance shown when no models are installed yet.
struct OnboardingSheet: View {
    @EnvironmentObject var loc: Localizer
    let onGoToModels: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ToshLLMLogo(size: 72)
            Text(loc.t("Bienvenido a ToshLLM", "Welcome to ToshLLM"))
                .font(.title.bold())
            Text(loc.t("Modelos de lenguaje corriendo en tu GPU, sin nube y sin cuentas.",
                       "Language models running on your GPU — no cloud, no accounts."))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                step("1", loc.t("Descarga un modelo del catálogo — la app te marca cuáles caben en tu equipo.",
                                "Download a model from the catalog — the app marks which ones fit your machine."))
                step("2", loc.t("Pulsa 'Usar' y los parámetros se configuran solos.",
                                "Press 'Use' and the parameters configure themselves."))
                step("3", loc.t("Vuelve al Chat, pulsa 'Iniciar servidor' y escribe.",
                                "Go back to Chat, press 'Start server' and type."))
            }
            .frame(maxWidth: 380)

            HStack {
                Button(loc.t("Explorar por mi cuenta", "Explore on my own"), action: onDismiss)
                Button {
                    onGoToModels()
                } label: {
                    Label(loc.t("Elegir mi primer modelo", "Pick my first model"),
                          systemImage: "shippingbox")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(30)
        .frame(width: 480)
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number)
                .font(.system(.callout, design: .rounded).bold())
                .frame(width: 24, height: 24)
                .background(Color.appAccent.opacity(0.18), in: Circle())
                .foregroundStyle(Color.appAccent)
            Text(text)
        }
    }
}

// MARK: - Stats bar

/// Compact server telemetry for the configuration window's toolbar, so the
/// stats share the system's glass title bar (macOS 26) instead of sitting in a
/// flat strip under the large title.
struct ServerStatsToolbar: View {
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var vram: VRAMMonitor
    @EnvironmentObject var loc: Localizer

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                stat("Prompt", server.promptSpeed)
                stat(loc.t("Generación", "Generation"), server.genSpeed)
                Divider().frame(height: 18)
                statusBadge
            }
            .fixedSize()
            statusBadge.fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassSurface(in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorkspaceStyle.border))
    }

    private func stat(_ label: String, _ value: Double?) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.0f", $0) } ?? "—")
                .font(.system(size: 12, design: .monospaced).weight(.semibold))
        }
        .help(loc.t("%@: velocidad de la última petición en tokens por segundo.",
                    "%@: last request speed in tokens per second.", label))
    }

    private var statusBadge: some View {
        // a failed engine used to spill its whole diagnosis across the toolbar; the
        // word is enough here and the detail belongs in the tooltip
        let (text, color): (String, Color) = {
            switch server.state {
            case .stopped: return (loc.t("Detenido", "Stopped"), .secondary)
            case .starting: return (loc.t("Cargando…", "Loading…"), .orange)
            case .running: return (loc.t("Activo", "Running"), .green)
            case .failed: return (loc.t("Error", "Error"), .red)
            }
        }()
        var detail = text
        if case .failed(let msg) = server.state { detail = loc.half(msg) }
        return HStack(spacing: 5) {
            if case .failed = server.state {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(text).font(.caption).lineLimit(1)
        }
        .help(detail)
    }
}
