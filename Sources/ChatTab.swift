import SwiftUI
import Charts

// MARK: - Chat

struct ChatTabView: View {
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var loc: Localizer
    @AppStorage(SettingsKeys.modelPath) private var modelPath = ""

    var body: some View {
        VStack(spacing: 0) {
            StatsBar()
            switch server.state {
            case .running:
                NativeChatView()
                    .toolbar {
                        Button {
                            NSWorkspace.shared.open(server.serverURL)
                        } label: { Image(systemName: "safari") }
                            .help(loc.t("Abrir el chat web en el navegador", "Open the web chat in the browser"))
                    }
            case .starting:
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text(loc.t("Cargando modelo…", "Loading model…")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                VStack(spacing: 16) {
                    Image(systemName: "bolt.slash")
                        .font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text(loc.t("Servidor detenido", "Server stopped"))
                        .font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                    if modelPath.isEmpty {
                        Text(loc.t("Selecciona un modelo en la pestaña Modelos y vuelve aquí.",
                                   "Pick a model in the Models tab, then come back here."))
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            server.start(.fromDefaults())
                        } label: {
                            Label(loc.t("Iniciar servidor", "Start server"), systemImage: "play.fill")
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
