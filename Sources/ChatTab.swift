import SwiftUI
import Charts

// MARK: - Main window: the chat

/// Selection state of the configuration window, shared so the chat's
/// shortcut buttons can land on a specific section before opening it.
@MainActor
final class ControlPanelState: ObservableObject {
    @Published var section: Section_ = .dashboard
}

struct ChatMainView: View {
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var updates: UpdateChecker
    @EnvironmentObject var control: ControlPanelState
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""
    @AppStorage(SettingsKeys.onboardingDone) private var onboardingDone = false
    @State private var showOnboarding = false

    var body: some View {
        Group {
            switch server.state {
            case .running:
                NativeChatView()
            case .starting:
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text(loc.t("Cargando modelo…", "Loading model…")).foregroundStyle(.secondary)
                    Button(loc.t("Cancelar", "Cancel")) { server.stop() }
                        .help(loc.t("Detiene la carga del modelo.", "Stops loading the model."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                setupHero
            }
        }
        .navigationTitle("ToshLLM")
        .navigationSubtitle(stateSubtitle)
        .toolbar {
            if let version = updates.latestVersion {
                Button {
                    openControl(.dashboard)
                } label: {
                    Label(loc.t("Actualización", "Update"), systemImage: "arrow.down.app.fill")
                        .foregroundStyle(.pink)
                }
                .help(loc.t("ToshLLM \(version) disponible — instálala desde Configuración → Inicio.",
                            "ToshLLM \(version) available — install it from Configuration → Home."))
            }
            Button {
                NSWorkspace.shared.open(server.serverURL)
            } label: { Image(systemName: "safari") }
                .disabled(server.state != .running)
                .help(loc.t("Abrir el chat web en el navegador", "Open the web chat in the browser"))
            Button {
                openControl()
            } label: { Image(systemName: "gearshape") }
                .keyboardShortcut(",", modifiers: .command)
                .help(loc.t("Configuración: modelos, motor, benchmarks y ajustes (⌘,)",
                            "Configuration: models, engine, benchmarks and settings (⌘,)"))
        }
        .onAppear {
            models.refresh()
            if !onboardingDone && models.models.isEmpty {
                showOnboarding = true
            }
            // Auto-start the server when enabled
            if UserDefaults.standard.bool(forKey: SettingsKeys.autoStart),
               server.state == .stopped,
               !(UserDefaults.standard.string(forKey: SettingsKeys.modelPath) ?? "").isEmpty {
                server.start(.fromDefaults())
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingSheet {
                onboardingDone = true
                showOnboarding = false
                openControl(.models)
            } onDismiss: {
                onboardingDone = true
                showOnboarding = false
            }
        }
    }

    private func openControl(_ section: Section_? = nil) {
        if let section { control.section = section }
        openWindow(id: "control")
    }

    /// Welcome state when the engine is not running: one obvious action to
    /// get chatting, plus shortcuts into the configuration window.
    private var setupHero: some View {
        VStack(spacing: 18) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 44)).foregroundStyle(.pink)
            Text(modelPath.isEmpty
                 ? loc.t("Empieza descargando un modelo", "Start by downloading a model")
                 : loc.t("Todo listo para conversar", "Ready to chat"))
                .font(.title2.weight(.semibold))
            if case .failed(let msg) = server.state {
                Label(msg, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: 480)
            } else {
                Text(modelPath.isEmpty
                     ? loc.t("El catálogo te marca cuáles caben en tu equipo; con un clic quedan configurados.",
                             "The catalog marks which models fit your machine; one click configures them.")
                     : loc.t("Inicia el modelo configurado y escribe tu primer mensaje.",
                             "Start the configured model and type your first message."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                if modelPath.isEmpty {
                    Button {
                        openControl(.models)
                    } label: {
                        Label(loc.t("Descargar un modelo", "Download a model"), systemImage: "shippingbox")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .help(loc.t("Abre el catálogo de modelos con estimaciones para tu hardware.",
                                "Opens the model catalog with estimates for your hardware."))
                } else {
                    Button {
                        server.start(.fromDefaults())
                    } label: {
                        Label(loc.t("Iniciar servidor", "Start server"), systemImage: "play.fill")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .help(loc.t("Carga el modelo configurado y deja el chat listo.",
                                "Loads the configured model and gets the chat ready."))
                    Button {
                        openControl(.models)
                    } label: {
                        Label(loc.t("Modelos", "Models"), systemImage: "shippingbox")
                    }
                    .controlSize(.large)
                    .help(loc.t("Cambiar de modelo o descargar otros.",
                                "Switch models or download more."))
                }
                Button {
                    openControl(.settings)
                } label: {
                    Label(loc.t("Ajustes", "Settings"), systemImage: "slider.horizontal.3")
                }
                .controlSize(.large)
                .help(loc.t("Parámetros del motor: contexto, memoria, GPU.",
                            "Engine parameters: context, memory, GPU."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Window subtitle with the engine state and loaded model, the native way
    /// to show document status on macOS. Full telemetry lives in Configuration.
    private var stateSubtitle: String {
        let model = URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
        switch server.state {
        case .running: return model.isEmpty ? loc.t("Activo", "Running") : model
        case .starting: return loc.t("Cargando modelo…", "Loading model…")
        case .failed: return loc.t("Error — revisa Configuración", "Error — see Configuration")
        case .stopped: return loc.t("Servidor detenido", "Server stopped")
        }
    }
}
