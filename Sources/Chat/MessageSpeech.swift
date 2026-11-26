// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import NaturalLanguage
import SwiftUI

/// Reads assistant replies aloud with the system's on-device speech synthesizer.
@MainActor
final class MessageSpeech: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = MessageSpeech()

    /// ID of the message being read; nil when idle.
    @Published private(set) var speakingMessageID: UUID?

    private struct Tracked {
        let utterance: AVSpeechUtterance
        var active: Bool
    }

    private let synthesizer = AVSpeechSynthesizer()
    /// Held until their callback so an address isn't reused; `stop()` clears `active`
    /// so late callbacks from a cancelled reading can't reset the next one.
    private var tracked: [ObjectIdentifier: Tracked] = [:]

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Starts reading `text` for message `id`, or stops if that message is
    /// already being read.
    func toggle(text: String, id: UUID) {
        if speakingMessageID == id { stop() } else { speak(text: text, id: id) }
    }

    func speak(text: String, id: UUID) {
        stop()
        let lines = Self.spokenLines(from: text)
        guard !lines.isEmpty else { return }
        let sample = lines.map(\.text).joined(separator: " ")
        let voice = Self.voice(forLanguage: Self.detectLanguage(sample))
        speakingMessageID = id
        for line in lines {
            let utterance = AVSpeechUtterance(string: line.text)
            utterance.voice = voice
            // Short pause between lines, a longer one between paragraphs and
            // stanzas, so verse and lists are not read as one run-on stream.
            utterance.postUtteranceDelay = line.endsParagraph ? 0.5 : 0.12
            tracked[ObjectIdentifier(utterance)] = Tracked(utterance: utterance, active: true)
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        for key in tracked.keys { tracked[key]?.active = false }
        speakingMessageID = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.finished(id) }
    }

    private func finished(_ id: ObjectIdentifier) {
        guard tracked.removeValue(forKey: id) != nil else { return }
        if !tracked.values.contains(where: \.active) { speakingMessageID = nil }
    }

    // MARK: Language and voice

    /// Dominant language of the text as a BCP-47 prefix ("de", "uk", "es"...).
    nonisolated static func detectLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(600)))
        return recognizer.dominantLanguage?.rawValue
    }

    /// Best installed voice for the language: Premium > Enhanced > Default.
    /// Novelty and Personal voices are skipped. nil falls back to the system
    /// voice when nothing matches.
    static func voice(forLanguage code: String?) -> AVSpeechSynthesisVoice? {
        guard let base = code?.prefix(2).lowercased(), !base.isEmpty else { return nil }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                voice.language.lowercased().hasPrefix(base + "-")
                    && !voice.voiceTraits.contains(.isNoveltyVoice)
                    && !voice.voiceTraits.contains(.isPersonalVoice)
            }
            .max { $0.quality.rawValue < $1.quality.rawValue }
    }

    // MARK: Text preparation

    struct SpokenLine: Equatable {
        let text: String
        let endsParagraph: Bool
    }

    /// Markdown reply → lines worth reading, with paragraph boundaries.
    nonisolated static func spokenLines(from markdown: String) -> [SpokenLine] {
        var out: [SpokenLine] = []
        for paragraph in plainText(from: markdown).components(separatedBy: "\n\n") {
            let lines = paragraph.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { line in line.contains { $0.isLetter || $0.isNumber } }
            for (index, line) in lines.enumerated() {
                out.append(SpokenLine(text: line, endsParagraph: index == lines.count - 1))
            }
        }
        return out
    }

    /// Strips markdown that would be read literally (code blocks, link URLs,
    /// emphasis markers, table pipes). Line-anchored rules use `[ \t]` rather
    /// than `\s` so they never swallow the blank line between paragraphs.
    nonisolated static func plainText(from markdown: String) -> String {
        let rules: [(pattern: String, template: String)] = [
            (#"<think>[\s\S]*?(</think>|$)"#, ""),
            (#"```[\s\S]*?(```|$)"#, "\n\n"),
            (#"!\[[^\]]*\]\([^)]*\)"#, ""),
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
            (#"<[^>]+>"#, ""),
            (#"(?m)^[ \t]{0,3}#{1,6}[ \t]*"#, ""),
            (#"(?m)^[ \t]*>+[ \t]?"#, ""),
            (#"(?m)^[ \t]*[-*_]{3,}[ \t]*$"#, ""),
            (#"(?m)^[ \t]*\|?[ \t:|-]+\|[ \t:|-]*$"#, ""),
            (#"(?m)^[ \t]*[-*+•][ \t]+"#, ""),
            (#"(\*\*|__)(.+?)\1"#, "$2"),
            (#"(?<![\w*])\*(?![ \t])(.+?)(?<![ \t])\*(?![\w*])"#, "$1"),
            (#"(?<!\w)_(?![ \t])(.+?)(?<![ \t])_(?!\w)"#, "$1"),
            (#"`([^`]*)`"#, "$1"),
            (#"(?m)^[ \t]*\||\|[ \t]*$"#, ""),
            (#"[ \t]*\|[ \t]*"#, ", "),
            (#"[ \t]{2,}"#, " "),
        ]
        var s = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        for rule in rules {
            s = s.replacingOccurrences(of: rule.pattern, with: rule.template,
                                       options: .regularExpression)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Action-row button that reads one assistant message aloud. It observes the
/// speech service itself, so only this button re-renders while speaking and
/// the equatable message bubbles keep skipping their markdown re-parse.
struct SpeakMessageButton: View {
    let message: ChatMessage

    @EnvironmentObject var loc: Localizer
    @ObservedObject private var speech = MessageSpeech.shared

    var body: some View {
        let active = speech.speakingMessageID == message.id
        let help = active ? loc.t("Detener lectura", "Stop reading")
                          : loc.t("Leer en voz alta", "Read aloud")
        Button {
            speech.toggle(text: message.parts.body, id: message.id)
        } label: {
            Label(help, systemImage: active ? "stop.circle" : "speaker.wave.2")
                .labelStyle(.iconOnly)
                .font(.system(size: 12))
                .foregroundStyle(active ? Color.appAccent : Color.secondary)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
