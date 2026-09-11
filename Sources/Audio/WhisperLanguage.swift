// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

struct WhisperLanguage: Identifiable, Hashable {
    let id: String
    let es: String
    let en: String

    static let common: [WhisperLanguage] = [
        .init(id: "auto", es: "Detectar automáticamente", en: "Detect automatically"),
        .init(id: "es", es: "Español", en: "Spanish"),
        .init(id: "en", es: "Inglés", en: "English"),
        .init(id: "fr", es: "Francés", en: "French"),
        .init(id: "de", es: "Alemán", en: "German"),
        .init(id: "it", es: "Italiano", en: "Italian"),
        .init(id: "pt", es: "Portugués", en: "Portuguese"),
        .init(id: "ja", es: "Japonés", en: "Japanese"),
        .init(id: "ko", es: "Coreano", en: "Korean"),
        .init(id: "zh", es: "Chino", en: "Chinese"),
        .init(id: "ru", es: "Ruso", en: "Russian")
    ]
}
