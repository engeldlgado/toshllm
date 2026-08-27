// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct WhisperModel: Identifiable, Hashable {
    enum Tier {
        case fast, recommended, maximum, advanced
    }

    let id: String
    let name: String
    let sizeMB: Int
    let tier: Tier
    let detailES: String
    let detailEN: String

    var fileName: String { "ggml-\(id).bin" }
    var downloadURL: String {
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)"
    }

    static let catalog: [WhisperModel] = [
        .init(id: "small", name: "Small", sizeMB: 466, tier: .fast,
              detailES: "Rápido · multilingüe", detailEN: "Fast · multilingual"),
        .init(id: "large-v3-turbo-q5_0", name: "Large v3 Turbo Q5", sizeMB: 547, tier: .advanced,
              detailES: "Compacto · precisión muy buena", detailEN: "Compact · very good accuracy"),
        .init(id: "large-v3-turbo", name: "Large v3 Turbo", sizeMB: 1_536, tier: .recommended,
              detailES: "Mejor equilibrio · multilingüe", detailEN: "Best balance · multilingual"),
        .init(id: "large-v3", name: "Large v3", sizeMB: 2_944, tier: .maximum,
              detailES: "Máxima precisión · multilingüe", detailEN: "Maximum accuracy · multilingual"),
        .init(id: "base", name: "Base", sizeMB: 142, tier: .advanced,
              detailES: "Dictado ligero · multilingüe", detailEN: "Light dictation · multilingual")
    ]

    static let recommendedID = "large-v3-turbo"

    static func model(id: String) -> WhisperModel {
        catalog.first { $0.id == id }
            ?? catalog.first { $0.id == recommendedID }
            ?? catalog[0]
    }

    func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }
}

enum WhisperTranscript {
    nonisolated static func normalized(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    nonisolated static func timestamped(jsonData: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }
        if let segments = root["segments"] as? [[String: Any]] {
            return segments.compactMap { segment -> String? in
                guard let text = segment["text"] as? String else { return nil }
                let cleaned = normalized(text)
                guard !cleaned.isEmpty else { return nil }
                let seconds = segment["start"] as? Double ?? 0
                return "[\(timestamp(seconds: seconds))] \(cleaned)"
            }.joined(separator: "\n")
        }
        guard let segments = root["transcription"] as? [[String: Any]] else { return nil }
        let lines = segments.compactMap { segment -> String? in
            guard let text = segment["text"] as? String else { return nil }
            let cleaned = normalized(text)
            guard !cleaned.isEmpty else { return nil }
            let timestamps = segment["timestamps"] as? [String: Any]
            let start = (timestamps?["from"] as? String)?.split(separator: ",").first.map(String.init)
                ?? "00:00:00"
            return "[\(start)] \(cleaned)"
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func timestamp(seconds: Double) -> String {
        let total = max(0, Int(seconds))
        func twoDigits(_ value: Int) -> String {
            value < 10 ? "0\(value)" : String(value)
        }
        return "\(twoDigits(total / 3_600)):\(twoDigits((total / 60) % 60)):\(twoDigits(total % 60))"
    }
}
