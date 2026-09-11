// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// App localization.
///
/// Spanish and English are the built-in languages, written inline at every call
/// site as `loc.t("es", "en")`. Additional languages are contributed as overlay
/// files in `Resources/lang/<code>.json` — a flat `{ "English string":
/// "translation" }` map keyed by the **English** string. At runtime any language
/// other than es/en looks the English text up in its overlay, falling back to
/// English when a key is missing or blank, so the UI never shows an empty label.
///
/// Adding a language is therefore drop-in: ship a `<code>.json` and it appears
/// in the Settings picker automatically. Run `scripts/extract-strings.py` to
/// regenerate the English key template translators start from.
final class Localizer: ObservableObject {
    /// Active language code ("es", "en", or any bundled community code).
    /// Defaults to English; the user can switch in Settings.
    @Published var language: String = UserDefaults.standard.string(forKey: SettingsKeys.language) ?? "en" {
        didSet {
            UserDefaults.standard.set(language, forKey: SettingsKeys.language)
            loadOverlay()
        }
    }

    /// English → translated string, for the active community language. Empty for
    /// the built-in es/en (they need no overlay).
    private var overlay: [String: String] = [:]

    /// Built-in languages first, then any `lang/<code>.json` found in the bundle.
    let availableLanguages: [String]

    init() {
        availableLanguages = Localizer.discoverLanguages()
        loadOverlay()
    }

    /// Kept for the many call sites that pick Spanish vs. English content
    /// directly (catalog details, relative dates). Community languages fall back
    /// to the English branch of those.
    var isSpanish: Bool { language == "es" }

    /// Engine diagnostics are built where no Localizer exists, so they carry both
    /// halves separated by " / ". Pick one instead of showing the pair.
    func half(_ bilingual: String) -> String {
        guard let r = bilingual.range(of: " / ") else { return bilingual }
        return String(isSpanish ? bilingual[..<r.lowerBound] : bilingual[r.upperBound...])
    }

    /// Returns the string for the active language.
    func t(_ es: String, _ en: String) -> String {
        switch language {
        case "es": return es
        case "en": return en
        default:
            if let v = overlay[en], !v.isEmpty { return v }
            return en
        }
    }

    /// Same lookup for a string carrying values. Interpolating them into the
    /// literal makes the key dynamic and the overlay never matches, so the key
    /// keeps `%@` placeholders and the values go in after the lookup.
    func t(_ es: String, _ en: String, _ args: String...) -> String {
        var out = t(es, en)
        for a in args {
            guard let r = out.range(of: "%@") else { break }
            out.replaceSubrange(r, with: a)
        }
        return out
    }

    /// Native display name (autonym) for a language code, e.g. "Italiano".
    func displayName(_ code: String) -> String {
        switch code {
        case "es": return "Español"
        case "en": return "English"
        default:
            let name = Locale(identifier: code).localizedString(forLanguageCode: code) ?? code
            return name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    // MARK: - Overlay loading

    private func loadOverlay() {
        guard language != "es", language != "en",
              let url = Localizer.langDirectory?.appendingPathComponent("\(language).json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { overlay = [:]; return }
        overlay = dict
    }

    private static var langDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("lang")
    }

    private static func discoverLanguages() -> [String] {
        var langs = ["es", "en"]
        if let dir = langDirectory,
           let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "json" {
                let code = f.deletingPathExtension().lastPathComponent
                if !code.hasPrefix("_"), !langs.contains(code) { langs.append(code) }
            }
        }
        return langs
    }
}
