// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The panel beside the settings form. It is its own view so the artwork and the
/// per-category copy are not rebuilt every time an unrelated setting changes.
struct SettingsCategoryGuide: View {
    let destination: SettingsDestination

    @EnvironmentObject private var loc: Localizer

    var body: some View {
        let content = categoryGuideContent

        ZStack {
            SettingsGuideArtwork()
            LinearGradient(colors: [Color.black.opacity(0.18),
                                    Color.black.opacity(0.58),
                                    WorkspaceStyle.surface.opacity(0.94)],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: content.icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 44, height: 44)
                    .background(Color.appAccent.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.appAccent.opacity(0.22)))
                VStack(alignment: .leading, spacing: 7) {
                    Text(content.title).font(.title2.weight(.bold))
                    Text(content.detail)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 13) {
                    ForEach(categoryGuideItems) { item in
                        HStack(alignment: .center, spacing: 11) {
                            Image(systemName: item.icon)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.appAccent)
                                .frame(width: 32, height: 32)
                                .background(Color.appAccent.opacity(0.11),
                                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.callout.weight(.semibold))
                                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Spacer(minLength: 8)
                Label(content.note, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.16),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(WorkspaceStyle.border.opacity(0.8)))
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    private struct GuideItem: Identifiable {
        let icon: String
        let title: String
        let detail: String
        var id: String { title }
    }

    private var categoryGuideItems: [GuideItem] {
        switch destination {
        case .general:
            return [
                .init(icon: "desktopcomputer", title: loc.t("Interfaz", "Interface"), detail: loc.t("Idioma, color y barra de menús.", "Language, color, and menu bar.")),
                .init(icon: "gearshape", title: loc.t("Inicio", "Startup"), detail: loc.t("Arranque, actualizaciones y comportamiento.", "Launch, updates, and behavior.")),
                .init(icon: "shield", title: loc.t("Seguridad", "Security"), detail: loc.t("Protege tu API y tus datos.", "Keep your API and data safe.")),
                .init(icon: "shippingbox", title: loc.t("Biblioteca", "Library"), detail: loc.t("Elige dónde viven tus modelos.", "Choose where your models live."))
            ]
        case .models:
            return [
                .init(icon: "doc.text", title: loc.t("Perfiles", "Profiles"), detail: loc.t("Guarda configuraciones para reutilizarlas.", "Save configurations for reuse.")),
                .init(icon: "memorychip", title: "GPU", detail: loc.t("Elige una tarjeta o reparte el modelo.", "Choose a card or split the model.")),
                .init(icon: "externaldrive", title: loc.t("Memoria", "Memory"), detail: loc.t("Controla VRAM, RAM y cachés.", "Control VRAM, RAM, and caches.")),
                .init(icon: "point.3.connected.trianglepath.dotted", title: "Multi-GPU", detail: loc.t("Configura capas, tensores y enlaces.", "Configure layers, tensors, and links."))
            ]
        case .inference:
            return [
                .init(icon: "text.document", title: loc.t("Contexto", "Context"), detail: loc.t("Ajusta el límite de tokens.", "Set the token limit.")),
                .init(icon: "square.stack.3d.up", title: loc.t("Caché KV", "KV cache"), detail: loc.t("Equilibra precisión y memoria.", "Balance precision and memory.")),
                .init(icon: "bolt", title: "Flash Attention", detail: loc.t("Usa el kernel adecuado para tu GPU.", "Use the right kernel for your GPU.")),
                .init(icon: "arrow.triangle.branch", title: loc.t("Concurrencia", "Concurrency"), detail: loc.t("Controla solicitudes y plantilla de chat.", "Control requests and chat templates."))
            ]
        case .speech:
            return [
                .init(icon: "mic", title: loc.t("Entrada", "Input"), detail: loc.t("Elige dictado de Apple o Whisper.", "Choose Apple Dictation or Whisper.")),
                .init(icon: "waveform", title: "Whisper.cpp", detail: loc.t("Transcripción acelerada por GPU.", "GPU-accelerated transcription.")),
                .init(icon: "arrow.down.circle", title: loc.t("Carga", "Loading"), detail: loc.t("Bajo demanda o siempre disponible.", "On demand or always available.")),
                .init(icon: "lock.shield", title: loc.t("Privacidad", "Privacy"), detail: loc.t("Audio y texto permanecen en tu Mac.", "Audio and text stay on your Mac."))
            ]
        case .advanced:
            return [
                .init(icon: "server.rack", title: loc.t("Motor", "Engine"), detail: loc.t("Usa el integrado o uno externo.", "Use the bundled or an external engine.")),
                .init(icon: "network", title: loc.t("API y red", "API & network"), detail: loc.t("Configura puerto y acceso local.", "Configure port and local access.")),
                .init(icon: "point.3.connected.trianglepath.dotted", title: "Embeddings", detail: loc.t("Expone servicios para clientes RAG.", "Expose services for RAG clients.")),
                .init(icon: "terminal", title: loc.t("Diagnóstico", "Diagnostics"), detail: loc.t("Argumentos adicionales y registro.", "Additional arguments and logs."))
            ]
        }
    }

    private var categoryGuideContent: (icon: String, title: String, detail: String, note: String) {
        switch destination {
        case .general:
            return ("paintbrush",
                    loc.t("Personaliza tu experiencia", "Personalize your experience"),
                    loc.t("Ajusta la interfaz, el inicio, la seguridad y dónde vive tu biblioteca local.",
                          "Adjust the interface, startup, security, and where your local library lives."),
                    loc.t("Estos cambios afectan la aplicación y su comportamiento al abrirse.",
                          "These settings affect the application and its startup behavior."))
        case .models:
            return ("memorychip",
                    loc.t("Modelos, GPU y memoria", "Models, GPU, and memory"),
                    loc.t("Guarda configuraciones y decide cómo cargar pesos, expertos y modelos entre tus GPUs.",
                          "Save configurations and decide how weights, experts, and models load across your GPUs."),
                    loc.t("Los cambios del motor se aplican al reiniciar el servidor.",
                          "Engine changes take effect after restarting the server."))
        case .inference:
            return ("square.stack.3d.up",
                    loc.t("Inferencia y contexto", "Inference and context"),
                    loc.t("Configura contexto, caché KV, Flash Attention, concurrencia y comportamiento del chat.",
                          "Configure context, KV cache, Flash Attention, concurrency, and chat behavior."),
                    loc.t("Un contexto mayor y cachés de más precisión requieren más RAM o VRAM.",
                          "Longer context and higher-precision caches require more RAM or VRAM."))
        case .speech:
            return ("waveform",
                    loc.t("Voz local, control completo", "Local voice, full control"),
                    loc.t("Configura la entrada de audio, la carga de Whisper y el perfil de transcripción.",
                          "Configure audio input, Whisper loading, and the transcription profile."),
                    loc.t("El audio y el texto permanecen en este Mac.",
                          "Audio and text stay on this Mac."))
        case .advanced:
            return ("wrench.and.screwdriver",
                    loc.t("Servicios y motor", "Services and engine"),
                    loc.t("Controla el puerto, el motor externo, embeddings, caché persistente y argumentos adicionales.",
                          "Control the port, external engine, embeddings, persistent cache, and extra arguments."),
                    loc.t("Usa argumentos adicionales solo cuando conozcas la opción de llama.cpp que necesitas.",
                          "Use extra arguments only when you know which llama.cpp option you need."))
        }
    }
}
