// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct PendingSpeechTranscription: Identifiable {
    let id: UUID
    let fileURL: URL
    let modelURL: URL
    let attachmentID: UUID
    let name: String
}
