import XCTest
@testable import ToshLLM

final class BenchmarkShareReviewTests: XCTestCase {
    func testReviewExtractsReadableBenchmarkSummaryWithoutChangingExactJSON() throws {
        let object: [String: Any] = [
            "model": [
                "displayName": "Qwen3.5 9B",
                "quantization": "Q4_K_M",
                "family": "dense",
                "artifacts": [["fileName": "model.gguf", "sha256": String(repeating: "a", count: 64), "sizeBytes": 5_000_000_000]],
            ],
            "hardware": [
                "cpu": "Intel CPU", "memoryBytes": 34_359_738_368,
                "machineModel": "MacPro7,1", "osVersion": "macOS 26",
                "gpus": [["name": "AMD Radeon", "vramBytes": 12_884_901_888]],
            ],
            "configuration": [
                "workloadId": "pp512-tg128", "promptTokens": 512, "generatedTokens": 128,
                "repetitions": 3, "contextDepth": 0, "gpuLayers": 99, "cpuMoeExperts": 0,
                "cacheTypeK": "q8_0", "cacheTypeV": "f16", "backend": "Metal", "flashAttention": "amd-gpu",
            ],
            "measurements": [
                "promptTokensPerSecond": [403.3, 415.0, 414.4],
                "generationTokensPerSecond": [45.8, 46.9, 46.5],
            ],
            "evidence": ["rawOutput": "benchmark output", "engineSha256": String(repeating: "b", count: 64)],
            "app": ["version": "0.82.3", "build": "823"],
        ]
        let payload = try JSONSerialization.data(withJSONObject: object)
        let review = BenchmarkShareReview(payload: payload, keyFingerprint: "fingerprint")

        XCTAssertEqual(review.modelName, "Qwen3.5 9B")
        XCTAssertEqual(review.promptMedian, 414.4, accuracy: 0.001)
        XCTAssertEqual(review.generationMedian, 46.5, accuracy: 0.001)
        XCTAssertEqual(review.artifacts.first?.name, "model.gguf")
        XCTAssertEqual(review.rawOutput, "benchmark output")
        XCTAssertEqual(review.exactJSON, String(data: payload, encoding: .utf8))
        XCTAssertFalse(review.formattedJSON.contains("benchmark output"))
    }
}
