import XCTest
@testable import NoteSearchCore

final class QueryParserTests: XCTestCase {
    private func word(_ text: String) -> QueryTerm { QueryTerm(text: text, isPhrase: false) }
    private func phrase(_ text: String) -> QueryTerm { QueryTerm(text: text, isPhrase: true) }

    func testSplitsWordsWithoutQuotes() {
        XCTAssertEqual(
            QueryParser.terms(from: "docker compose"),
            [word("docker"), word("compose")]
        )
    }

    func testQuotedPhraseIsOneTerm() {
        XCTAssertEqual(
            QueryParser.terms(from: "\"домашний сервер\""),
            [phrase("домашний сервер")]
        )
    }

    func testMixedWordsAndPhrase() {
        XCTAssertEqual(
            QueryParser.terms(from: "docker \"home server\" nginx"),
            [word("docker"), phrase("home server"), word("nginx")]
        )
    }

    func testUnclosedQuoteIsTreatedAsPhrase() {
        XCTAssertEqual(
            QueryParser.terms(from: "\"home server"),
            [phrase("home server")]
        )
    }

    func testDropsTermsWithoutLettersOrDigits() {
        XCTAssertEqual(
            QueryParser.terms(from: "--- docker ???"),
            [word("docker")]
        )
    }

    func testEmptyAndWhitespaceQueriesGiveNoTerms() {
        XCTAssertTrue(QueryParser.terms(from: "").isEmpty)
        XCTAssertTrue(QueryParser.terms(from: "    ").isEmpty)
    }

    func testHyphenAndUnderscoreStayInsideWord() {
        XCTAssertEqual(
            QueryParser.terms(from: "uv-proekt my_var"),
            [word("uv-proekt"), word("my_var")]
        )
    }

    func testFtsQueryUsesPrefixForWordsAndExactForPhrases() {
        let terms = QueryParser.terms(from: "docker \"домашний сервер\"")
        XCTAssertEqual(
            QueryParser.ftsQuery(from: terms),
            "\"docker\"* AND \"домашний сервер\""
        )
    }

    func testQuotedSingleWordIsExact() {
        let terms = QueryParser.terms(from: "\"docker\"")
        XCTAssertEqual(QueryParser.ftsQuery(from: terms), "\"docker\"")
    }

    func testHyphenatedWordBecomesPrefixPhrase() {
        let terms = QueryParser.terms(from: "uv-proekt")
        XCTAssertEqual(QueryParser.ftsQuery(from: terms), "\"uv-proekt\"*")
    }
}
