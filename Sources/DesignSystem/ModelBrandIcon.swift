// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct ModelBrandIcon: View {
    let name: String
    var size: CGFloat = 38

    var body: some View {
        Group {
            if let key = Self.key(for: name), let image = Self.images[key] {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "cube.transparent.fill")
                    .resizable().scaledToFit().padding(size * 0.15)
                    .foregroundStyle(Color.appAccent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25))
        .accessibilityHidden(true)
    }

    private static func key(for name: String) -> String? {
        let name = name.lowercased()
        let families: [(String, [String])] = [
            ("qwen", ["qwen", "qwq"]), ("glm", ["glm", "zhipu"]),
            ("gemma", ["gemma"]), ("llama", ["llama"]),
            ("mistral", ["mistral", "mixtral", "pixtral", "ministral", "devstral"]),
            ("openai", ["gpt-oss", "gpt oss"]), ("deepseek", ["deepseek"]),
            ("phi", ["phi-"]), ("smol", ["smollm", "smolvlm"])
        ]
        return families.first { $0.1.contains(where: name.contains) }?.0
    }

    /// Loaded once per process; token streaming never causes disk or network reads.
    private static let images: [String: NSImage] = {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("model-icons")
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Assets/model-icons")
        var images: [String: NSImage] = [:]
        for key in ["qwen", "glm", "gemma", "llama", "mistral", "openai", "deepseek", "phi", "smol"] {
            let urls = [bundled, development].compactMap { $0?.appendingPathComponent(key + ".webp") }
            images[key] = urls.lazy.compactMap { NSImage(contentsOf: $0) }.first
        }
        return images
    }()
}
