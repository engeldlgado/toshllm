// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import ToshLLM
final class FamilyGroupTests: XCTestCase {
    func testFamilyAndSize() {
        let cases: [(String, String, Double?)] = [
            ("Qwen3-8B-Q4_K_M.gguf", "Qwen", 8),
            ("Qwen3-0.6B-Q4_0.gguf", "Qwen", 0.6),
            ("Qwen3-30B-A3B-Q4_0.gguf", "Qwen", 30),
            ("Qwen2.5-VL-7B-Instruct.Q4_K_M.gguf", "Qwen", 7),
            ("QwQ-32B-Q4_K_M.gguf", "Qwen", 32),
            ("Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf", "Llama", 8),
            ("TinyLlama-1.1B-Chat-Q8_0.gguf", "Llama", 1.1),
            ("glm-4-9b-chat-Q4_K_M.gguf", "GLM", 9),
            ("gemma-4-26B-A4B-it-MXFP4_MOE.gguf", "Gemma", 26),
            ("gemma-3n-E4B-it-Q4_K_M.gguf", "Gemma", 4),
            ("Mixtral-8x7B-Instruct-Q4_K_M.gguf", "Mistral", 56),
            ("DeepSeek-V4-Flash-Q4_K.gguf", "DeepSeek", nil),
            ("Phi-4-14B-Q4_K_M.gguf", "Phi", 14),
            ("gpt-oss-20b-MXFP4.gguf", "GPT-OSS", 20),
            ("OLMoE-1B-7B-Q4_0.gguf", "OLMo", 7),
            ("Mistral-Small-4-24B-Instruct-Q4_K_M.gguf", "Mistral", 24),
            ("Ministral-8B-Instruct-Q4_K_M.gguf", "Mistral", 8),
            ("granite-4.0-h-small-32B-Q4_K_M.gguf", "Granite", 32),
            ("Kimi-K3-Instruct-Q2_K.gguf", "Kimi", nil),
            ("MiniCPM4-8B-Q4_K_M.gguf", "MiniCPM", 8),
            ("GLM-4.6-Air-106B-A12B-Q4_K_M.gguf", "GLM", 106),
            ("Falcon-H1-34B-Instruct-Q4_K_M.gguf", "Falcon", 34),
            ("LFM2-2.6B-Q8_0.gguf", "LFM", 2.6),
            ("SmolLM3-3B-Q4_K_M.gguf", "SmolLM", 3),
            ("Seed-OSS-36B-Instruct-Q4_K_M.gguf", "Seed", 36),
            ("Apertus-8B-Instruct-Q4_K_M.gguf", "Apertus", 8),
            ("FableVibes-14B-Q4_K_M.gguf", "Others", 14),
            ("SomeRandomFinetune-7B-Q4_K_M.gguf", "Others", 7),
        ]
        for (file, family, params) in cases {
            let n = ModelName(file)
            XCTAssertEqual(n.family, family, "family of \(file)")
            if let params {
                XCTAssertEqual(n.paramsB ?? -1, params, accuracy: 0.001, "params of \(file)")
            }
        }
    }
}
