import SwiftUI

final class Localizer: ObservableObject {
    @Published var isSpanish: Bool = UserDefaults.standard.string(forKey: "lang") != "en" {
        didSet { UserDefaults.standard.set(isSpanish ? "es" : "en", forKey: "lang") }
    }

    /// Returns the string for the active language.
    func t(_ es: String, _ en: String) -> String { isSpanish ? es : en }
}
