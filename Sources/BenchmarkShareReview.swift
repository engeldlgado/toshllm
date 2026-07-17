import Foundation

struct BenchmarkShareReview {
    let exactJSON: String
    let formattedJSON: String
    let payloadByteCount: Int
    let rawOutput: String
    let keyFingerprint: String

    let modelName: String
    let quantization: String
    let family: String
    let contributor: String
    let artifacts: [BenchmarkShareArtifact]

    let promptRuns: [Double]
    let generationRuns: [Double]
    let promptMedian: Double
    let generationMedian: Double

    let workloadID: String
    let promptTokens: Int
    let generatedTokens: Int
    let repetitions: Int
    let contextDepth: Int

    let gpu: String
    let cpu: String
    let memory: String
    let machine: String
    let operatingSystem: String
    let backend: String
    let flashAttention: String
    let gpuLayers: Int
    let cpuMoeExperts: Int
    let cacheTypes: String
    let appVersion: String

    init(payload: Data, keyFingerprint: String) {
        let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
        let model = Self.dictionary(root["model"])
        let hardware = Self.dictionary(root["hardware"])
        let configuration = Self.dictionary(root["configuration"])
        let measurements = Self.dictionary(root["measurements"])
        let evidence = Self.dictionary(root["evidence"])
        let app = Self.dictionary(root["app"])
        let contributorObject = Self.dictionary(root["contributor"])

        exactJSON = String(data: payload, encoding: .utf8) ?? ""
        payloadByteCount = payload.count
        rawOutput = Self.string(evidence["rawOutput"])
        self.keyFingerprint = keyFingerprint

        modelName = Self.string(model["displayName"])
        quantization = Self.string(model["quantization"])
        family = Self.string(model["family"])
        contributor = Self.string(contributorObject["displayName"])
        artifacts = Self.artifacts(model["artifacts"])

        promptRuns = Self.doubles(measurements["promptTokensPerSecond"])
        generationRuns = Self.doubles(measurements["generationTokensPerSecond"])
        promptMedian = Self.median(promptRuns)
        generationMedian = Self.median(generationRuns)

        workloadID = Self.string(configuration["workloadId"])
        promptTokens = Self.integer(configuration["promptTokens"])
        generatedTokens = Self.integer(configuration["generatedTokens"])
        repetitions = Self.integer(configuration["repetitions"])
        contextDepth = Self.integer(configuration["contextDepth"])

        gpu = Self.gpuSummary(hardware["gpus"])
        cpu = Self.string(hardware["cpu"])
        memory = Self.byteCount(hardware["memoryBytes"])
        machine = Self.string(hardware["machineModel"])
        operatingSystem = Self.string(hardware["osVersion"])
        backend = Self.string(configuration["backend"])
        flashAttention = Self.string(configuration["flashAttention"])
        gpuLayers = Self.integer(configuration["gpuLayers"])
        cpuMoeExperts = Self.integer(configuration["cpuMoeExperts"])
        cacheTypes = "K: \(Self.string(configuration["cacheTypeK"])) · V: \(Self.string(configuration["cacheTypeV"]))"
        appVersion = "\(Self.string(app["version"])) (\(Self.string(app["build"])))"

        var readableRoot = root
        var readableEvidence = evidence
        readableEvidence["rawOutput"] = "[Shown separately in Benchmark log: \(rawOutput.utf8.count) UTF-8 bytes]"
        readableRoot["evidence"] = readableEvidence
        let readableData = try? JSONSerialization.data(
            withJSONObject: readableRoot,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        formattedJSON = readableData.flatMap { String(data: $0, encoding: .utf8) } ?? exactJSON
    }

    private static func dictionary(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private static func string(_ value: Any?) -> String {
        value as? String ?? ""
    }

    private static func integer(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    private static func doubles(_ value: Any?) -> [Double] {
        (value as? [NSNumber])?.map(\.doubleValue) ?? []
    }

    private static func artifacts(_ value: Any?) -> [BenchmarkShareArtifact] {
        guard let values = value as? [[String: Any]] else { return [] }
        return values.map {
            BenchmarkShareArtifact(
                name: string($0["fileName"]),
                sha256: string($0["sha256"]),
                sizeBytes: ($0["sizeBytes"] as? NSNumber)?.int64Value ?? 0
            )
        }
    }

    private static func gpuSummary(_ value: Any?) -> String {
        guard let values = value as? [[String: Any]] else { return "" }
        return values.map {
            let name = string($0["name"])
            let size = byteCount($0["vramBytes"])
            return size.isEmpty ? name : "\(name) · \(size) VRAM"
        }.joined(separator: " + ")
    }

    private static func byteCount(_ value: Any?) -> String {
        guard let number = value as? NSNumber else { return "" }
        return ByteCountFormatter.string(fromByteCount: number.int64Value, countStyle: .memory)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
