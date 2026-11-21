// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where Hugging Face downloads, searches and file lookups connect. Catalogs, recorded sources and
/// the links that open huggingface.co keep their address; only the connection goes to the mirror.
enum HubEndpoint {
    static let huggingFace = "huggingface"
    static let hfMirror = "hf-mirror"
    static let custom = "custom"
    static let hfMirrorURL = URL(string: "https://hf-mirror.com")!
    static let environmentKey = "HF_ENDPOINT"

    /// Where huggingface.co requests go instead, or nil to use huggingface.co itself.
    static func base(choice: String?, custom: String?, environment: [String: String]) -> URL? {
        switch choice {
        case hfMirror: return hfMirrorURL
        case Self.custom: return validBase(custom)
        default: return validBase(environment[environmentKey])
        }
    }

    static var currentBase: URL? {
        let defaults = UserDefaults.standard
        return base(choice: defaults.string(forKey: SettingsKeys.hubEndpoint),
                    custom: defaults.string(forKey: SettingsKeys.hubEndpointCustom),
                    environment: ProcessInfo.processInfo.environment)
    }

    /// An http(s) address with a host and nothing after its path; anything else is ignored.
    static func validBase(_ text: String?) -> URL? {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false, url.query == nil, url.fragment == nil,
              !(isHub(url) && url.path.isEmpty) else { return nil }
        return url
    }

    static func isHub(_ url: URL) -> Bool {
        let host = url.host?.lowercased()
        return host == "huggingface.co" || host == "www.huggingface.co"
    }

    /// `url` aimed at `base` when it is a huggingface.co address, unchanged otherwise.
    static func resolve(_ url: URL, base: URL?) -> URL {
        guard let base, isHub(url),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return url }
        parts.scheme = target.scheme
        parts.host = target.host
        parts.port = target.port
        parts.user = target.user
        parts.password = target.password
        parts.percentEncodedPath = target.percentEncodedPath + parts.percentEncodedPath
        return parts.url ?? url
    }

    static func resolve(_ url: URL) -> URL { resolve(url, base: currentBase) }

    /// A link copied from hf-mirror.com or the chosen mirror, written back as its huggingface.co
    /// address so it gets the same checksum, source record and update check.
    static func canonical(_ url: URL, base: URL?) -> URL {
        for mirror in [base, hfMirrorURL].compactMap({ $0 }) {
            guard url.host?.lowercased() == mirror.host?.lowercased(), url.port == mirror.port,
                  var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            let prefix = URLComponents(url: mirror, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
            guard parts.percentEncodedPath.hasPrefix(prefix + "/") else { continue }
            parts.percentEncodedPath.removeFirst(prefix.count)
            parts.scheme = "https"
            parts.host = "huggingface.co"
            parts.port = nil
            parts.user = nil
            parts.password = nil
            return parts.url ?? url
        }
        return url
    }

    static func canonical(_ url: URL) -> URL { canonical(url, base: currentBase) }

    static func data(from url: URL) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(from: resolve(url))
    }

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        request.url = request.url.map { resolve($0) }
        return try await URLSession.shared.data(for: request)
    }
}
