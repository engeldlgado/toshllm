// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum WhisperVADModel {
    static let name = "Silero VAD 6.2"
    static let fileName = "ggml-silero-v6.2.0.bin"
    static let sizeKB = 864
    static let downloadURL = "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin"

    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }
}
