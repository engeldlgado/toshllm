import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
    @AppStorage("menuBarIcon") private var menuBarIcon = true

    init() {
        // Release VRAM held by engines orphaned by a previous force-quit.
        ServerSettings.reapOrphanedEngines()

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
        WindowGroup {
            ContentView()
                .environmentObject(server)
                .environmentObject(models)
                .environmentObject(vram)
                .environmentObject(loc)
                .environmentObject(bench)
                .environmentObject(search)
                .environmentObject(profiles)
                .environmentObject(updates)
                .frame(minWidth: 980, minHeight: 640)
                .task { await updates.check() }
        }

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
