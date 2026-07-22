import SwiftUI

struct MCPBrowserView: View {
    let addAttachment: (ChatAttachment) -> Void
    let insertPrompt: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var loc: Localizer
    @State private var catalog = MCPCatalog()
    @State private var loading = true
    @State private var error: String?
    @State private var query = ""
    @State private var selectedTab = 0
    @State private var readingID: String?
    @State private var attachedIDs = Set<String>()
    @State private var selectedPrompt: MCPPromptItem?
    @State private var selectedTemplate: MCPResourceTemplateItem?

    private var resources: [MCPResourceItem] {
        catalog.resources.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
            || $0.uri.localizedCaseInsensitiveContains(query) }
    }

    private var prompts: [MCPPromptItem] {
        catalog.prompts.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
            || ($0.description?.localizedCaseInsensitiveContains(query) ?? false) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(loc.t("Contenido MCP", "MCP content")).font(.title2.weight(.semibold))
                Spacer()
                Button(loc.t("Cerrar", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            Picker("", selection: $selectedTab) {
                Text(loc.t("Recursos", "Resources")).tag(0)
                Text(loc.t("Prompts", "Prompts")).tag(1)
            }
            .pickerStyle(.segmented).padding()
            TextField(loc.t("Buscar", "Search"), text: $query, prompt: Text(loc.t("Nombre o URI", "Name or URI")))
                .textFieldStyle(.roundedBorder).padding(.horizontal)
            Group {
                if loading {
                    ProgressView(loc.t("Consultando servidores…", "Loading servers…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                } else if selectedTab == 0 {
                    resourceList
                } else {
                    promptList
                }
            }
        }
        .frame(minWidth: 640, minHeight: 500)
        .task { await load() }
        .sheet(item: $selectedPrompt) { prompt in
            MCPPromptForm(prompt: prompt) { arguments in
                Task {
                    do {
                        let value = try await ToshMCPService.shared.getPrompt(prompt, arguments: arguments)
                        await MainActor.run { insertPrompt(value); dismiss() }
                    } catch {
                        await MainActor.run { self.error = error.localizedDescription }
                    }
                }
            }
            .environmentObject(loc)
        }
        .sheet(item: $selectedTemplate) { template in
            MCPResourceTemplateForm(template: template) { arguments in
                Task {
                    do {
                        let attachment = try await ToshMCPService.shared.readTemplate(
                            template, arguments: arguments)
                        await MainActor.run {
                            addAttachment(attachment)
                            attachedIDs.insert(template.id)
                        }
                    } catch {
                        await MainActor.run { self.error = error.localizedDescription }
                    }
                }
            }
            .environmentObject(loc)
        }
    }

    private var resourceList: some View {
        List {
            Section(loc.t("Recursos", "Resources")) {
                ForEach(resources) { resource in
                    HStack(spacing: 10) {
                Image(systemName: attachedIDs.contains(resource.id) ? "checkmark.circle.fill" : "doc.text")
                    .foregroundStyle(attachedIDs.contains(resource.id) ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(resource.name).font(.callout.weight(.medium))
                    Text(resource.description ?? resource.uri).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text(resource.serverName).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                if readingID == resource.id { ProgressView().controlSize(.small) }
                Button(attachedIDs.contains(resource.id)
                       ? loc.t("Añadido", "Added") : loc.t("Adjuntar", "Attach")) {
                    attach(resource)
                }
                .disabled(readingID != nil || attachedIDs.contains(resource.id))
                    }
                    .padding(.vertical, 3)
                }
            }
            if !catalog.templates.isEmpty {
                Section(loc.t("Plantillas", "Templates")) {
                    ForEach(catalog.templates.filter {
                        query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                            || $0.uriTemplate.localizedCaseInsensitiveContains(query)
                    }) { template in
                        HStack(spacing: 10) {
                            Image(systemName: attachedIDs.contains(template.id)
                                  ? "checkmark.circle.fill" : "doc.badge.gearshape")
                                .foregroundStyle(attachedIDs.contains(template.id) ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.name).font(.callout.weight(.medium))
                                Text(template.description ?? template.uriTemplate)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Text(template.serverName).font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button(loc.t("Usar", "Use")) { selectedTemplate = template }
                                .disabled(attachedIDs.contains(template.id))
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .overlay {
            if resources.isEmpty && catalog.templates.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private var promptList: some View {
        List(prompts) { prompt in
            Button { selectedPrompt = prompt } label: {
                HStack {
                    Image(systemName: "text.quote").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prompt.title ?? prompt.name).font(.callout.weight(.medium))
                        if let description = prompt.description {
                            Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Text(prompt.serverName).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.vertical, 3)
        }
        .overlay { if prompts.isEmpty { ContentUnavailableView.search(text: query) } }
    }

    private func load() async {
        catalog = await ToshMCPService.shared.catalog()
        loading = false
    }

    private func attach(_ resource: MCPResourceItem) {
        readingID = resource.id
        Task {
            do {
                let attachment = try await ToshMCPService.shared.readResource(resource)
                await MainActor.run {
                    addAttachment(attachment)
                    attachedIDs.insert(resource.id)
                    readingID = nil
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; readingID = nil }
            }
        }
    }
}

private struct MCPResourceTemplateForm: View {
    let template: MCPResourceTemplateItem
    let submit: ([String: String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var loc: Localizer
    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(template.name).font(.title3.weight(.semibold))
            Text(template.uriTemplate)
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Form {
                ForEach(template.variables, id: \.self) { variable in
                    TextField(variable, text: Binding(
                        get: { values[variable] ?? "" }, set: { values[variable] = $0 }))
                }
            }
            HStack {
                Spacer()
                Button(loc.t("Cancelar", "Cancel")) { dismiss() }
                Button(loc.t("Adjuntar", "Attach")) { submit(values); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(template.variables.contains { (values[$0] ?? "").isEmpty })
            }
        }
        .padding(22).frame(width: 500)
    }
}

private struct MCPPromptForm: View {
    let prompt: MCPPromptItem
    let submit: ([String: String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var loc: Localizer
    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(prompt.title ?? prompt.name).font(.title3.weight(.semibold))
            if let description = prompt.description { Text(description).foregroundStyle(.secondary) }
            if prompt.arguments.isEmpty {
                Text(loc.t("Este prompt no requiere argumentos.", "This prompt has no arguments."))
            } else {
                Form {
                    ForEach(prompt.arguments) { argument in
                        TextField(argument.name + (argument.required ? " *" : ""),
                                  text: Binding(get: { values[argument.name] ?? "" },
                                                set: { values[argument.name] = $0 }),
                                  prompt: argument.description.map(Text.init))
                    }
                }
            }
            HStack {
                Spacer()
                Button(loc.t("Cancelar", "Cancel")) { dismiss() }
                Button(loc.t("Insertar", "Insert")) { submit(values); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(prompt.arguments.contains { $0.required && (values[$0.name] ?? "").isEmpty })
            }
        }
        .padding(22).frame(width: 480)
    }
}
