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
        VStack(spacing: 0) {
            sheetHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsRowGroup {
                        SettingsRow(icon: "tag", title: loc.t("Nombre", "Name")) {
                            TextField(loc.t("Nombre del servidor", "Server name"), text: $server.name)
                                .workspaceTextField(width: 310)
                        }
                        SettingsRow(icon: "point.3.connected.trianglepath.dotted",
                                    title: loc.t("Transporte", "Transport"),
                                    help: transportHelp) {
                            ToshDropdown(selection: $server.transport,
                                         options: transportOptions,
                                         width: 310,
                                         maximumListHeight: 250)
                        }
                        if server.transport.isLocal {
                            SettingsRow(icon: "terminal", title: loc.t("Comando", "Command"),
                                        help: loc.t("Ruta del ejecutable, o su nombre si está en el PATH.",
                                                    "Path to the executable, or its name when it is on the PATH.")) {
                                TextField("/usr/local/bin/server", text: $server.command)
                                    .font(.system(.caption, design: .monospaced))
                                    .workspaceTextField(width: 310)
                            }
                            SettingsRow(icon: "folder", title: loc.t("Carpeta de trabajo", "Working directory"),
                                        subtitle: loc.t("Opcional", "Optional")) {
                                TextField("/path/to/project", text: $server.workingDirectory)
                                    .font(.system(.caption, design: .monospaced))
                                    .workspaceTextField(width: 310)
                            }
                        } else {
                            SettingsRow(icon: "link", title: "URL") {
                                TextField("http://127.0.0.1:3000/mcp", text: $server.url)
                                    .font(.system(.caption, design: .monospaced))
                                    .workspaceTextField(width: 310)
                            }
                        }
                        SettingsRow(icon: "clock", title: loc.t("Tiempo de espera", "Timeout"),
                                    subtitle: loc.t("Entre 5 y 600 segundos", "Between 5 and 600 seconds")) {
                            timeoutControl
                        }
                    }

                    if server.transport.isLocal { localArgumentsCard } else { headersCard }

                    if server.transport.isLocal {
                        notice(loc.t("Este servidor se ejecuta en tu equipo con tus permisos. Añade solo programas en los que confíes.",
                                     "This server runs on your machine with your permissions. Only add programs you trust."),
                               icon: "exclamationmark.triangle", color: .orange)
                    }
                    if let validationError {
                        notice(validationError, icon: "exclamationmark.circle", color: .red)
                    }
                }
                .padding(18)
            }
            .frame(height: server.transport.isLocal ? 440 : 360)

            Divider()
            footer
        }
        .frame(width: 610)
        .background(WorkspaceStyle.canvas)
    }

    private var sheetHeader: some View {
        HStack(spacing: 13) {
            SectionGlyph(systemName: "point.3.connected.trianglepath.dotted")
            VStack(alignment: .leading, spacing: 3) {
                Text(loc.t("Servidor MCP", "MCP server"))
                    .font(.title3.weight(.semibold))
                Text(loc.t("Conecta herramientas locales o remotas con el chat.",
                           "Connect local or remote tools to Chat."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(WorkspaceStyle.surface)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(loc.t("Cancelar", "Cancel")) { dismiss() }
                .glassButton()
                .keyboardShortcut(.cancelAction)
            Button(loc.t("Guardar", "Save"), systemImage: "checkmark") { validateAndSave() }
                .glassButton(prominent: true)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(WorkspaceStyle.surface)
    }

    private var transportOptions: [ToshDropdown<MCPTransport>.Option] {
        [
            .init(value: .automatic, title: loc.t("Automático", "Automatic"),
                  subtitle: loc.t("Detecta el protocolo", "Detects the protocol"), systemImage: "wand.and.stars"),
            .init(value: .stdio, title: loc.t("Local (stdio)", "Local (stdio)"),
                  subtitle: loc.t("Ejecuta un programa local", "Runs a local program"), systemImage: "terminal"),
            .init(value: .streamableHTTP, title: "Streamable HTTP", systemImage: "network"),
            .init(value: .serverSentEvents, title: "SSE", systemImage: "dot.radiowaves.left.and.right"),
            .init(value: .webSocket, title: "WebSocket", systemImage: "arrow.left.arrow.right"),
        ]
    }

    private var transportHelp: String {
        loc.t("«Local (stdio)» ejecuta un programa del equipo y se comunica por sus tuberías. Los demás transportes se conectan a una URL.",
              "“Local (stdio)” runs a program on this Mac and communicates over its pipes. The other transports connect to a URL.")
    }

    private var timeoutControl: some View {
        HStack(spacing: 8) {
            Button { server.timeoutSeconds = max(5, server.timeoutSeconds - 5) } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(GlassIconButtonStyle())
            .disabled(server.timeoutSeconds <= 5)
            .iconHelp(loc.t("Reducir tiempo de espera", "Decrease timeout"))
            Text("\(server.timeoutSeconds) s")
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .frame(width: 58)
            Button { server.timeoutSeconds = min(600, server.timeoutSeconds + 5) } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(GlassIconButtonStyle())
            .disabled(server.timeoutSeconds >= 600)
            .iconHelp(loc.t("Aumentar tiempo de espera", "Increase timeout"))
        }
    }

    private var localArgumentsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(loc.t("Argumentos", "Arguments"), systemImage: "list.bullet.rectangle")
                .font(.callout.weight(.semibold))
            Text(loc.t("Uno por línea; los argumentos con espacios permanecen completos.",
                       "One per line; arguments containing spaces stay intact."))
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: argumentsText)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 92)
                .workspaceFieldSurface()
        }
        .padding(14)
        .cardSurface()
    }

    private var headersCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(loc.t("Cabeceras HTTP", "HTTP headers"), systemImage: "lock.shield")
                .font(.callout.weight(.semibold))
            Text(loc.t("Objeto JSON opcional. Las credenciales se guardan en el Llavero de macOS.",
                       "Optional JSON object. Credentials are stored in the macOS Keychain."))
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $headers)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 96)
                .workspaceFieldSurface()
            Text(#"{"Authorization":"Bearer …"}"#)
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .cardSurface()
    }

    private func notice(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(color.opacity(0.22)))
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
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                SectionGlyph(systemName: "doc.on.clipboard")
                VStack(alignment: .leading, spacing: 3) {
                    Text(loc.t("Importar servidores MCP", "Import MCP servers"))
                        .font(.title3.weight(.semibold))
                    Text(loc.t("Admite servidores locales y remotos.", "Supports local and remote servers."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .background(WorkspaceStyle.surface)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text(loc.t("Pega el bloque de configuración «mcpServers» de otro cliente MCP.",
                           "Paste the “mcpServers” configuration block from another MCP client."))
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 220).workspaceFieldSurface()
                Text(#"{"mcpServers":{"memory":{"command":"/usr/local/bin/server","args":["--project-path","/ruta"]}}}"#)
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                if let error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            .padding(18)

            Divider()

            HStack(spacing: 10) {
                Spacer()
                Button(loc.t("Cancelar", "Cancel")) { dismiss() }
                    .glassButton().keyboardShortcut(.cancelAction)
                Button(loc.t("Importar", "Import"), systemImage: "square.and.arrow.down") { load() }
                    .glassButton(prominent: true).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(WorkspaceStyle.surface)
        }
        .frame(width: 590)
        .background(WorkspaceStyle.canvas)
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
