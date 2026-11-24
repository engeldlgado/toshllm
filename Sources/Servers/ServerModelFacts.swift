// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What the server page asks about the selected model. Several answers list the model's
/// folder, so they are gathered once per model instead of on every redraw.
struct ServerModelFacts: Equatable {
    let modelPath: String
    let isMoE: Bool
    let supportsVision: Bool
    let usesMTP: Bool
    let offersMTP: Bool
    let hasDflashDraft: Bool
    let supportsTurboKV: Bool
    let trainedContext: Int?
    let contextChoices: [Int]

    init(modelPath: String) {
        self.modelPath = modelPath
        isMoE = ServerSettings.modelIsMoE(at: modelPath)
        supportsVision = ServerSettings.mightSupportVision(modelPath: modelPath)
        usesMTP = ServerSettings.modelUsesMTP(at: modelPath)
        offersMTP = usesMTP || ServerSettings.modelOffersMTP(at: modelPath)
        hasDflashDraft = ServerSettings.dflashDraftPath(forModel: modelPath) != nil
        supportsTurboKV = !ServerSettings.isAppleSilicon && ServerSettings.modelSupportsTurboKV(at: modelPath)
        trainedContext = GGUFMetadataCache.metadata(at: modelPath)?.trainedContext
        contextChoices = ServerSettings.contextChoices(modelPath: modelPath, from: 8192)
    }
}
