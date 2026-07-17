import Foundation
import CryptoKit

// MARK: - Signed benchmark sharing (v2 protocol)
//
// Client for the toshllm.com signed benchmark contract. Everything here runs
// only inside an explicit user share: the P-256 key and the registration call
// are created on the first share, never at launch, so an install that never
// shares makes no network call at all.

@MainActor
final class BenchmarkSharing: ObservableObject {
    static let shared = BenchmarkSharing()

    static let baseURL = "https://toshllm.com"
    static let consentVersion = "benchmark-share-v1"
    private static let bundleID = "dev.engel.toshllm"
    private static let keyAccount = "benchmark-signing-key.v1"

    /// Public, non-secret identity assigned by the server. Shown in the identity
    /// panel; the private key stays in the Keychain.
    @Published private(set) var installationId: String?
    @Published private(set) var keyFingerprint: String?
    @Published var busy = false

    private init() {
        installationId = UserDefaults.standard.string(forKey: SettingsKeys.benchmarkInstallationId)
        keyFingerprint = UserDefaults.standard.string(forKey: SettingsKeys.benchmarkKeyFingerprint)
    }

    /// True once this install has generated a signing key (i.e. shared at least once).
    var hasIdentity: Bool { Keychain.get(Self.keyAccount) != nil }

    /// Drops the Keychain key and the public identity so the next share starts a
    /// fresh, unlinkable installation. Past public submissions keep the old one.
    func resetIdentity() {
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

    /// Loads the stored key, or mints one (Secure Enclave when the machine has it,
    /// a software key on a Hackintosh without a T2). The stored string is tagged so
    /// reload knows which kind it is.
    private func loadOrCreateKey() -> SigningKey {
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
        if SecureEnclave.isAvailable, let k = try? SecureEnclave.P256.Signing.PrivateKey() {
            Keychain.set("se:" + k.dataRepresentation.base64EncodedString(), account: Self.keyAccount)
            return .enclave(k)
        }
        let k = P256.Signing.PrivateKey()
        Keychain.set("sw:" + k.rawRepresentation.base64EncodedString(), account: Self.keyAccount)
        return .software(k)
    }

    // MARK: Errors

    enum ShareError: LocalizedError {
        case network
        case badResponse
        case server(status: Int, code: String?)
        case workloadFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .network: return "network error"
            case .badResponse: return "unexpected server response"
            case .server(let status, let code): return "server \(status)\(code.map { " (\($0))" } ?? "")"
            case .workloadFailed(let m): return m
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

    /// Payload built and ready to review, before anything is signed or uploaded.
    /// Holding the exact bytes here is what lets the user inspect the final JSON
    /// and lets submit use the identical bytes it reviewed.
    struct Prepared {
        let payload: Data
        var json: String { String(data: payload, encoding: .utf8) ?? "" }
    }

    /// Step 1 of a share (runs only after the user accepts the consent dialog):
    /// creates the key + registration on first use, runs the exact server workload,
    /// and builds the payload. Nothing is uploaded yet.
    func prepareShare(model: LocalModel, settings: ServerSettings,
                      contributorAlias: String?) async throws -> Prepared {
        busy = true
        defer { busy = false }

        let key = loadOrCreateKey()
        try await ensureRegistered(key)

        let (_, _, workload) = try await benchmarkChallenge()
        let run = try await runWorkload(workload, model: model, settings: settings)
        let payload = try buildBenchmarkPayload(model: model, settings: settings,
                                                workload: workload, run: run,
                                                contributorAlias: contributorAlias)
        return Prepared(payload: payload)
    }

    /// Step 2: the user reviewed the JSON and confirmed. Signs the exact reviewed
    /// bytes against a fresh challenge and uploads. A fresh challenge here avoids
    /// the expiry race during the minutes-long workload run.
    func submitPrepared(_ prepared: Prepared) async throws -> Outcome {
        busy = true
        defer { busy = false }
        let key = loadOrCreateKey()
        let (challengeId, nonce) = try await challenge(purpose: "benchmark")
        let signature = try key.signatureDER(for: Self.signatureMessage(
            purpose: "benchmark", challengeId: challengeId, nonce: nonce, payload: prepared.payload))
        let d = unwrap(try await postJSON("/api/v2/benchmarks", [
            "installationId": installationId as Any,
            "envelope": [
                "challengeId": challengeId, "nonce": nonce,
                "payload": prepared.payload.base64URLValue, "signature": signature.base64URLValue,
            ],
        ]))
        return Outcome(
            trust: d["trust"] as? String ?? "app-recorded",
            moderationStatus: d["moderationStatus"] as? String ?? "pending",
            replay: d["idempotentReplay"] as? Bool ?? false)
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
        let key = loadOrCreateKey()
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
        let d = unwrap(obj)
        let items = (d["items"] as? [[String: Any]]) ?? (d["benchmarks"] as? [[String: Any]]) ?? []
        return items.map { it in
            HistoryItem(
                id: it["id"] as? String ?? UUID().uuidString,
                model: it["model"] as? String ?? "—",
                gpu: it["gpu"] as? String ?? "—",
                pp: (it["prompt"] as? Double) ?? (it["pp"] as? Double) ?? 0,
                tg: (it["generation"] as? Double) ?? (it["tg"] as? Double) ?? 0,
                trust: it["trust"] as? String ?? "app-recorded",
                moderation: it["moderationStatus"] as? String ?? "pending")
        }
    }

    // MARK: Registration

    private func ensureRegistered(_ key: SigningKey) async throws {
        if installationId != nil { return }
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
        guard let iid = d["installationId"] as? String else { throw ShareError.badResponse }
        installationId = iid
        UserDefaults.standard.set(iid, forKey: SettingsKeys.benchmarkInstallationId)
        if let fp = d["keyFingerprint"] as? String {
            keyFingerprint = fp
            UserDefaults.standard.set(fp, forKey: SettingsKeys.benchmarkKeyFingerprint)
        }
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
        // The server drives the workload; decode it rather than hardcoding.
        let w = (d["workload"] as? [String: Any]) ?? d
        let workload = Workload(
            id: w["id"] as? String ?? "llama-bench-pp512-tg128-r3-v1",
            promptTokens: w["promptTokens"] as? Int ?? 512,
            generatedTokens: w["generatedTokens"] as? Int ?? 128,
            repetitions: w["repetitions"] as? Int ?? 3,
            consentVersion: (d["privacyConsentVersion"] as? String)
                ?? (w["privacyConsentVersion"] as? String) ?? Self.consentVersion)
        return (id, nonce, workload)
    }

    // MARK: Workload execution

    struct WorkloadRun {
        let pp: [Double]
        let tg: [Double]
        let rawOutput: String
        let engineSha256: String?
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
        runConfig.ncmoe = Estimator.ncmoeForSelection(path: model.url.path,
                                                      models: LocalModel.scan(in: ServerSettings.modelsDirectory))
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
        let engineSha = FileHash.sha256(of: URL(fileURLWithPath: benchPath))
        return WorkloadRun(pp: pp, tg: tg, rawOutput: sanitize(raw, modelPath: model.url.path),
                           engineSha256: engineSha)
    }

    // MARK: Payload assembly

    private func buildBenchmarkPayload(model: LocalModel, settings: ServerSettings,
                                       workload: Workload, run: WorkloadRun,
                                       contributorAlias: String?) throws -> Data {
        let name = ModelName.forPath(model.url.path)
        let hw = HardwareInfo.detect()

        let artifacts: [[String: Any]] = try model.partURLs.map { url in
            guard let sha = FileHash.sha256(of: url) else { throw ShareError.workloadFailed("hash failed for \(url.lastPathComponent)") }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return ["fileName": url.lastPathComponent, "sha256": sha, "sizeBytes": size]
        }

        var modelObj: [String: Any] = [
            "displayName": name.title,
            "artifacts": artifacts,
            "quantization": name.quant.isEmpty ? "unknown" : name.quant,
            "family": modelFamily(model),
        ]
        if let params = ModelName.activeParamsB(model.name) { modelObj["parameterCountB"] = params }

        let gpus: [[String: Any]] = hw.gpus.filter { !$0.isIntegrated }.map { g in
            ["name": g.name, "vramBytes": Int64(g.vramMB) * 1024 * 1024]
        }

        var evidence: [String: Any] = ["rawOutput": run.rawOutput]
        if let sha = run.engineSha256 { evidence["engineSha256"] = sha }

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
                "cpuMoeExperts": Estimator.ncmoeForSelection(
                    path: model.url.path,
                    models: LocalModel.scan(in: ServerSettings.modelsDirectory)),
                "cacheTypeK": settings.cacheTypeK,
                "cacheTypeV": settings.cacheTypeV,
                "flashAttention": settings.benchmarkFlashAttentionRoute,
                "mmap": false,
                "backend": "Metal",
            ],
            "measurements": [
                "promptTokensPerSecond": run.pp,
                "generationTokensPerSecond": run.tg,
            ],
            // Echo the exact version the challenge advertised, not a local constant.
            "privacyConsentVersion": workload.consentVersion,
        ]
        if let alias = contributorAlias, !alias.isEmpty {
            payload["contributor"] = ["displayName": alias]
        }
        // Encode ONCE: these exact bytes are what we hash, sign, and upload.
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func modelFamily(_ model: LocalModel) -> String {
        // Only claim dense/moe when the GGUF metadata says so; never guess from name.
        guard let metadata = GGUFMetadataCache.metadata(at: model.url.path),
              let experts = metadata.uint32(forSuffix: "expert_count") else { return "unknown" }
        return experts > 0 ? "moe" : "dense"
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

    /// Internal + static so the protocol contract (exact bytes, no trailing
    /// newline, lowercase hex) can be unit-tested without a server. Pure, so
    /// nonisolated to run off the main actor.
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

    private static var buildNumber: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? AppInfo.version.replacingOccurrences(of: ".", with: "")
    }

    // MARK: Process + parsing

    private func runProcess(_ path: String, _ args: [String], env: [String: String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
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
}

private extension Data {
    var base64URLValue: String { BenchmarkSharing.base64URL(self) }
}
