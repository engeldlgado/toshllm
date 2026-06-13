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
            ServerController.shared.stop()
            NSApp.terminate(nil)
        }
        source.resume()
        sigtermSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        ServerController.shared.stop()
    }
}

private func defaultsMigrationExtraArgs() -> String? {
    UserDefaults.standard.string(forKey: SettingsKeys.extraArgs)
}

@main
struct ToshLLMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var server = ServerController.shared
    @StateObject private var models = ModelStore()
    @StateObject private var vram = VRAMMonitor()
    @StateObject private var loc = Localizer()
    @StateObject private var bench = BenchmarkController()
    @StateObject private var search = SearchStore()
    @StateObject private var profiles = ProfileStore()
    @StateObject private var updates = UpdateChecker()
    @StateObject private var control = ControlPanelState()
    @AppStorage(SettingsKeys.menuBarIcon) private var menuBarIcon = true

    init() {
        // Release VRAM held by an engine orphaned by a previous force-quit.
        EngineLock.reapOrphan()

        // Migrate the legacy raw flag into the dedicated MTP toggle.
        if var extra = defaultsMigrationExtraArgs(), extra.contains("--spec-type draft-mtp") {
            extra = extra.replacingOccurrences(of: "--spec-type draft-mtp", with: "")
                .trimmingCharacters(in: .whitespaces)
            UserDefaults.standard.set(extra, forKey: SettingsKeys.extraArgs)
            UserDefaults.standard.set(true, forKey: SettingsKeys.specMTP)
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
                .environmentObject(loc)
        } label: {
            Image(systemName: server.state == .running ? "cpu.fill" : "cpu")
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var loc: Localizer

    var body: some View {
        Group {
            switch server.state {
            case .running:
                Text(loc.t("Servidor activo", "Server running") +
                     (server.genSpeed.map { String(format: " · %.1f t/s", $0) } ?? ""))
                Button(loc.t("Abrir chat en el navegador", "Open chat in browser")) {
                    NSWorkspace.shared.open(server.serverURL)
                }
                Button(loc.t("Detener servidor", "Stop server")) { server.stop() }
            case .starting:
                Text(loc.t("Cargando modelo…", "Loading model…"))
                Button(loc.t("Cancelar", "Cancel")) { server.stop() }
            default:
                Text(loc.t("Servidor detenido", "Server stopped"))
                Button(loc.t("Iniciar servidor", "Start server")) {
                    server.start(.fromDefaults())
                }
                .disabled((UserDefaults.standard.string(forKey: "modelPath") ?? "").isEmpty)
            }

            Divider()

            Button(loc.t("Abrir ToshLLM", "Open ToshLLM")) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            }
            Button(loc.t("Salir", "Quit")) { NSApp.terminate(nil) }
        }
    }
}
