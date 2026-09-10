// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AVFoundation

/// Subtitle appearance, previewed over a real frame of the video with the
/// longest caption, which is the one that used to get cut off.
struct SubtitleStyleSheet: View {
    let sourceURL: URL?
    let cues: [SubtitleCue]

    @EnvironmentObject var loc: Localizer
    @Environment(\.dismiss) private var dismiss

    @State private var style = SubtitleStyle.load()
    @State private var frame: NSImage? = nil
    @State private var rendered: NSImage? = nil

    /// The worst case is what you want to look at, not an average one.
    private var sampleText: String {
        cues.max { $0.text.count < $1.text.count }?.text
            ?? loc.t("Un subtítulo de ejemplo, lo bastante largo como para que tenga que partirse en varias líneas y se vea cómo queda.",
                     "A sample caption, long enough that it has to wrap onto several lines so you can see how it lands.")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    preview
                    controls
                }
                .padding(18)
            }
            Divider()
            footer.padding(14)
        }
        .frame(minWidth: 660, idealWidth: 720, minHeight: 600, idealHeight: 720)
        .background(WorkspaceStyle.canvas)
        .task { await loadFrame() }
        .onChange(of: style) { _, _ in render() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "captions.bubble.fill")
                .font(.title2)
                .foregroundStyle(Color.appAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(loc.t("Apariencia de los subtítulos", "Subtitle appearance"))
                    .font(.headline)
                Text(loc.t("Ajusta el resultado sobre un fotograma real del vídeo.",
                           "Adjust the result over a real frame from the video."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(loc.t("Vista previa", "Preview"), systemImage: "play.rectangle")
                .font(.headline)
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.black)
                if let rendered {
                    Image(nsImage: rendered)
                        .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
            .frame(minHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorkspaceStyle.border))
        }
        .padding(14)
        .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(WorkspaceStyle.border))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(loc.t("Estilo", "Style"), systemImage: "slider.horizontal.3")
                .font(.headline)

            settingRow(loc.t("Tipografía", "Typeface")) {
                Picker("", selection: $style.fontName) {
                    ForEach(SubtitleStyle.fontChoices, id: \.name) { Text($0.label).tag($0.name) }
                }
                .labelsHidden()
                .frame(width: 220)
            }
            .help(loc.t("Fuentes que trae macOS y se leen bien sobre imagen en movimiento.",
                        "Faces macOS ships that stay readable over moving pictures."))

            settingRow(loc.t("Tamaño", "Size")) {
                HStack(spacing: 10) {
                    Slider(value: $style.relativeSize, in: 0.02...0.08)
                    Text("\(Int(style.relativeSize * 1000))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                .frame(width: 290)
            }
            .help(loc.t("Proporción del alto del fotograma, así se ve igual en 720p que en 4K.",
                        "A fraction of the frame height, so it reads the same at 720p and at 4K."))

            settingRow(loc.t("Color del texto", "Text colour")) {
                ColorPicker("", selection: Binding(get: { style.textColor.color },
                                                    set: { style.textColor = .init($0) }))
                    .labelsHidden()
            }

            settingRow(loc.t("Fondo", "Background")) {
                GlassSegmentedControl(selection: $style.background, segments: [
                    .init(value: .box, title: loc.t("Caja", "Box")),
                    .init(value: .outline, title: loc.t("Contorno", "Outline")),
                    .init(value: .none, title: loc.t("Ninguno", "None")),
                ])
            }
            .help(loc.t("La caja se lee siempre; el contorno tapa menos imagen.",
                        "The box always reads; the outline covers less of the picture."))

            if style.background != .none {
                settingRow(loc.t("Opacidad", "Opacity")) {
                    Slider(value: $style.backgroundOpacity, in: 0.2...1)
                        .frame(width: 290)
                }
            }

            settingRow(loc.t("Posición", "Position")) {
                GlassSegmentedControl(selection: $style.position, segments: [
                    .init(value: .bottom, title: loc.t("Abajo", "Bottom")),
                    .init(value: .top, title: loc.t("Arriba", "Top")),
                ])
            }

            settingRow(loc.t("Margen", "Margin")) {
                Slider(value: $style.margin, in: 0.01...0.2)
                    .frame(width: 290)
            }

            settingRow(loc.t("Ancho máximo", "Maximum width")) {
                Slider(value: $style.maxWidth, in: 0.5...0.98)
                    .frame(width: 290)
            }
            .help(loc.t("Cuánto del ancho puede ocupar el texto antes de partir de línea.",
                        "How much of the width the text may take before it wraps."))
        }
        .padding(14)
        .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(WorkspaceStyle.border))
    }

    private func settingRow<Content: View>(_ title: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.callout)
            Spacer(minLength: 20)
            content()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
        .background(WorkspaceStyle.field, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(WorkspaceStyle.border))
    }

    private var footer: some View {
        HStack {
            Button(loc.t("Restaurar", "Reset")) { style = .default }
                .glassButton()
                .help(loc.t("Vuelve a la apariencia de fábrica.", "Back to the built-in look."))
            Spacer()
            Button(loc.t("Cancelar", "Cancel")) { dismiss() }
                .glassButton()
                .keyboardShortcut(.cancelAction)
            Button(loc.t("Guardar", "Save")) {
                style.save()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .glassButton(prominent: true)
        }
    }

    private func loadFrame() async {
        guard let sourceURL else { render(); return }
        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // A small still would make the caption look different from the export.
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        // The middle of the clip beats the first frame, which is often black.
        let at = (try? await asset.load(.duration)).map { CMTime(seconds: $0.seconds / 2, preferredTimescale: 600) }
        guard let at, let cg = try? await generator.image(at: at).image else { render(); return }
        frame = NSImage(cgImage: cg, size: .zero)
        render()
    }

    private func render() {
        guard let frame else {
            rendered = SubtitleLayout.preview(text: sampleText, style: style,
                                              over: Self.placeholder)
            return
        }
        rendered = SubtitleLayout.preview(text: sampleText, style: style, over: frame)
    }

    /// Audio-only projects still get to set the look.
    private static let placeholder: NSImage = {
        let size = CGSize(width: 1280, height: 720)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        img.unlockFocus()
        return img
    }()
}
