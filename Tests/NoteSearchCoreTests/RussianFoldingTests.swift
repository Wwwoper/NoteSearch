import XCTest
@testable import NoteSearchCore

final class RussianFoldingTests: IndexTestCase {
    private func seed() async throws {
        try fx.write("yo.md", "ёлка и всё")
        try fx.write("ye.md", "елка и все")
        try fx.write("yj.md", "мой край")
        try fx.write("yi.md", "мои краи")
        try fx.write(
            "nfd.md",
            "ёжик".decomposedStringWithCanonicalMapping + " " + "йога".decomposedStringWithCanonicalMapping
        )
        try await fx.reindex()
    }

    private func found(_ query: String) throws -> [String] {
        fx.names(try fx.search.search(query: query)).sorted()
    }

    private func word(_ text: String) -> QueryTerm {
        QueryTerm(text: text, isPhrase: false)
    }

    private func slices(_ text: String, _ ranges: [Range<String.Index>]) -> [String] {
        ranges.map { String(text[$0]) }
    }

    func testDiagnoseFoldingBehaviour() async throws {
        try await seed()
        for query in ["елка", "ёлка", "все", "всё", "мой", "мои", "край", "краи", "ёжик", "йога"] {
            print("FOLDING \(query) -> \(try found(query))")
        }
    }

    func testYoAndYeAreEquivalent() async throws {
        try await seed()
        XCTAssertEqual(try found("елка"), ["ye.md", "yo.md"])
        XCTAssertEqual(try found("ёлка"), ["ye.md", "yo.md"])
        XCTAssertEqual(try found("все"), ["ye.md", "yo.md"])
        XCTAssertEqual(try found("всё"), ["ye.md", "yo.md"])
    }

    func testYjAndYiAreDistinct() async throws {
        try await seed()
        XCTAssertEqual(try found("мой"), ["yj.md"])
        XCTAssertEqual(try found("мои"), ["yi.md"])
        XCTAssertEqual(try found("край"), ["yj.md"])
        XCTAssertEqual(try found("краи"), ["yi.md"])
    }

    func testDecomposedTextMatchesComposedQuery() async throws {
        try await seed()
        XCTAssertEqual(try found("ёжик"), ["nfd.md"])
        XCTAssertEqual(try found("еж"), ["nfd.md"])
        XCTAssertEqual(try found("йога"), ["nfd.md"])
    }

    func testHighlightingFollowsSearchRules() {
        let text = "мой и мои"
        XCTAssertEqual(slices(text, SnippetBuilder.findRanges(in: text, terms: [word("мои")])), ["мои"])
        XCTAssertEqual(slices(text, SnippetBuilder.findRanges(in: text, terms: [word("мой")])), ["мой"])

        let yo = "ёлка елка"
        XCTAssertEqual(SnippetBuilder.findRanges(in: yo, terms: [word("елка")]).count, 2)
        XCTAssertEqual(SnippetBuilder.findRanges(in: yo, terms: [word("ёлка")]).count, 2)
    }
}
