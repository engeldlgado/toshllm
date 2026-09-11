// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

enum AudioStudioStage: Equatable {
    case idle
    case preparing
    case analyzingVAD
    case transcribing
    case translating
    case completed
    case failed(String)
}
