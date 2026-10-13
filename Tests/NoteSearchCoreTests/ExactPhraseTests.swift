import XCTest
@testable import NoteSearchCore

final class ExactPhraseTests: XCTestCase {
    func testWrapsPlainQuery() {
        XCTAssertEqual(ExactPhrase.toggle("uv run --with"), "\"uv run --with\"")
    }

    func testUnwrapsQuotedQuery() {
        XCTAssertEqual(ExactPhrase.toggle("\"uv run --with\""), "uv run --with")
    }

    func testDoubleToggleReturnsOriginal() {
        let original = "домашний сервер"
        XCTAssertEqual(ExactPhrase.toggle(ExactPhrase.toggle(original)), original)
    }

    func testEmptyQueryStaysEmpty() {
        XCTAssertEqual(ExactPhrase.toggle(""), "")
    }

    func testWhitespaceOnlyQueryIsUnchanged() {
        XCTAssertEqual(ExactPhrase.toggle("   "), "   ")
    }

    func testTrimsSurroundingSpacesBeforeWrapping() {
        XCTAssertEqual(ExactPhrase.toggle("  docker  "), "\"docker\"")
    }

    func testSingleQuoteCharacterIsWrappedNotUnwrapped() {
        XCTAssertEqual(ExactPhrase.toggle("\""), "\"\"\"")
    }

    func testWrappedQueryIsParsedAsPhrase() {
        let wrapped = ExactPhrase.toggle("home server")
        XCTAssertEqual(
            QueryParser.terms(from: wrapped),
            [QueryTerm(text: "home server", isPhrase: true)]
        )
    }

    func testUnwrappedQueryIsParsedAsWords() {
        let unwrapped = ExactPhrase.toggle("\"home server\"")
        XCTAssertEqual(
            QueryParser.terms(from: unwrapped),
            [QueryTerm(text: "home", isPhrase: false),
             QueryTerm(text: "server", isPhrase: false)]
        )
    }
}