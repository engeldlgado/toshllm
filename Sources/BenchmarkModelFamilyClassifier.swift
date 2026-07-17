import Foundation

enum BenchmarkModelFamilyClassifier {
    static func family(for model: LocalModel) -> String {
        if let metadata = GGUFMetadataCache.metadata(at: model.url.path) {
            if let experts = metadata.uint32(forSuffix: "expert_count") {
                return experts > 0 ? "moe" : "dense"
            }
            if let architecture = metadata.string(for: "general.architecture"), !architecture.isEmpty {
                return "dense"
            }
            return "unknown"
        }
        return ModelName.looksMoE(model.name) ? "moe" : "unknown"
    }
}
