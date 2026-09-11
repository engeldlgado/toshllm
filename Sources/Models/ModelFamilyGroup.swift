// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One section of a model picker: a maker's models, smallest first.
struct ModelFamilyGroup: Identifiable, Sendable {
    let family: String
    let models: [LocalModel]
    var id: String { family }
    var isOther: Bool { family == ModelName.otherFamily }

    static func grouped(_ models: [LocalModel]) -> [ModelFamilyGroup] {
        let parsed = models.map { (model: $0, name: ModelName.forPath($0.url.path)) }
        return Dictionary(grouping: parsed, by: { $0.name.family })
            .map { family, entries in
                ModelFamilyGroup(family: family, models: entries.sorted {
                    // Unlabelled sizes sink to the bottom of their family.
                    let a = $0.name.paramsB ?? .greatestFiniteMagnitude
                    let b = $1.name.paramsB ?? .greatestFiniteMagnitude
                    if a != b { return a < b }
                    if $0.model.sizeBytes != $1.model.sizeBytes {
                        return $0.model.sizeBytes < $1.model.sizeBytes
                    }
                    return $0.model.name.localizedCaseInsensitiveCompare($1.model.name) == .orderedAscending
                }.map(\.model))
            }
            .sorted {
                if $0.isOther != $1.isOther { return $1.isOther }
                return $0.family.localizedCaseInsensitiveCompare($1.family) == .orderedAscending
            }
    }
}
