import Foundation

struct ModelModalities: Codable, Equatable, Sendable {
    var vision: Bool
    var audio: Bool
    var video: Bool
    var thinking: Bool?

    init(vision: Bool, audio: Bool, video: Bool, thinking: Bool? = nil) {
        self.vision = vision
        self.audio = audio
        self.video = video
        self.thinking = thinking
    }

    static let textOnly = ModelModalities(vision: false, audio: false, video: false)
}

enum ModelCapabilitiesService {
    private struct Props: Decodable {
        let modalities: ModelModalities?
        let chatTemplate: String?

        enum CodingKeys: String, CodingKey {
            case modalities
            case chatTemplate = "chat_template"
        }
    }

    static func fetch(port: Int, model: String?) async throws -> ModelModalities? {
        var components = URLComponents(string: "http://127.0.0.1:\(port)/props")!
        if let model, !model.isEmpty {
            components.queryItems = [
                URLQueryItem(name: "model", value: model),
                URLQueryItem(name: "autoload", value: "false"),
            ]
        }
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        if let key = ServerSettings.activeAPIKey() {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        let props = try JSONDecoder().decode(Props.self, from: data)
        var capabilities = props.modalities ?? .textOnly
        capabilities.thinking = props.chatTemplate.map(ThinkingSupportDetector.supportsThinking)
        capabilities.video = capabilities.video && VideoRuntimeAvailability.isAvailable
        return capabilities
    }
}

enum ThinkingSupportDetector {
    static func supportsThinking(_ template: String) -> Bool {
        guard !template.isEmpty else { return false }
        let lowered = template.lowercased()
        for variable in ["enable_thinking", "reasoning_effort", "thinking_budget"]
        where lowered.contains(variable) {
            return true
        }
        for pair in [("<think>", "</think>"),
                     ("<|think|>", "</|think|>"),
                     ("<seed:think|>", "</seed:think|>")]
        where lowered.contains(pair.0) && lowered.contains(pair.1) {
            return true
        }
        return lowered.contains("<|channel>thought") || lowered.contains("<think></think>")
    }
}
