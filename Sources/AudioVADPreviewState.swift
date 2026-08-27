// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

enum AudioVADPreviewState: Equatable {
    case idle
    case running
    case ready(segmentCount: Int, speechSeconds: Double, sampleSeconds: Double)
    case failed(String)
}
