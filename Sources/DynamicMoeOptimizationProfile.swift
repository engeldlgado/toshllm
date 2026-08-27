// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct DynamicMoeOptimizationProfile: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let modelFingerprint: String
    let modelName: String
    let gpuName: String
    let gpuVRAMMB: Int
    let route: DynamicMoeExecutionRoute
    let slots: Int
    let ringSlots: Int
    let prefetch: Int
    let hotMapPath: String?
    let promptTokensPerSecond: Double
    let generationTokensPerSecond: Double
    let baselinePromptTokensPerSecond: Double
    let baselineGenerationTokensPerSecond: Double
    let estimatedVRAMFraction: Double?
    let createdAt: Date
}
