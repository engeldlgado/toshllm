// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct AudioProjectDocument: Codable, Sendable {
    let version: Int
    let savedAt: Date
    let sourcePath: String
    let detectedLanguage: String
    let targetLanguage: String
    let translationModel: String
    let glossary: String
    let originalCues: [SubtitleCue]
    let translatedCues: [SubtitleCue]
}
