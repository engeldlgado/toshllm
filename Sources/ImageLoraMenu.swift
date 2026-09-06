import SwiftUI

/// Inserts a `<lora:file:weight>` tag into the prompt. The engine reads the tag and loads the
/// file from the lora folder, so the menu writes text rather than holding state of its own.
struct ImageLoraMenu: View {
    @Binding var prompt: String
    @EnvironmentObject var loc: Localizer

    @State private var files: [URL] = []

    var body: some View {
        Menu {
            if files.isEmpty {
                Text(loc.t("Pon los archivos en la carpeta lora de imagen",
                           "Put the files in the image lora folder"))
            } else {
                ForEach(files, id: \.self) { file in
                    Button(file.deletingPathExtension().lastPathComponent) { insert(file) }
                }
            }
            Divider()
            Button(loc.t("Abrir la carpeta", "Open the folder"), systemImage: "folder") {
                let dir = ImageGenPool.loraDirectory()
                    ?? ServerSettings.modelsDirectory
                        .appendingPathComponent("imagen", isDirectory: true)
                        .appendingPathComponent("lora", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(dir)
            }
        } label: {
            Label("LoRA", systemImage: "slider.horizontal.below.square.filled.and.square")
        }
        .help(loc.t("Añade un LoRA al prompt. El peso se puede editar en la etiqueta.",
                    "Adds a LoRA to the prompt. The weight can be edited in the tag."))
        .task { refresh() }
        .onChange(of: prompt) { _, _ in }
    }

    private func refresh() {
        files = ImageGenPool.loraDirectory().map { ImageGenPool.loraFiles(in: $0) } ?? []
    }

    private func insert(_ file: URL) {
        let tag = "<lora:\(file.deletingPathExtension().lastPathComponent):0.8>"
        if prompt.isEmpty { prompt = tag }
        else if !prompt.hasSuffix(" ") { prompt += " " + tag }
        else { prompt += tag }
    }
}
