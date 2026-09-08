// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

enum ChatSettingsDestination: Hashable {
    case general, sampling, agents, advanced, mcp
}

struct ChatSettingsView: View {
    @EnvironmentObject private var loc: Localizer
    @State private var destination: ChatSettingsDestination = .general

    var body: some View {
        VStack(spacing: 0) {
            navigation
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            content
        }
    }

    private var navigation: some View {
        HStack(spacing: 14) {
            GlassSegmentedControl(selection: $destination, segments: [
                .init(value: .general, title: loc.t("General", "General"), systemImage: "bubble.left.and.bubble.right"),
                .init(value: .sampling, title: loc.t("Muestreo", "Sampling"), systemImage: "dial.medium"),
                .init(value: .agents, title: loc.t("Agentes", "Agents"), systemImage: "hammer"),
                .init(value: .advanced, title: loc.t("Avanzado", "Advanced"), systemImage: "slider.horizontal.3"),
                .init(value: .mcp, title: "MCP", systemImage: "point.3.connected.trianglepath.dotted")
            ])
            Spacer(minLength: 16)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider().opacity(0.65)
            GeometryReader { proxy in
                HStack(alignment: .top, spacing: 0) {
                    form.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if proxy.size.width >= 930 {
                        Divider().opacity(0.65)
                        SettingsCategoryGuide(content: guideContent)
                            .frame(width: 340)
                            .frame(maxHeight: .infinity)
                    }
                }
            }
        }
        .background(WorkspaceStyle.surface.opacity(0.72),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(WorkspaceStyle.border)
            .allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

    private var panelHeader: some View {
        HStack(spacing: 12) {
            SectionGlyph(systemName: panelCopy.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(panelCopy.title).font(.headline)
                Text(panelCopy.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if destination == .mcp {
                    MCPSettingsSection()
                } else {
                    ChatAdvancedSettingsSection(destination: destination)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var panelCopy: (icon: String, title: String, subtitle: String) {
        switch destination {
        case .general:
            return ("bubble.left.and.bubble.right", loc.t("Conversación", "Conversation"),
                    loc.t("Comportamiento del chat, texto y prompt de sistema.",
                          "Chat behavior, text, and system prompt."))
        case .sampling:
            return ("dial.medium", loc.t("Muestreo", "Sampling"),
                    loc.t("Cómo elige el modelo cada palabra.", "How the model picks each word."))
        case .agents:
            return ("hammer", loc.t("Agentes y adjuntos", "Agents and attachments"),
                    loc.t("Herramientas, memoria y archivos que el modelo puede usar.",
                          "Tools, memory, and files the model can use."))
        case .advanced:
            return ("slider.horizontal.3", loc.t("Avanzado", "Advanced"),
                    loc.t("Peticiones personalizadas para el motor.",
                          "Custom requests for the engine."))
        case .mcp:
            return ("point.3.connected.trianglepath.dotted", "MCP",
                    loc.t("Servidores de herramientas externas.", "External tool servers."))
        }
    }

    private var guideContent: SettingsGuideContent {
        switch destination {
        case .general:
            return .init(icon: "bubble.left.and.bubble.right",
                         title: loc.t("Ajusta tu conversación", "Tune your conversation"),
                         detail: loc.t("Controla cómo se comporta el chat, cómo se ve el texto y qué instrucciones recibe el modelo por defecto.",
                                       "Control how the chat behaves, how the text looks, and what instructions the model gets by default."),
                         note: loc.t("Los cambios se aplican al siguiente mensaje que envíes.",
                                     "Changes apply to the next message you send."),
                         items: [
                            .init(icon: "arrow.down.right.and.arrow.up.left", title: loc.t("Contexto", "Context"),
                                  detail: loc.t("Resume lo viejo para seguir hablando.", "Summarize old turns to keep talking.")),
                            .init(icon: "textformat.size", title: loc.t("Lectura", "Reading"),
                                  detail: loc.t("Tamaño del texto del chat.", "Chat text size.")),
                            .init(icon: "text.quote", title: loc.t("Instrucciones", "Instructions"),
                                  detail: loc.t("Prompt de sistema para todo el chat.", "System prompt for every chat.")),
                            .init(icon: "clock.arrow.circlepath", title: loc.t("Historial", "History"),
                                  detail: loc.t("Borra todas las conversaciones.", "Delete every conversation."))
                         ])
        case .sampling:
            return .init(icon: "dial.medium",
                         title: loc.t("Cómo escribe el modelo", "How the model writes"),
                         detail: loc.t("Estos valores deciden cuánto arriesga el modelo al elegir cada palabra y cuánto se repite.",
                                       "These values decide how much the model gambles on each word and how much it repeats itself."),
                         note: loc.t("Si algo se desmadra, restaura los valores por defecto en Avanzado.",
                                     "If something goes wild, reset to defaults in Advanced."),
                         items: [
                            .init(icon: "dial.medium", title: loc.t("Muestreo", "Sampling"),
                                  detail: loc.t("Top P, Min P, Top K y semilla.", "Top P, Min P, Top K, and seed.")),
                            .init(icon: "arrow.uturn.backward", title: loc.t("Penalizaciones", "Penalties"),
                                  detail: loc.t("Evita que se repita.", "Keep it from repeating.")),
                            .init(icon: "thermometer.medium", title: loc.t("Temperatura", "Temperature"),
                                  detail: loc.t("Rango dinámico y XTC.", "Dynamic range and XTC.")),
                            .init(icon: "waveform.path", title: "DRY",
                                  detail: loc.t("Corta bucles largos de texto.", "Cuts long text loops."))
                         ])
        case .agents:
            return .init(icon: "hammer",
                         title: loc.t("Lo que el modelo puede hacer", "What the model can do"),
                         detail: loc.t("Herramientas para leer archivos, ejecutar código y recordar lo hablado, más cómo se tratan los adjuntos.",
                                       "Tools to read files, run code, and remember what was said, plus how attachments are handled."),
                         note: loc.t("Cada operación sensible pide permiso antes de ejecutarse.",
                                     "Every sensitive operation asks for permission first."),
                         items: [
                            .init(icon: "hammer", title: loc.t("Herramientas", "Tools"),
                                  detail: loc.t("Leer, editar y ejecutar.", "Read, edit, and run.")),
                            .init(icon: "shippingbox", title: loc.t("Aislamiento", "Isolation"),
                                  detail: loc.t("Ejecútalas fuera de tu Mac.", "Run them off your Mac.")),
                            .init(icon: "brain.head.profile", title: loc.t("Memoria", "Memory"),
                                  detail: loc.t("Archiva y recupera turnos.", "Archive and recall turns.")),
                            .init(icon: "paperclip", title: loc.t("Adjuntos", "Attachments"),
                                  detail: loc.t("Imágenes y PDF que envías.", "Images and PDFs you send."))
                         ])
        case .advanced:
            return .init(icon: "slider.horizontal.3",
                         title: loc.t("Para casos concretos", "For specific cases"),
                         detail: loc.t("Reemplaza los parámetros con tu propio JSON y conecta servidores MCP para ampliar las herramientas del chat.",
                                       "Override the parameters with your own JSON and connect MCP servers to extend the chat's tools."),
                         note: loc.t("Un JSON inválido se ignora hasta que lo corrijas.",
                                     "Invalid JSON is ignored until you fix it."),
                         items: [
                            .init(icon: "curlybraces", title: loc.t("Petición", "Request"),
                                  detail: loc.t("JSON que manda sobre lo demás.", "JSON that wins over the rest.")),
                            .init(icon: "arrow.counterclockwise", title: loc.t("Restaurar", "Reset"),
                                  detail: loc.t("Vuelve a los valores por defecto.", "Back to the defaults."))
                         ])
        case .mcp:
            return .init(icon: "point.3.connected.trianglepath.dotted",
                         title: loc.t("Herramientas de otros servidores", "Tools from other servers"),
                         detail: loc.t("Conecta servidores MCP para que el chat use sus herramientas junto a las locales.",
                                       "Connect MCP servers so the chat can use their tools alongside the local ones."),
                         note: loc.t("Las herramientas MCP piden permiso igual que las locales.",
                                     "MCP tools ask for permission just like local ones."),
                         items: [
                            .init(icon: "plus.circle", title: loc.t("Servidores", "Servers"),
                                  detail: loc.t("Añade uno por su dirección.", "Add one by its address.")),
                            .init(icon: "key", title: loc.t("Credenciales", "Credentials"),
                                  detail: loc.t("Se guardan en el Llavero.", "Stored in the Keychain.")),
                            .init(icon: "hammer", title: loc.t("Herramientas", "Tools"),
                                  detail: loc.t("Se suman a las del chat.", "Added to the chat's own.")),
                            .init(icon: "lock.shield", title: loc.t("Permisos", "Permissions"),
                                  detail: loc.t("Autorización por llamada.", "Per-call authorization."))
                         ])
        }
    }
}
