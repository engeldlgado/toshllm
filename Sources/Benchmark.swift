import Foundation

struct BenchResult: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let model: String
    let ncmoe: Int
    let pp: Double
    let tg: Double
    // optional for backward compatibility with older saved results
    var ctk: String?
    var ctv: String?
    var engine: String?

    var shortModel: String {
        model.replacingOccurrences(of: ".gguf", with: "")
            .replacingOccurrences(of: "-Instruct", with: "")
            .replacingOccurrences(of: "-2507", with: "")
            .replacingOccurrences(of: "-UD", with: "")
    }

    var configLabel: String {
        var parts: [String] = []
        if ncmoe > 0 { parts.append("ncmoe \(ncmoe)") }
        if let ctk, ctk != "f16" { parts.append("K:\(ctk)") }
        if let ctv, ctv != "f16" { parts.append("V:\(ctv)") }
        if let engine, engine != "bundled" { parts.append(engine) }
        return parts.isEmpty ? "base" : parts.joined(separator: " · ")
    }
}

@MainActor
final class BenchmarkController: ObservableObject {
    @Published var running = false
    @Published var output = ""
    @Published var history: [BenchResult] = []

    private var process: Process?
    private let storeKey = "benchHistory"

    init() { load() }

    func run(settings: ServerSettings) {
        guard !running else { return }
        let benchPath = URL(fileURLWithPath: settings.serverBinary)
            .deletingLastPathComponent().appendingPathComponent("llama-bench").path
        guard FileManager.default.fileExists(atPath: benchPath) else {
            output = "llama-bench no encontrado / not found: \(benchPath)"
            return
        }
        guard FileManager.default.fileExists(atPath: settings.modelPath) else {
            output = "Modelo no encontrado / model not found"
            return
        }

        output = ""
        running = true

        let p = Process()
        p.executableURL = URL(fileURLWithPath: benchPath)
        var args = ["-m", settings.modelPath, "-ngl", String(settings.ngl), "--mmap", "0", "-r", "2"]
        if settings.ncmoe > 0 { args += ["-ncmoe", String(settings.ncmoe)] }
        if settings.cacheTypeK != "f16" { args += ["-ctk", settings.cacheTypeK] }
        if settings.cacheTypeV != "f16" { args += ["-ctv", settings.cacheTypeV] }
        if settings.flashAttn == "on" || settings.cacheTypeV != "f16" { args += ["-fa", "1"] }
        p.arguments = args
        p.environment = settings.environment

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.output += text }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.finish(settings: settings) }
        }

        do {
            try p.run()
            process = p
        } catch {
            output = error.localizedDescription
            running = false
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
        running = false
    }

    private func finish(settings: ServerSettings) {
        running = false
        process = nil

        func speed(_ test: String) -> Double? {
            for line in output.split(separator: "\n") where line.contains(" \(test) ") {
                if let r = line.range(of: #"([0-9]+\.[0-9]+) ±"#, options: .regularExpression) {
                    return Double(line[r].split(separator: " ")[0])
                }
            }
            return nil
        }

        if let pp = speed("pp512"), let tg = speed("tg128") {
            let name = URL(fileURLWithPath: settings.modelPath).lastPathComponent
            let engine: String
            if settings.serverBinary == ServerSettings.defaultBinary {
                engine = "bundled"
            } else if settings.serverBinary == ServerSettings.turboBinary {
                engine = "turbo"
            } else {
                engine = "externo"
            }
            history.insert(BenchResult(date: .now, model: name, ncmoe: settings.ncmoe, pp: pp, tg: tg,
                                       ctk: settings.cacheTypeK, ctv: settings.cacheTypeV, engine: engine),
                           at: 0)
            save()
        }
    }

    func delete(_ result: BenchResult) {
        history.removeAll { $0.id == result.id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let h = try? JSONDecoder().decode([BenchResult].self, from: data) else { return }
        history = h
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }
}
