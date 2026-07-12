import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The system default tooltip delay (~1.5 s) makes the bilingual .help
        // hints feel broken; show them promptly.
        UserDefaults.standard.set(400, forKey: "NSInitialToolTipDelay")

        // Shut the engine down cleanly on SIGTERM (pkill, logout, system
        // shutdown); otherwise the child would be orphaned holding VRAM.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            ServerManager.shared.stopAll()
            NSApp.terminate(nil)
        }
        source.resume()
        sigtermSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        ServerManager.shared.stopAll()
        ImageGenPool.cleanupOutputsIfEnabled()
    }
}

private func defaultsMigrationExtraArgs() -> String? {
    UserDefaults.standard.string(forKey: SettingsKeys.extraArgs)
}

@main
struct ToshLLMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var manager = ServerManager.shared
    // The active instance, observed directly so state changes drive the UI. One
    // server today; switching the active one is handled when the multi-server UI lands.
    @StateObject private var server = ServerManager.shared.active
    @StateObject private var models = ModelStore()
    @StateObject private var vram = VRAMMonitor()
    @StateObject private var loc = Localizer()
    @StateObject private var bench = BenchmarkController()
    @StateObject private var search = SearchStore()
    @StateObject private var profiles = ProfileStore()
    @StateObject private var updates = UpdateChecker()
    @StateObject private var control = ControlPanelState()
    @AppStorage(SettingsKeys.menuBarIcon) private var menuBarIcon = true
    @AppStorage(SettingsKeys.menuBarGPU) private var menuBarGPU = "panel"

    init() {
        // Release VRAM held by an engine orphaned by a previous force-quit.
        EngineLock.reapOrphans()

        // Remove the legacy raw flag; MTP is selected automatically per model.
        if var extra = defaultsMigrationExtraArgs(), extra.contains("--spec-type draft-mtp") {
            extra = extra.replacingOccurrences(of: "--spec-type draft-mtp", with: "")
                .trimmingCharacters(in: .whitespaces)
            UserDefaults.standard.set(extra, forKey: SettingsKeys.extraArgs)
        }

        // Heal the stored engine path: legacy builds or paths from another machine
        // fall back to the bundled engine.
        let defaults = UserDefaults.standard
        let legacyDefaults = ["llama.cpp-b7833", "llama.cpp/build/bin/llama-server"]
        if let bin = defaults.string(forKey: "serverBinary"),
           legacyDefaults.contains(where: bin.contains) || !FileManager.default.fileExists(atPath: bin) {
            defaults.set(ServerSettings.defaultBinary, forKey: "serverBinary")
        }
    }

    var body: some Scene {
        // Main window: the chat. A single Window (not WindowGroup) keeps ⌘N
        // for "new conversation" instead of "new window".
        Window("ToshLLM", id: "chat") {
            ChatMainView()
                .environmentObject(server)
                .environmentObject(manager)
                .environmentObject(models)
                .environmentObject(vram)
                .environmentObject(loc)
                .environmentObject(bench)
                .environmentObject(search)
                .environmentObject(profiles)
                .environmentObject(updates)
                .environmentObject(control)
                .tint(.pink)
                .frame(minWidth: 760, minHeight: 540)
                .task { await updates.check() }
        }
        .defaultSize(width: 1240, height: 820)

        Window(loc.t("Configuración", "Configuration"), id: "control") {
            ControlPanelView()
                .environmentObject(server)
                .environmentObject(manager)
                .environmentObject(models)
                .environmentObject(vram)
                .environmentObject(loc)
                .environmentObject(bench)
                .environmentObject(search)
                .environmentObject(profiles)
                .environmentObject(updates)
                .environmentObject(control)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1080, height: 700)

        MenuBarExtra(isInserted: $menuBarIcon) {
            MenuBarView()
                .environmentObject(server)
                .environmentObject(manager)
                .environmentObject(loc)
                .environmentObject(vram)
        } label: {
            let icon = server.state == .running ? "cpu.fill" : "cpu"
            // "icon" mode shows aggregate VRAM next to the glyph; per-GPU bars
            // live in the panel.
            if menuBarGPU == "icon", vram.totalMB > 0 {
                Label("\(Int(vram.fraction * 100))%", systemImage: icon)
            } else {
                Image(systemName: icon)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Window-style menu bar panel: a real SwiftUI surface so it can draw per-GPU
/// VRAM bars and per-server controls (a native menu only renders text/buttons).
struct MenuBarView: View {
    @EnvironmentObject var manager: ServerManager
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var vram: VRAMMonitor
    @AppStorage(SettingsKeys.menuBarGPU) private var menuBarGPU = "panel"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Every server, primary first, each with its own start/stop + networking.
            ForEach(Array(manager.servers.enumerated()), id: \.element.id) { i, c in
                if i > 0 { Divider() }
                MenuServerRow(c: c, isPrimary: i == 0).environmentObject(manager).environmentObject(loc)
            }

            if menuBarGPU == "panel" && !vram.gpus.isEmpty {
                Divider()
                gpuSection
            }

            Divider()

            HStack {
                Button(loc.t("Abrir ToshLLM", "Open ToshLLM")) {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
                }
                Spacer()
                Button(loc.t("Salir", "Quit")) { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private var gpuSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc.t("GPUs", "GPUs")).font(.caption).foregroundStyle(.secondary)
            ForEach(vram.gpus) { g in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(g.name).font(.caption).lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(Int(g.fraction * 100))%")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    ProgressView(value: g.fraction)
                        .tint(g.fraction > 0.9 ? .red : g.fraction > 0.75 ? .orange : .accentColor)
                }
            }
        }
    }
}

/// One server in the menu bar panel (primary or added): live status, start/stop,
/// chat link and a per-server networking toggle. Observes the controller so it
/// refreshes while the panel is open.
struct MenuServerRow: View {
    @ObservedObject var c: ServerController
    let isPrimary: Bool
    @EnvironmentObject var manager: ServerManager
    @EnvironmentObject var loc: Localizer
    @AppStorage(SettingsKeys.localNetworkDiscovery) private var globalDiscover = false

    private var running: Bool { c.state == .running || c.state == .starting }
    private var hasModel: Bool {
        isPrimary ? !((UserDefaults.standard.string(forKey: SettingsKeys.modelPath) ?? "").isEmpty)
                  : !((c.profile?.modelPath ?? "").isEmpty)
    }
    private var dotColor: Color {
        switch c.state {
        case .running: return .green
        case .starting: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                // The primary's stored name isn't localized; show the same label the
                // dashboard uses for it. Added servers keep their user-facing name.
                Text(isPrimary ? loc.t("Servidor", "Server") : c.name)
                    .font(.subheadline.weight(.medium)).lineLimit(1)
                if c.state == .running, let tg = c.genSpeed {
                    Text(String(format: "%.1f t/s", tg))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                actions
            }
            HStack(spacing: 6) {
                Image(systemName: "wifi").font(.caption2).foregroundStyle(.secondary)
                Text(loc.t("Descubrible en red", "Discoverable")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: discoverBinding)
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if running {
            if c.state == .running {
                Button(loc.t("Chat", "Chat")) { NSWorkspace.shared.open(c.webChatURL) }.controlSize(.small)
            }
            Button(loc.t("Detener", "Stop")) { c.stop() }.controlSize(.small)
        } else {
            Button(loc.t("Iniciar", "Start")) {
                c.start(isPrimary ? .fromDefaults() : c.effectiveSettings())
            }
            .controlSize(.small).disabled(!hasModel)
        }
    }

    // Networking is a launch flag, so restart the server if it's up to apply it now.
    private var discoverBinding: Binding<Bool> {
        if isPrimary {
            return Binding(get: { globalDiscover }, set: { v in
                globalDiscover = v
                if running { c.restart(.fromDefaults()) }
            })
        }
        return Binding(get: { c.profile?.localNetworkDiscovery ?? false }, set: { v in
            c.profile?.localNetworkDiscovery = v
            manager.persist()
            if running { c.restart(c.effectiveSettings()) }
        })
    }
}
