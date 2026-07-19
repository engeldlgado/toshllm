import SwiftUI
import Charts

// MARK: - Main window: the chat

/// Selection state of the configuration window, shared so the chat's
/// shortcut buttons can land on a specific section before opening it.
@MainActor
final class ControlPanelState: ObservableObject {
    @Published var section: Section_ = .dashboard
}

/// Top-level mode of the main window: the chat, or the image studio.
enum MainMode: String { case chat, images }

struct ChatMainView: View {
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var models: ModelStore
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var updates: UpdateChecker
    @EnvironmentObject var control: ControlPanelState
    @Environment(\.openWindow) private var openWindow
    @StateObject private var chat = ChatStore()
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""
    @AppStorage(SettingsKeys.routerMode) private var routerMode = false
    @AppStorage(SettingsKeys.chatSelectedModel) private var chatSelectedModel = ""
    @AppStorage(SettingsKeys.onboardingDone) private var onboardingDone = false
    @State private var showOnboarding = false
    @State private var mode: MainMode = .chat
    // One pool shared across the studio's sidebar (controls) and detail
    // (canvas): it owns every generation instance and its generator, so both
    // halves of the split view drive the same runs.
    @StateObject private var imageGenPool = ImageGenPool()
    @AppStorage(SettingsKeys.appAccent) private var accentRaw = AppTheme.defaultKey

    var body: some View {
        // A single NavigationSplitView for both modes: only the sidebar and detail
        // content swap, so the window chrome stays put and Chat/Images doesn't jump.
        NavigationSplitView {
            Group {
                if mode == .images {
                    ImageControls(pool: imageGenPool).transition(.opacity)
                } else {
                    ConversationListView().transition(.opacity)
                }
            }
        } detail: {
            Group {
                if mode == .images {
                    ImageCanvas(pool: imageGenPool).transition(.opacity)
                } else {
                    chatDetail.transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.2), value: mode)
        .tint(AppTheme.accent(accentRaw))
        .environmentObject(chat)
        .navigationTitle("ToshLLM")
        .navigationSubtitle(mode == .images
                            ? loc.t("Imágenes · Experimental", "Images · Experimental")
                            : stateSubtitle)
        .toolbar {
            ToolbarItem(placement: .principal) { modePicker }
            toolbarActions
        }
        .onAppear {
            imageGenPool.modelStore = models
            models.refresh()
            if !onboardingDone && models.models.isEmpty {
                showOnboarding = true
            }
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
        .sheet(item: $server.dflashWarning) { warning in
            DflashMemoryWarningSheet(
                warning: warning,
                useAutomatic: server.useAutomaticDflashAndRestart,
                disable: server.disableDflashAndRestart,
                continueAnyway: server.acknowledgeDflashWarning)
        }
    }

    @ViewBuilder private var chatDetail: some View {
        switch server.state {
        case .running:  NativeChatView()
        case .starting: loadingView
        default:        setupHero
        }
    }

    /// Chat / Images switch, front and center in the title bar.
    private var modePicker: some View {
        Picker("", selection: $mode) {
            Label(loc.t("Chat", "Chat"), systemImage: "bubble.left.and.bubble.right").tag(MainMode.chat)
            Label(loc.t("Imágenes", "Images"), systemImage: "photo.on.rectangle.angled").tag(MainMode.images)
        }
        .pickerStyle(.segmented).labelStyle(.titleAndIcon).fixedSize()
        .help(loc.t("Cambia entre el chat y la generación de imágenes.",
                    "Switch between chat and image generation."))
    }

    /// Web chat, config and the optional update badge. The web link only applies
    /// to the chat, so it's disabled outside chat mode.
    @ToolbarContentBuilder private var toolbarActions: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            GPUUsageBadge()
                .padding(.leading, 12)
        }
        ToolbarItemGroup(placement: .automatic) {
            if let version = updates.latestVersion {
                Button {
                    openControl(.dashboard)
                } label: {
                    Label(loc.t("Actualización", "Update"), systemImage: "arrow.down.app.fill")
                        .foregroundStyle(Color.appAccent)
                }
                .help(loc.t("ToshLLM \(version) disponible... instálala desde Configuración → Inicio.",
                            "ToshLLM \(version) available... install it from Configuration → Home."))
            }
            Button {
                NSWorkspace.shared.open(server.webChatURL)
            } label: { Image(systemName: "safari") }
                .disabled(server.state != .running || mode == .images)
                .help(loc.t("Abrir el chat web en el navegador", "Open the web chat in the browser"))
            Button {
                openControl()
            } label: { Image(systemName: "gearshape") }
                .keyboardShortcut(",", modifiers: .command)
                .help(loc.t("Configuración: modelos, motor, benchmarks y ajustes (⌘,)",
                            "Configuration: models, engine, benchmarks and settings (⌘,)"))
        }
    }

    private func openControl(_ section: Section_? = nil) {
        if let section { control.section = section }
        openWindow(id: "control")
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(loc.t("Cargando modelo…", "Loading model…")).foregroundStyle(.secondary)
            Button(loc.t("Cancelar", "Cancel")) { server.stop() }
                .help(loc.t("Detiene la carga del modelo.", "Stops loading the model."))
        }
    }

    /// Welcome state when the engine is not running: one obvious action to
    /// get chatting, plus shortcuts into the configuration window.
    private var setupHero: some View {
        VStack(spacing: 18) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 44)).foregroundStyle(Color.appAccent)
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
        if routerMode, server.state == .running {
            guard !chatSelectedModel.isEmpty,
                  let m = models.models.first(where: { ServerSettings.routerAlias(for: $0.url.path) == chatSelectedModel })
            else { return loc.t("Router: elige un modelo", "Router: pick a model") }
            return URL(fileURLWithPath: m.url.path).deletingPathExtension().lastPathComponent
        }
        let model = URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
        switch server.state {
        case .running: return model.isEmpty ? loc.t("Activo", "Running") : model
        case .starting: return loc.t("Cargando modelo…", "Loading model…")
        case .failed: return loc.t("Error — revisa Configuración", "Error — see Configuration")
        case .stopped: return loc.t("Servidor detenido", "Server stopped")
        }
    }
}
