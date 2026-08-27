// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum BenchmarkModelFamilyClassifier {
    static func family(for model: LocalModel) -> String {
        if let metadata = GGUFMetadataCache.metadata(at: model.url.path) {
            if metadata.isMoE { return "moe" }
            if metadata.uint32(forSuffix: "expert_count") != nil
                || metadata.string(for: "general.architecture")?.isEmpty == false {
                return "dense"
            }
            return "unknown"
        }
        return ModelName.looksMoE(model.name) ? "moe" : "unknown"
    }
}
