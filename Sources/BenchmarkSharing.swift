import Foundation
import CryptoKit

// MARK: - Signed benchmark sharing (v2 protocol)
//
// The key and every network call happen only inside an explicit user share, so
// an install that never shares makes no request at all.

@MainActor
final class BenchmarkSharing: ObservableObject {
    static let shared = BenchmarkSharing()

    static let baseURL = "https://toshllm.com"
    static let consentVersion = "benchmark-share-v1"
    private static let bundleID = "dev.engel.toshllm"
    private static let keyAccount = "benchmark-signing-key.v1"

    // Public identity from the server; the private key never leaves the Keychain.
    @Published private(set) var installationId: String?
    @Published private(set) var keyFingerprint: String?
    @Published var busy = false

    private init() {
        installationId = UserDefaults.standard.string(forKey: SettingsKeys.benchmarkInstallationId)
        keyFingerprint = UserDefaults.standard.string(forKey: SettingsKeys.benchmarkKeyFingerprint)
    }

    var hasIdentity: Bool { installationId != nil && keyFingerprint != nil }

    /// The next share starts a fresh, unlinkable installation; past public
    /// submissions keep the old identity.
    func resetIdentity() {
        guard !busy else { return }
        Keychain.delete(Self.keyAccount)
        installationId = nil
        keyFingerprint = nil
        UserDefaults.standard.removeObject(forKey: SettingsKeys.benchmarkInstallationId)
        UserDefaults.standard.removeObject(forKey: SettingsKeys.benchmarkKeyFingerprint)
    }

    // MARK: Signing key

    private enum SigningKey {
        case enclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)

        var publicX963: Data {
            switch self {
            case .enclave(let k): return k.publicKey.x963Representation
            case .software(let k): return k.publicKey.x963Representation
            }
        }

        func signatureDER(for message: Data) throws -> Data {
            switch self {
            case .enclave(let k): return try k.signature(for: message).derRepresentation
            case .software(let k): return try k.signature(for: message).derRepresentation
            }
        }
    }

    // The stored string is tagged ("se:"/"sw:") so reload picks the right key kind.
    private func loadStoredKey() -> SigningKey? {
        if let stored = Keychain.get(Self.keyAccount) {
            if stored.hasPrefix("se:"), let data = Data(base64Encoded: String(stored.dropFirst(3))),
               let k = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data) {
                return .enclave(k)
            }
            if stored.hasPrefix("sw:"), let data = Data(base64Encoded: String(stored.dropFirst(3))),
               let k = try? P256.Signing.PrivateKey(rawRepresentation: data) {
                return .software(k)
            }
        }
        return nil
    }

    private func loadOrCreateKey() throws -> SigningKey {
        if let key = loadStoredKey() { return key }
        if SecureEnclave.isAvailable, let k = try? SecureEnclave.P256.Signing.PrivateKey() {
            guard Keychain.setThisDeviceOnly("se:" + k.dataRepresentation.base64EncodedString(),
                                             account: Self.keyAccount) else {
                throw ShareError.keychain
            }
            return .enclave(k)
        }
        let k = P256.Signing.PrivateKey()
        guard Keychain.setThisDeviceOnly("sw:" + k.rawRepresentation.base64EncodedString(),
                                         account: Self.keyAccount) else {
            throw ShareError.keychain
        }
        return .software(k)
    }

    // MARK: Errors

    enum ShareError: LocalizedError {
        case network
        case badResponse
        case server(status: Int, code: String?)
        case workloadFailed(String)
        case unsupportedConsent(String)
        case identityChanged
        case keychain
        case cancelled

        var errorDescription: String? {
            switch self {
            case .network: return "network error"
            case .badResponse: return "unexpected server response"
            case .server(let status, let code): return "server \(status)\(code.map { " (\($0))" } ?? "")"
            case .workloadFailed(let m): return m
            case .unsupportedConsent(let version): return "unsupported consent version: \(version)"
            case .identityChanged: return "benchmark identity changed; prepare the submission again"
            case .keychain: return "the benchmark signing key could not be stored in Keychain"
            case .cancelled: return "cancelled"
            }
        }
    }

    // MARK: Public entry points

    struct Outcome {
        let trust: String            // "app-recorded" or "lab-signed"
        let moderationStatus: String // "pending", …
        let replay: Bool
    }

    /// Holds the exact bytes so the user inspects and submit uploads the same JSON.
    /// pp/tg are the medians measured, so the run can be recorded in local history.
    struct Prepared {
        let payload: Data
        let installationId: String
        let keyFingerprint: String
        let pp: Double
        let tg: Double
        var json: String { String(data: payload, encoding: .utf8) ?? "" }
    }

    /// Runs after consent: mints the key + registers on first use, runs the
    /// workload, builds the payload. Nothing is uploaded yet.
    func prepareShare(model: LocalModel, settings: ServerSettings,
                      contributorAlias: String?) async throws -> Prepared {
        busy = true
        defer { busy = false }

        let key = try loadOrCreateKey()
        try await ensureRegistered(key)

        guard let installationId, let keyFingerprint else { throw ShareError.badResponse }

        let (_, _, workload) = try await benchmarkChallenge()
        let run = try await runWorkload(workload, model: model, settings: settings)
        let payload = try await buildBenchmarkPayload(model: model, settings: settings,
                                                      workload: workload, run: run,
                                                      contributorAlias: contributorAlias)
        let pp = run.pp.sorted()[run.pp.count / 2]
        let tg = run.tg.sorted()[run.tg.count / 2]
        return Prepared(payload: payload, installationId: installationId,
                        keyFingerprint: keyFingerprint, pp: pp, tg: tg)
    }

    /// A fresh challenge here avoids the expiry race during the long workload run.
    func submitPrepared(_ prepared: Prepared) async throws -> Outcome {
        busy = true
        defer { busy = false }
        guard installationId == prepared.installationId,
              keyFingerprint == prepared.keyFingerprint else { throw ShareError.identityChanged }
        guard let key = loadStoredKey(),
              Self.fingerprint(for: key) == prepared.keyFingerprint else {
            throw ShareError.identityChanged
        }
        let (challengeId, nonce) = try await challenge(purpose: "benchmark")
        let signature = try key.signatureDER(for: Self.signatureMessage(
            purpose: "benchmark", challengeId: challengeId, nonce: nonce, payload: prepared.payload))
        let obj = try await postJSON("/api/v2/benchmarks", [
            "installationId": prepared.installationId,
            "envelope": [
                "challengeId": challengeId, "nonce": nonce,
                "payload": prepared.payload.base64URLValue, "signature": signature.base64URLValue,
            ],
        ])
        let d = unwrap(obj)
        return Outcome(
            trust: d["trust"] as? String ?? "app-recorded",
            moderationStatus: d["moderationStatus"] as? String ?? "pending",
            replay: obj["idempotentReplay"] as? Bool ?? false)
    }

    /// This installation's own submissions (signed history call). Load only on an
    /// explicit user tap, never on view appearance.
    struct HistoryItem: Identifiable {
        let id: String
        let model: String
        let gpu: String
        let pp: Double
        let tg: Double
        let trust: String
        let moderation: String
    }

    func fetchHistory(page: Int = 1, limit: Int = 20) async throws -> [HistoryItem] {
        guard hasIdentity, let installationId else { return [] }
        busy = true
        defer { busy = false }
        guard let key = loadStoredKey(),
              Self.fingerprint(for: key) == keyFingerprint else { throw ShareError.identityChanged }
        let (challengeId, nonce) = try await challenge(purpose: "history")
        let payloadObj: [String: Any] = [
            "schemaVersion": 1, "installationId": installationId, "page": page, "limit": limit,
        ]
        let payload = try JSONSerialization.data(withJSONObject: payloadObj)
        let signature = try key.signatureDER(for: Self.signatureMessage(
            purpose: "history", challengeId: challengeId, nonce: nonce, payload: payload))
        let obj = try await postJSON("/api/v2/my-benchmarks", [
            "installationId": installationId,
            "envelope": [
                "challengeId": challengeId, "nonce": nonce,
                "payload": payload.base64URLValue, "signature": signature.base64URLValue,
            ],
        ])
        guard let items = obj["data"] as? [[String: Any]] else { throw ShareError.badResponse }
        return items.compactMap { item in
            guard let id = item["submissionId"] as? String,
                  let model = item["model"] as? [String: Any],
                  let modelName = model["displayName"] as? String,
                  let hardware = item["hardware"] as? [String: Any],
                  let gpus = hardware["gpus"] as? [[String: Any]],
                  let performance = item["performance"] as? [String: Any],
                  let pp = performance["promptTokensPerSecond"] as? Double,
                  let tg = performance["generationTokensPerSecond"] as? Double else { return nil }
            let gpuNames = gpus.compactMap { $0["name"] as? String }
            return HistoryItem(
                id: id,
                model: modelName,
                gpu: gpuNames.isEmpty ? "—" : gpuNames.joined(separator: " + "),
                pp: pp,
                tg: tg,
                trust: item["trust"] as? String ?? "app-recorded",
                moderation: item["moderationStatus"] as? String ?? "pending")
        }
    }

    // MARK: Registration

    private func ensureRegistered(_ key: SigningKey) async throws {
        let localFingerprint = Self.fingerprint(for: key)
        if installationId != nil, keyFingerprint == localFingerprint { return }
        installationId = nil
        keyFingerprint = nil
        UserDefaults.standard.removeObject(forKey: SettingsKeys.benchmarkInstallationId)
        UserDefaults.standard.removeObject(forKey: SettingsKeys.benchmarkKeyFingerprint)
        let (challengeId, nonce) = try await challenge(purpose: "register")
        let payloadObj: [String: Any] = [
            "schemaVersion": 1,
            "publicKey": ["algorithm": "ES256", "format": "x963", "value": key.publicX963.base64URLValue],
            "app": ["bundleIdentifier": Self.bundleID, "version": AppInfo.version,
                    "build": Self.buildNumber, "platform": "macOS"],
        ]
        let payload = try JSONSerialization.data(withJSONObject: payloadObj)
        let signature = try key.signatureDER(for: Self.signatureMessage(
            purpose: "register", challengeId: challengeId, nonce: nonce, payload: payload))
        let obj = try await postJSON("/api/v2/installations", [
            "challengeId": challengeId, "nonce": nonce,
            "payload": payload.base64URLValue, "signature": signature.base64URLValue,
        ])
        let d = unwrap(obj)
        guard let iid = d["installationId"] as? String,
              let fp = d["keyFingerprint"] as? String,
              fp == localFingerprint else {
            throw ShareError.badResponse
        }
        installationId = iid
        keyFingerprint = fp
        UserDefaults.standard.set(iid, forKey: SettingsKeys.benchmarkInstallationId)
        UserDefaults.standard.set(fp, forKey: SettingsKeys.benchmarkKeyFingerprint)
    }

    // MARK: Challenges

    private func challenge(purpose: String) async throws -> (id: String, nonce: String) {
        var body: [String: Any] = ["purpose": purpose]
        if purpose != "register", let installationId { body["installationId"] = installationId }
        let d = unwrap(try await postJSON("/api/v2/challenges", body))
        guard let id = d["challengeId"] as? String, let nonce = d["nonce"] as? String else {
            throw ShareError.badResponse
        }
        return (id, nonce)
    }

    struct Workload {
        let id: String
        let runner: String
        let promptTokens: Int
        let generatedTokens: Int
        let repetitions: Int
        /// The consent version the server currently accepts; must be echoed in the
        /// signed payload verbatim (the server rejects arbitrary/obsolete versions).
        let consentVersion: String
    }

    private func benchmarkChallenge() async throws -> (id: String, nonce: String, workload: Workload) {
        guard let installationId else { throw ShareError.badResponse }
        let d = unwrap(try await postJSON("/api/v2/challenges",
                                          ["purpose": "benchmark", "installationId": installationId]))
        guard let id = d["challengeId"] as? String, let nonce = d["nonce"] as? String else {
            throw ShareError.badResponse
        }
        guard let w = d["workload"] as? [String: Any],
              let workloadId = w["id"] as? String,
              let runner = w["runner"] as? String,
              let promptTokens = w["promptTokens"] as? Int,
              let generatedTokens = w["generatedTokens"] as? Int,
              let repetitions = w["repetitions"] as? Int,
              let consentVersion = d["privacyConsentVersion"] as? String,
              runner == "llama-bench",
              promptTokens > 0, generatedTokens > 0,
              (1...20).contains(repetitions) else { throw ShareError.badResponse }
        guard consentVersion == Self.consentVersion else {
            throw ShareError.unsupportedConsent(consentVersion)
        }
        let workload = Workload(
            id: workloadId,
            runner: runner,
            promptTokens: promptTokens,
            generatedTokens: generatedTokens,
            repetitions: repetitions,
            consentVersion: consentVersion)
        return (id, nonce, workload)
    }

    // MARK: Workload execution

    struct WorkloadRun {
        let pp: [Double]
        let tg: [Double]
        let rawOutput: String
        let engineURL: URL
        let arguments: [String]
        let cpuMoeExperts: Int
    }

    /// Runs llama-bench once per repetition (each `-r 1`, so all rows are preserved)
    /// with the app's real AMD config, so shared numbers match what the app shows.
    private func runWorkload(_ workload: Workload, model: LocalModel,
                             settings: ServerSettings) async throws -> WorkloadRun {
        let benchPath = URL(fileURLWithPath: settings.serverBinary)
            .deletingLastPathComponent().appendingPathComponent("llama-bench").path
        guard FileManager.default.fileExists(atPath: benchPath) else {
            throw ShareError.workloadFailed("llama-bench not found")
        }

        var runConfig = settings
        runConfig.modelPath = model.url.path
        var args = runConfig.benchmarkArguments
        overrideArg(&args, "-p", String(workload.promptTokens))
        overrideArg(&args, "-n", String(workload.generatedTokens))
        overrideArg(&args, "-r", "1")
        removeArg(&args, "-d")   // the shared workload is depth 0

        var pp: [Double] = [], tg: [Double] = []
        var raw = ""
        for _ in 0..<workload.repetitions {
            let out = try await runProcess(benchPath, args, env: runConfig.environment)
            raw += out + "\n"
            if let v = parseSpeed(out, test: "pp\(workload.promptTokens)") { pp.append(v) }
            if let v = parseSpeed(out, test: "tg\(workload.generatedTokens)") { tg.append(v) }
        }
        guard pp.count == workload.repetitions, tg.count == workload.repetitions else {
            throw ShareError.workloadFailed("benchmark produced \(pp.count) pp / \(tg.count) tg rows, expected \(workload.repetitions)")
        }
        return WorkloadRun(pp: pp, tg: tg, rawOutput: sanitize(raw, modelPath: model.url.path),
                           engineURL: URL(fileURLWithPath: benchPath),
                           arguments: sanitizeArguments(args, modelPath: model.url.path),
                           cpuMoeExperts: runConfig.ncmoe)
    }

    // MARK: Payload assembly

    private func buildBenchmarkPayload(model: LocalModel, settings: ServerSettings,
                                       workload: Workload, run: WorkloadRun,
                                       contributorAlias: String?) async throws -> Data {
        let name = ModelName.forPath(model.url.path)
        let hw = HardwareInfo.detect()

        let artifactURLs = model.partURLs
        let engineURL = run.engineURL
        let digests = await Task.detached(priority: .utility) {
            artifactURLs.map { url -> (URL, String?, Int64) in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                return (url, FileHash.sha256(of: url), size)
            }
        }.value
        let engineSHA = await Task.detached(priority: .utility) {
            FileHash.sha256(of: engineURL)
        }.value
        let artifacts: [[String: Any]] = try digests.map { url, digest, size in
            guard let digest, size >= 1024 else {
                throw ShareError.workloadFailed("hash failed for \(url.lastPathComponent)")
            }
            return ["fileName": url.lastPathComponent, "sha256": digest, "sizeBytes": size]
        }
        guard let engineSHA else { throw ShareError.workloadFailed("hash failed for llama-bench") }

        let modelObj: [String: Any] = [
            "displayName": name.title,
            "artifacts": artifacts,
            "quantization": name.quant.isEmpty ? "unknown" : name.quant,
            "family": modelFamily(model),
        ]
        let discreteGPUs = hw.gpus.filter { !$0.isIntegrated }
        let reportedGPUs = discreteGPUs.isEmpty ? hw.gpus : discreteGPUs
        guard !reportedGPUs.isEmpty else { throw ShareError.workloadFailed("no GPU detected") }
        let gpus: [[String: Any]] = reportedGPUs.map { g in
            var value: [String: Any] = [
                "name": g.name,
                "vramBytes": Int64(g.vramMB) * 1024 * 1024,
            ]
            if let architecture = GPUArchitectureClassifier.architecture(for: g.name) {
                value["architecture"] = architecture
            }
            return value
        }

        let evidence: [String: Any] = ["rawOutput": run.rawOutput, "engineSha256": engineSHA]

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var payload: [String: Any] = [
            "schemaVersion": 1,
            "runId": UUID().uuidString,
            "capturedAt": iso.string(from: Date()),
            "app": [
                "bundleIdentifier": Self.bundleID, "version": AppInfo.version,
                "build": Self.buildNumber,
                "engineVersion": "ToshLLM \(AppInfo.version)",
            ],
            "model": modelObj,
            "hardware": [
                "machineModel": hw.model,
                "osVersion": hw.osVersion,
                "cpu": hw.cpuBrand,
                "memoryBytes": Int64(hw.ramGB * 1_073_741_824),
                "gpus": gpus,
            ],
            "configuration": [
                "workloadId": workload.id,
                "promptTokens": workload.promptTokens,
                "generatedTokens": workload.generatedTokens,
                "repetitions": workload.repetitions,
                "contextDepth": 0,
                "gpuLayers": settings.ngl,
                "cpuMoeExperts": run.cpuMoeExperts,
                "cacheTypeK": settings.cacheTypeK,
                "cacheTypeV": settings.cacheTypeV,
                "flashAttention": settings.benchmarkFlashAttentionRoute,
                "mmap": false,
                "backend": "Metal",
                "arguments": run.arguments,
            ],
            "measurements": [
                "promptTokensPerSecond": run.pp,
                "generationTokensPerSecond": run.tg,
            ],
            "evidence": evidence,
            // Echo the exact version the challenge advertised, not a local constant.
            "privacyConsentVersion": workload.consentVersion,
        ]
        if let alias = contributorAlias, !alias.isEmpty {
            guard alias.utf16.count <= 80 else { throw ShareError.workloadFailed("alias is longer than 80 characters") }
            payload["contributor"] = ["displayName": alias]
        }
        // Encode ONCE: these exact bytes are what we hash, sign, and upload.
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func modelFamily(_ model: LocalModel) -> String {
        BenchmarkModelFamilyClassifier.family(for: model)
    }

    // MARK: Networking

    private func unwrap(_ obj: [String: Any]) -> [String: Any] {
        (obj["data"] as? [String: Any]) ?? obj
    }

    private func postJSON(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: Self.baseURL + path) else { throw ShareError.network }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { throw ShareError.network }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            let code = (obj["error"] as? [String: Any])?["code"] as? String ?? obj["code"] as? String
            throw ShareError.server(status: http.statusCode, code: code)
        }
        return obj
    }

    // MARK: Signing helpers

    // static + nonisolated so the exact-bytes contract is unit-testable without a server.
    nonisolated static func signatureMessage(purpose: String, challengeId: String,
                                             nonce: String, payload: Data) -> Data {
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return Data("toshllm-benchmark-v2\n\(purpose)\n\(challengeId)\n\(nonce)\n\(hash)".utf8)
    }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private nonisolated static func fingerprint(for key: SigningKey) -> String {
        SHA256.hash(data: key.publicX963).map { String(format: "%02x", $0) }.joined()
    }

    private static var buildNumber: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? AppInfo.version.replacingOccurrences(of: ".", with: "")
    }

    // MARK: Process + parsing

    private func runProcess(_ path: String, _ args: [String], env: [String: String]) async throws -> String {
        let outputURL = URL.temporaryDirectory.appending(path: "toshllm-benchmark-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw ShareError.workloadFailed("could not create temporary benchmark log")
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.environment = env
            p.standardOutput = outputHandle
            p.standardError = outputHandle
            p.terminationHandler = { process in
                cont.resume(returning: process.terminationStatus)
            }
            do {
                try p.run()
            } catch {
                p.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }
        try outputHandle.synchronize()
        let data = try Data(contentsOf: outputURL)
        let output = String(data: data, encoding: .utf8) ?? ""
        guard status == 0 else {
            throw ShareError.workloadFailed("llama-bench exited with status \(status): \(output.suffix(500))")
        }
        return output
    }

    private func parseSpeed(_ output: String, test: String) -> Double? {
        for line in output.split(separator: "\n") where line.contains(" \(test) ") {
            if let r = line.range(of: #"([0-9]+\.[0-9]+) ±"#, options: .regularExpression) {
                return Double(line[r].split(separator: " ")[0])
            }
        }
        return nil
    }

    private func overrideArg(_ args: inout [String], _ flag: String, _ value: String) {
        if let i = args.firstIndex(of: flag), i + 1 < args.count { args[i + 1] = value }
        else { args += [flag, value] }
    }

    private func removeArg(_ args: inout [String], _ flag: String) {
        if let i = args.firstIndex(of: flag) { args.removeSubrange(i ..< min(i + 2, args.count)) }
    }

    /// Strips the model path, home dir and any -m argument value from the raw log
    /// so no local path leaves the machine, keeping the benchmark rows for the server.
    private func sanitize(_ text: String, modelPath: String) -> String {
        var out = text.replacingOccurrences(of: modelPath, with: "[MODEL]")
        out = out.replacingOccurrences(of: NSHomeDirectory(), with: "[HOME]")
        return out
    }

    private func sanitizeArguments(_ arguments: [String], modelPath: String) -> [String] {
        arguments.map { argument in
            sanitize(argument, modelPath: modelPath)
        }
    }
}

private extension Data {
    var base64URLValue: String { BenchmarkSharing.base64URL(self) }
}
