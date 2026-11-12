// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Hides a code at several depths of a long text and asks the running server for it back: a quick
/// check that a quantized KV cache or a long context still recalls what it read.
@MainActor
final class NeedleTest: ObservableObject {
    struct Cell: Identifiable, Equatable {
        let length: Int
        let depth: Int          // percent of the text before the code
        var passed: Bool?
        var promptTokens: Int?
        var seconds: Double?
        var answer: String?
        var id: String { "\(length)-\(depth)" }
    }

    @Published private(set) var cells: [Cell] = []
    @Published private(set) var running = false {
        didSet { keepAwake = KeepAwake.update(keepAwake, active: running, reason: "Running a context test") }
    }
    private var keepAwake: KeepAwake?
    @Published private(set) var contextTokens: Int?
    @Published var error: String?
    private var task: Task<Void, Never>?

    static let depths = [10, 50, 90]
    static let lengths = [8192, 32768, 131072]

    func lengths(fitting ctx: Int?) -> [Int] {
        guard let ctx else { return [] }
        return Self.lengths.filter { $0 + 512 <= ctx }
    }

    func readContext(port: Int) async {
        guard let url = URL(string: "http://127.0.0.1:\(port)/props") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        if let key = ServerSettings.activeAPIKey() { req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let settings = json["default_generation_settings"] as? [String: Any]
        contextTokens = (settings?["n_ctx"] as? Int) ?? (json["n_ctx"] as? Int)
    }

    func run(port: Int, upTo maxLength: Int) {
        guard !running else { return }
        let lengths = Self.lengths.filter { $0 <= maxLength }
        cells = lengths.flatMap { l in Self.depths.map { Cell(length: l, depth: $0) } }
        error = nil
        running = true
        task = Task { [weak self] in
            guard let self else { return }
            for i in cells.indices {
                if Task.isCancelled { break }
                let cell = cells[i]
                let code = Self.code()
                let prompt = Self.prompt(tokens: cell.length, depth: cell.depth, code: code)
                let t0 = Date()
                do {
                    let (answer, promptTokens) = try await Self.ask(port: port, prompt: prompt)
                    cells[i].answer = answer
                    cells[i].passed = answer.contains(code)
                    cells[i].promptTokens = promptTokens
                    cells[i].seconds = Date().timeIntervalSince(t0)
                } catch {
                    self.error = error.localizedDescription
                    break
                }
            }
            running = false
        }
    }

    func cancel() {
        task?.cancel()
        running = false
    }

    // MARK: text

    private static let words = ["amber", "cobalt", "falcon", "harbor", "juniper", "lantern", "meadow", "orchid",
                                "quartz", "saffron", "thistle", "willow"]

    static func code() -> String {
        "\(words.randomElement()!.uppercased())-\(Int.random(in: 1000...9999))"
    }

    /// Filler of about `tokens` tokens with the code sentence at `depth` percent. Its numbers tokenize
    /// densely: measured on Qwen at about 3.6 characters per token, so the budget stays under that.
    static let charsPerToken = 3.4
    static func prompt(tokens: Int, depth: Int, code: String) -> String {
        var rng = SystemRandomNumberGenerator()
        let subjects = ["The keeper", "A traveler", "The old clock", "Every lamp", "The river", "A small boat",
                        "The market", "Each bell", "The northern road", "A quiet garden"]
        let verbs = ["waited near", "passed by", "shone over", "rested beside", "turned toward", "drifted past"]
        let places = ["the harbor", "the hill", "the station", "the library", "the bridge", "the square"]
        let budget = Int(Double(max(256, tokens - 96)) * charsPerToken)
        let needle = " The access code for the vault is \(code). Remember it."
        var text = ""
        text.reserveCapacity(budget + 256)
        var placed = false
        var day = 1
        while text.count < budget {
            if !placed && text.count >= budget * depth / 100 {
                text += needle
                placed = true
            }
            text += " \(subjects.randomElement(using: &rng)!) \(verbs.randomElement(using: &rng)!) \(places.randomElement(using: &rng)!) on day \(day % 365 + 1)."
            day += 1
        }
        if !placed { text += needle }
        return text + "\n\nWhat is the access code for the vault? Answer with the code only."
    }

    private static func ask(port: Int, prompt: String) async throws -> (String, Int?) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 3600)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("off", forHTTPHeaderField: "X-Tosh-Agent")
        if let key = ServerSettings.activeAPIKey() { req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = [
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 32, "temperature": 0, "cache_prompt": false,
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "NeedleTest", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: data.prefix(300), as: UTF8.self)])
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
        let answer = (message?["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let usage = json?["usage"] as? [String: Any]
        return (answer, usage?["prompt_tokens"] as? Int)
    }
}

/// The recall check in Benchmarks: runs against the main server as it is loaded.
struct NeedleTestCard: View {
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var loc: Localizer
    @StateObject private var test = NeedleTest()
    @State private var maxLength = 32768

    var body: some View {
        Card(title: loc.t("Memoria de contexto", "Context recall"), icon: "text.magnifyingglass") {
            VStack(alignment: .leading, spacing: 12) {
                Text(loc.t("Esconde un código en un texto largo a varias profundidades y pregunta por él al servidor en marcha, sin razonamiento. Sirve para comprobar que un KV cuantizado o un contexto largo siguen recordando lo que leyeron.",
                           "Hides a code in a long text at several depths and asks the running server for it, with reasoning off. It checks that a quantized KV cache or a long context still recalls what it read."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    let fitting = test.lengths(fitting: test.contextTokens)
                    if fitting.isEmpty {
                        Text(server.runningPort == nil
                             ? loc.t("Inicia el servidor principal con el modelo que quieras probar.", "Start the main server with the model you want to test.")
                             : loc.t("El contexto del servidor es menor de 8K.", "The server's context is under 8K."))
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Picker(loc.t("Hasta", "Up to"), selection: $maxLength) {
                            ForEach(fitting, id: \.self) { l in
                                Text("\(l / 1024)K").tag(l)
                            }
                        }
                        .frame(width: 150)
                        .disabled(test.running)
                        .help(loc.t("Longitud máxima del texto. Solo aparecen las que caben en el contexto del servidor; las largas pueden tardar varios minutos cada una.",
                                    "Longest text to try. Only lengths that fit the server's context are offered; long ones can take several minutes each."))
                    }
                    Spacer()
                    if test.running {
                        ProgressView().controlSize(.small)
                        Button(loc.t("Detener", "Stop")) { test.cancel() }
                            .help(loc.t("Detiene la prueba tras la petición en curso.", "Stops the test after the current request."))
                    } else {
                        Button(loc.t("Ejecutar", "Run")) {
                            if let port = server.runningPort { test.run(port: port, upTo: maxLength) }
                        }
                        .glassButton(prominent: true)
                        .disabled(server.runningPort == nil || fitting.isEmpty)
                        .help(server.runningPort == nil
                              ? loc.t("Inicia el servidor principal con el modelo que quieras probar.", "Start the main server with the model you want to test.")
                              : loc.t("Hace una petición por longitud y profundidad al servidor en marcha.", "Sends one request per length and depth to the running server."))
                    }
                }
                if let error = test.error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
                if !test.cells.isEmpty { grid }
            }
        }
        .task(id: server.runningPort) {
            if let port = server.runningPort {
                await test.readContext(port: port)
                if let best = test.lengths(fitting: test.contextTokens).first(where: { $0 >= 32768 }) ?? test.lengths(fitting: test.contextTokens).last {
                    maxLength = best
                }
            }
        }
    }

    private var grid: some View {
        let lengths = Array(Set(test.cells.map(\.length))).sorted()
        return Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                Text(loc.t("Longitud", "Length")).font(.caption.weight(.semibold))
                ForEach(NeedleTest.depths, id: \.self) { d in
                    Text(loc.t("Código al %@%%", "Code at %@%%", "\(d)")).font(.caption.weight(.semibold))
                }
            }
            ForEach(lengths, id: \.self) { l in
                GridRow {
                    Text("\(l / 1024)K").font(.callout.monospacedDigit())
                    ForEach(NeedleTest.depths, id: \.self) { d in
                        cellView(test.cells.first { $0.length == l && $0.depth == d })
                    }
                }
            }
        }
    }

    @ViewBuilder private func cellView(_ cell: NeedleTest.Cell?) -> some View {
        if let cell, let passed = cell.passed {
            Label(cell.seconds.map { String(format: "%.0fs", $0) } ?? "",
                  systemImage: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(passed ? .green : .red)
                .font(.callout.monospacedDigit())
                .help(loc.t("Respuesta: %@", "Answer: %@", cell.answer ?? ""))
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}
