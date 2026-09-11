// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

enum AudioExportFormat: String, CaseIterable, Identifiable {
    case srt, vtt, text, json

    var id: String { rawValue }
    var fileExtension: String { rawValue == "text" ? "txt" : rawValue }
}
