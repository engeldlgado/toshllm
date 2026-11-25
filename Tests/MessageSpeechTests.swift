import XCTest
@testable import ToshLLM

final class MessageSpeechTests: XCTestCase {
    func testPlainTextDropsCodeBlocksThinkingAndLinkTargets() {
        let md = """
        <think>internal</think>**Hello** [docs](https://example.com) and `code`.

        ```swift
        let x = 1
        ```

        Done.
        """
        let plain = MessageSpeech.plainText(from: md)
        XCTAssertFalse(plain.contains("internal"))
        XCTAssertFalse(plain.contains("let x"))
        XCTAssertFalse(plain.contains("https"))
        XCTAssertTrue(plain.contains("Hello docs and code."))
        XCTAssertTrue(plain.contains("Done."))
    }

    func testPlainTextKeepsSnakeCaseAndMath() {
        let plain = MessageSpeech.plainText(from: "Use snake_case_name and 2 * 3 * 4.")
        XCTAssertEqual(plain, "Use snake_case_name and 2 * 3 * 4.")
    }

    func testStanzasKeepLineBreaksAndParagraphEnds() {
        let poem = "## Тіні\n\nРядок один,\nРядок два.\n\nНова строфа."
        let lines = MessageSpeech.spokenLines(from: poem)
        XCTAssertEqual(lines.map(\.text), ["Тіні", "Рядок один,", "Рядок два.", "Нова строфа."])
        XCTAssertEqual(lines.map(\.endsParagraph), [true, false, true, true])
    }

    func testListMarkersAndTablePipesAreNotRead() {
        let md = "- first\n- second\n\n| a | b |\n|---|---|\n| 1 | 2 |"
        let plain = MessageSpeech.plainText(from: md)
        XCTAssertFalse(plain.contains("-"))
        XCTAssertFalse(plain.contains("|"))
        XCTAssertTrue(plain.contains("first\nsecond"))
    }

    func testDetectsLanguageOfTypicalReplies() {
        XCTAssertEqual(MessageSpeech.detectLanguage("Він — оксамитова пляма на світлій підлозі, тихий хижак із грацією."), "uk")
        XCTAssertEqual(MessageSpeech.detectLanguage("Die Katze schläft den ganzen Tag auf dem warmen Fensterbrett."), "de")
    }
}
