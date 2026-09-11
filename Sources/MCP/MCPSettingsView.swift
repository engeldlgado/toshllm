// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct MCPSettingsSection: View {
    @EnvironmentObject private var loc: Localizer
    @State private var servers: [MCPServer] = []
    @State private var editing: MCPServer?
    @State private var testingID: UUID?
    @State private var status: [UUID: String] = [:]
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                    .glassButton()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(WorkspaceStyle.border)
                    .allowsHitTesting(false))
            } else {
                SettingsRowGroup {
                ForEach($servers) { $server in
                    HStack(spacing: 10) {
                        Toggle(isOn: $server.enabled) { EmptyView() }
                            .labelsHidden()
                            .onChange(of: server.enabled) { persist() }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name).font(.callout.weight(.medium))
                            Text(server.addressLabel).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            if let message = status[server.id] {
                                Text(message).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if testingID == server.id { ProgressView().controlSize(.small) }
                        Button(loc.t("Probar", "Test"), systemImage: "stethoscope") {
                            test(server)
                        }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(loc.t("Probar conexión", "Test connection"))
                        Button(loc.t("Editar", "Edit"), systemImage: "pencil") { editing = server }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        Button(loc.t("Eliminar", "Delete"), systemImage: "trash", role: .destructive) {
                            delete(server)
                        }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                }
            }
            HStack(spacing: 8) {
                if !servers.isEmpty {
                    Button(loc.t("Añadir servidor MCP", "Add MCP server"), systemImage: "plus") {
                        editing = MCPServer(name: "MCP", url: "http://127.0.0.1:3000/mcp")
                    }
                    .glassButton()
                }
                Button(loc.t("Importar configuración…", "Import configuration…"), systemImage: "doc.on.clipboard") {
                    importing = true
                }
                .glassButton()
                .help(loc.t("Pega el bloque \"mcpServers\" que usan otros clientes MCP y se añaden todos de una vez.",
                            "Paste the \"mcpServers\" block other MCP clients use and they are all added at once."))
            }
            Text(loc.t("Las cabeceras de autenticación se guardan en el Llavero de macOS. Las herramientas MCP usan la misma autorización por llamada que las herramientas locales.",
                       "Authentication headers are stored in the macOS Keychain. MCP tools use the same per-call permission flow as local tools."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { servers = MCPServerStore.load() }
        .sheet(isPresented: $importing) {
            MCPConfigImportSheet { imported in
                for server in imported {
                    if let index = servers.firstIndex(where: { $0.name == server.name }) {
                        servers[index] = server
                    } else {
                        servers.append(server)
                    }
                }
                persist()
            }
            .environmentObject(loc)
        }
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
                    ? loc.t("Conectado · %@ herramientas", "Connected · %@ tools", "\(count)")
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
                TextField(loc.t("Nombre", "Name"), text: $server.name).workspaceTextField()
                Picker(loc.t("Transporte", "Transport"), selection: $server.transport) {
                    Text(loc.t("Automático", "Automatic")).tag(MCPTransport.automatic)
                    Text(loc.t("Local (stdio)", "Local (stdio)")).tag(MCPTransport.stdio)
                    Text("Streamable HTTP").tag(MCPTransport.streamableHTTP)
                    Text("SSE").tag(MCPTransport.serverSentEvents)
                    Text("WebSocket").tag(MCPTransport.webSocket)
                }
                .help(loc.t("'Local (stdio)' lanza un programa de tu equipo y habla con él por sus tuberías, que es como corre la mayoría de servidores MCP locales. Los demás se conectan a una URL.",
                            "'Local (stdio)' launches a program on your machine and talks to it over its pipes, which is how most local MCP servers run. The rest connect to a URL."))
                if server.transport.isLocal {
                    TextField(loc.t("Comando", "Command"), text: $server.command).workspaceTextField()
                        .help(loc.t("Ruta del ejecutable, o su nombre si está en el PATH.",
                                    "Path to the executable, or its name when it is on the PATH."))
                    TextField(loc.t("Argumentos (uno por línea)", "Arguments (one per line)"), text: argumentsText, axis: .vertical)
                        .workspaceTextField().lineLimit(2...5)
                        .help(loc.t("Cada argumento en su propia línea, para que los que llevan espacios no se partan.",
                                    "One argument per line, so the ones containing spaces stay whole."))
                    TextField(loc.t("Carpeta de trabajo (opcional)", "Working directory (optional)"),
                              text: $server.workingDirectory).workspaceTextField()
                } else {
                    TextField("URL", text: $server.url).workspaceTextField()
                }
                Stepper(loc.t("Timeout: %@ s", "Timeout: %@ s", "\(server.timeoutSeconds)"),
                        value: $server.timeoutSeconds, in: 5...600, step: 5)
                if !server.transport.isLocal {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(loc.t("Cabeceras HTTP (JSON, opcional)", "HTTP headers (optional JSON)"))
                        TextEditor(text: $headers)
                            .font(.system(.caption, design: .monospaced)).frame(height: 90)
                            .workspaceFieldSurface()
                        Text(#"{"Authorization":"Bearer …"}"#)
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            if server.transport.isLocal {
                Label(loc.t("Este servidor se ejecuta en tu equipo con tus permisos. Añade solo programas en los que confíes.",
                            "This server runs on your machine with your permissions. Only add programs you trust."),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
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

    private var argumentsText: Binding<String> {
        Binding(get: { server.arguments.joined(separator: "\n") },
                set: { server.arguments = $0.split(separator: "\n").map(String.init).filter { !$0.isEmpty } })
    }

    private func validateAndSave() {
        if server.transport.isLocal {
            server.command = server.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !server.command.isEmpty else {
                validationError = loc.t("Indica el programa que hay que lanzar.", "Name the program to launch.")
                return
            }
            server.name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
            save(server, "")
            dismiss()
            return
        }
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

private struct MCPConfigImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var loc: Localizer
    @State private var text = ""
    @State private var error: String?
    let add: ([MCPServer]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc.t("Importar servidores MCP", "Import MCP servers")).font(.title2.weight(.semibold))
            Text(loc.t("Pega la configuración que usan otros clientes MCP. Se admiten servidores locales (comando) y remotos (URL).",
                       "Paste the configuration other MCP clients use. Local servers (a command) and remote ones (a url) are both accepted."))
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 210).workspaceFieldSurface()
            Text(#"{"mcpServers":{"memory":{"command":"/usr/local/bin/server","args":["--project-path","/ruta"]}}}"#)
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(loc.t("Cancelar", "Cancel")) { dismiss() }
                Button(loc.t("Importar", "Import")) { load() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22).frame(width: 560)
    }

    private func load() {
        do {
            add(try MCPConfigImport.servers(fromJSON: text))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
