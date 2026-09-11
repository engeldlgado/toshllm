// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Charts

// MARK: - Main window: the chat

/// Selection state of the configuration window, shared so the chat's
/// shortcut buttons can land on a specific section before opening it.
@MainActor
final class ControlPanelState: ObservableObject {
    @Published var section: Section_ = .dashboard
    @Published var settingsAnchor: SettingsAnchor?
    @Published var serverAnchor: UUID?
    @Published var serverNavigationID = UUID()

    func focusServer(_ id: UUID) {
        section = .dashboard
        serverAnchor = id
        serverNavigationID = UUID()
    }

    func visibleServers(from servers: [ServerController]) -> [ServerController] {
        guard let serverAnchor else { return servers }
        return servers.filter { $0.id == serverAnchor }
    }

    func openSettings(_ anchor: SettingsAnchor) {
        settingsAnchor = anchor
        section = anchor == .chat ? .chatSettings : .settings
    }
}

enum SettingsAnchor: Hashable {
    case chat
}

/// Top-level mode of the main window: the chat, or the image studio.
enum MainMode: String { case chat, images, video, audio }

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
    @StateObject private var imageGenPool = ImageGenPool()
    @StateObject private var videoGenPool = VideoGenPool()
    @StateObject private var audioStudio = AudioStudioController.shared
    @StateObject private var upscaler = ImageUpscaler()
    @AppStorage(SettingsKeys.appAccent) private var accentRaw = AppTheme.defaultKey
    @AppStorage(SettingsKeys.chatFontScale) private var chatFontScale = 1.0
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        // A single NavigationSplitView for both modes: only the sidebar and detail
        // content swap, so the window chrome stays put and Chat/Images doesn't jump.
        NavigationSplitView {
            Group {
                if mode == .images {
                    ImageControls(pool: imageGenPool, upscaler: upscaler).transition(.opacity)
                } else if mode == .video {
                    VideoControls(pool: videoGenPool).transition(.opacity)
                } else if mode == .audio {
                    AudioControls(studio: audioStudio).transition(.opacity)
                } else {
                    ConversationListView().transition(.opacity)
                }
            }
        } detail: {
            Group {
                if mode == .images {
                    ImageCanvas(pool: imageGenPool, upscaler: upscaler).transition(.opacity)
                } else if mode == .video {
                    VideoCanvas(pool: videoGenPool).transition(.opacity)
                } else if mode == .audio {
                    AudioCanvas(studio: audioStudio).transition(.opacity)
                } else {
                    chatDetail.transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.2), value: mode)
        .tint(AppTheme.accent(accentRaw))
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                windowBackdropColor
                    .opacity(0.93)
            }
            .ignoresSafeArea()
        }
        .background {
            ChatWindowConfigurator()
                .frame(width: 0, height: 0)
        }
        .environmentObject(chat)
        .environment(\.chatFontScale, ChatFont.clamp(chatFontScale))
        .background {
            // ⌘= as well as ⌘+, since the unshifted key is what most keyboards send;
            // the rest are in the View menu, where they are discoverable
            Button("") { chatFontScale = ChatFont.clamp(chatFontScale + ChatFont.step) }
                .keyboardShortcut("=", modifiers: .command)
                .opacity(0)
        }
        .navigationTitle("")
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) { toolbarIdentity }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .principal) { modePicker }
                    .sharedBackgroundVisibility(.hidden)
                toolbarActions
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { toolbarIdentity }
                ToolbarItem(placement: .principal) { modePicker }
                toolbarActions
            }
        }
        .hiddenChatToolbarBackground()
        .onAppear {
            imageGenPool.modelStore = models
            videoGenPool.modelStore = models
            models.refreshIfNeeded()
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

    private var chatDetail: some View {
        NativeChatView()
    }

    private var windowBackdropColor: Color {
        colorScheme == .dark
            ? Color(red: 19 / 255, green: 19 / 255, blue: 20 / 255)
            : Color(red: 245 / 255, green: 245 / 255, blue: 248 / 255)
    }

    private var toolbarIdentity: some View {
        HStack(spacing: 7) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .foregroundStyle(Color.appAccent)
            Text("ToshLLM")
                .font(.system(size: 12, weight: .semibold))
            Circle()
                .fill(serverStateColor)
                .frame(width: 7, height: 7)
                .accessibilityLabel(modeSubtitle)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .glassSurface(in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .help(modeSubtitle)
    }

    private var serverStateColor: Color {
        switch server.state {
        case .running: .green
        case .starting: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }

    /// Chat / Images switch, front and center in the title bar.
    private var modePicker: some View {
        HStack(spacing: 14) {
            modeButton(.chat, title: loc.t("Chat", "Chat"), icon: "bubble.left.and.bubble.right")
            modeButton(.images, title: loc.t("Imágenes", "Images"), icon: "photo.on.rectangle.angled")
            modeButton(.video, title: loc.t("Vídeo", "Video"), icon: "play.circle")
            modeButton(.audio, title: "Audio", icon: "waveform")
        }
        .fixedSize()
        .help(loc.t("Cambia entre chat, imágenes, vídeo y audio.",
                    "Switch between chat, images, video, and audio."))
    }

    private func modeButton(_ value: MainMode, title: String, icon: String) -> some View {
        Button {
            mode = value
        } label: {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(GlassIconButtonStyle(active: mode == value))
        .help(title)
        .accessibilityAddTraits(mode == value ? .isSelected : [])
    }

    @ToolbarContentBuilder private var toolbarActions: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            GPUUsageBadge()
                .padding(.horizontal, 9)
                .frame(height: 28)
                .glassSurface(in: Capsule())
        }
        ToolbarItemGroup(placement: .automatic) {
            if let version = updates.latestVersion {
                Button {
                    openControl(.dashboard)
                } label: {
                    Label(loc.t("Actualización", "Update"), systemImage: "arrow.down.app.fill")
                        .foregroundStyle(Color.appAccent)
                }
                .help(loc.t("ToshLLM %@ disponible... instálala desde Configuración → Inicio.",
                            "ToshLLM %@ available... install it from Configuration → Home.", version))
            }
            ServerWebUIButton(server: server, presentation: .icon)
                .buttonStyle(GlassIconButtonStyle())
                .disabled(mode != .chat)
            Button {
                openControl()
            } label: {
                Label(loc.t("Configuración", "Configuration"), systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
                .buttonStyle(GlassIconButtonStyle())
                .keyboardShortcut(",", modifiers: .command)
                .accessibilityLabel(loc.t("Configuración", "Configuration"))
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
                Label(loc.half(msg), systemImage: "exclamationmark.triangle")
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

    private var modeSubtitle: String {
        switch mode {
        case .chat: stateSubtitle
        case .images: loc.t("Imágenes · Experimental", "Images · Experimental")
        case .video: loc.t("Vídeo · Experimental", "Video · Experimental")
        case .audio: loc.t("Audio · Whisper GPU", "Audio · Whisper GPU")
        }
    }
}
