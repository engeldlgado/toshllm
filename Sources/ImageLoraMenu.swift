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
                Divider()
                Text(loc.t("LCM y Turbo: pocos pasos y guía cerca de 1.5",
                           "LCM and Turbo: few steps and guidance near 1.5"))
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
        .help(loc.t("Añade un LoRA al prompt. El peso se puede editar en la etiqueta. Los LoRA de tipo LCM o Turbo piden además pocos pasos y una guía baja, cerca de 1.5, o la imagen sale quemada.",
                    "Adds a LoRA to the prompt. The weight can be edited in the tag. LCM and Turbo LoRAs also want few steps and a low guidance, around 1.5, or the image comes out burnt."))
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
