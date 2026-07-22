import SwiftUI

struct MCPSettingsSection: View {
    @EnvironmentObject private var loc: Localizer
    @State private var servers: [MCPServer] = []
    @State private var editing: MCPServer?
    @State private var testingID: UUID?
    @State private var status: [UUID: String] = [:]

    var body: some View {
        Section("MCP") {
            if servers.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(loc.t("Sin servidores MCP", "No MCP servers"))
                            .font(.callout.weight(.medium))
                        Text(loc.t("Añade un servidor para usar sus herramientas en el chat.",
                                   "Add a server to use its tools in chat."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(loc.t("Añadir", "Add"), systemImage: "plus") {
                        editing = MCPServer(name: "MCP", url: "http://127.0.0.1:3000/mcp")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 6)
            } else {
                ForEach($servers) { $server in
                    HStack(spacing: 10) {
                        Toggle(isOn: $server.enabled) { EmptyView() }
                            .labelsHidden()
                            .onChange(of: server.enabled) { persist() }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name).font(.callout.weight(.medium))
                            Text(server.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if let message = status[server.id] {
                                Text(message).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if testingID == server.id { ProgressView().controlSize(.small) }
                        Button(loc.t("Probar", "Test"), systemImage: "stethoscope") {
                            test(server)
                        }
                        .labelStyle(.iconOnly).help(loc.t("Probar conexión", "Test connection"))
                        Button(loc.t("Editar", "Edit"), systemImage: "pencil") { editing = server }
                            .labelStyle(.iconOnly)
                        Button(loc.t("Eliminar", "Delete"), systemImage: "trash", role: .destructive) {
                            delete(server)
                        }
                        .labelStyle(.iconOnly)
                    }
                }
            }
            if !servers.isEmpty {
                Button(loc.t("Añadir servidor MCP", "Add MCP server"), systemImage: "plus") {
                    editing = MCPServer(name: "MCP", url: "http://127.0.0.1:3000/mcp")
                }
            }
            Text(loc.t("Las cabeceras de autenticación se guardan en el Llavero de macOS. Las herramientas MCP usan la misma autorización por llamada que las herramientas locales.",
                       "Authentication headers are stored in the macOS Keychain. MCP tools use the same per-call permission flow as local tools."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { servers = MCPServerStore.load() }
        .sheet(item: $editing) { server in
            MCPServerEditor(server: server) { updated, headers in
                if let index = servers.firstIndex(where: { $0.id == updated.id }) {
                    servers[index] = updated
                } else {
                    servers.append(updated)
                }
                if headers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Keychain.delete(updated.credentialAccount)
                } else {
                    Keychain.set(headers, account: updated.credentialAccount)
                }
                persist()
                Task { await ToshMCPService.shared.disconnect(updated.id) }
            }
            .environmentObject(loc)
        }
    }

    private func persist() { MCPServerStore.save(servers) }

    private func delete(_ server: MCPServer) {
        servers.removeAll { $0.id == server.id }
        MCPServerStore.deleteCredentials(for: server)
        persist()
        Task { await ToshMCPService.shared.disconnect(server.id) }
    }

    private func test(_ server: MCPServer) {
        testingID = server.id
        status[server.id] = loc.t("Conectando…", "Connecting…")
        Task {
            await ToshMCPService.shared.disconnect(server.id)
            let tools = await ToshMCPService.shared.discoverTools()
            await MainActor.run {
                testingID = nil
                let count = tools.filter { $0.mcpServerID == server.id }.count
                status[server.id] = count > 0
                    ? loc.t("Conectado · \(count) herramientas", "Connected · \(count) tools")
                    : loc.t("Sin herramientas o conexión fallida; revisa el registro.",
                            "No tools or connection failed; check the log.")
            }
        }
    }
}

private struct MCPServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var loc: Localizer
    @State private var server: MCPServer
    @State private var headers: String
    @State private var validationError: String?
    let save: (MCPServer, String) -> Void

    init(server: MCPServer, save: @escaping (MCPServer, String) -> Void) {
        _server = State(initialValue: server)
        _headers = State(initialValue: Keychain.get(server.credentialAccount) ?? "")
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(loc.t("Servidor MCP", "MCP server")).font(.title2.weight(.semibold))
            Form {
                TextField(loc.t("Nombre", "Name"), text: $server.name)
                TextField("URL", text: $server.url)
                Picker(loc.t("Transporte", "Transport"), selection: $server.transport) {
                    Text(loc.t("Automático", "Automatic")).tag(MCPTransport.automatic)
                    Text("Streamable HTTP").tag(MCPTransport.streamableHTTP)
                    Text("SSE").tag(MCPTransport.serverSentEvents)
                    Text("WebSocket").tag(MCPTransport.webSocket)
                }
                Stepper(loc.t("Timeout: \(server.timeoutSeconds) s", "Timeout: \(server.timeoutSeconds) s"),
                        value: $server.timeoutSeconds, in: 5...600, step: 5)
                VStack(alignment: .leading, spacing: 5) {
                    Text(loc.t("Cabeceras HTTP (JSON, opcional)", "HTTP headers (optional JSON)"))
                    TextEditor(text: $headers)
                        .font(.system(.caption, design: .monospaced)).frame(height: 90)
                    Text(#"{"Authorization":"Bearer …"}"#)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if let validationError { Text(validationError).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(loc.t("Cancelar", "Cancel")) { dismiss() }
                Button(loc.t("Guardar", "Save")) { validateAndSave() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 520)
    }

    private func validateAndSave() {
        guard let url = URL(string: server.url), let scheme = url.scheme?.lowercased(),
              ["http", "https", "ws", "wss"].contains(scheme) else {
            validationError = loc.t("Introduce una URL MCP válida.", "Enter a valid MCP URL.")
            return
        }
        let trimmed = headers.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            guard let data = trimmed.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                validationError = loc.t("Las cabeceras deben ser un objeto JSON.",
                                        "Headers must be a JSON object.")
                return
            }
        }
        server.name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        server.url = server.url.trimmingCharacters(in: .whitespacesAndNewlines)
        save(server, trimmed)
        dismiss()
    }
}
