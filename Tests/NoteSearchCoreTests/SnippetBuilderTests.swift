import XCTest
@testable import NoteSearchCore

final class SnippetBuilderTests: XCTestCase {
    private func word(_ text: String) -> QueryTerm { QueryTerm(text: text, isPhrase: false) }
    private func phrase(_ text: String) -> QueryTerm { QueryTerm(text: text, isPhrase: true) }

    private func slices(_ text: String, _ ranges: [Range<String.Index>]) -> [String] {
        ranges.map { String(text[$0]) }
    }

    private func offsets(_ text: String, _ ranges: [Range<String.Index>]) -> [Int] {
        ranges.map { text.distance(from: text.startIndex, to: $0.lowerBound) }
    }

    func testFindsRussianTextIgnoringCase() {
        let text = "ДОМАШНИЙ СЕРВЕР и домашний сервер"
        let ranges = SnippetBuilder.findRanges(in: text, terms: [word("домашний")])
        XCTAssertEqual(slices(text, ranges), ["ДОМАШНИЙ", "домашний"])
    }

    func testWordTermMatchesOnlyAtWordStart() {
        let text = "observer server serverless"
        let ranges = SnippetBuilder.findRanges(in: text, terms: [word("serv")])
        XCTAssertEqual(slices(text, ranges), ["serv", "serv"])
        XCTAssertEqual(offsets(text, ranges), [9, 16])
    }

    func testPhraseRequiresWholeWords() {
        let text = "домашний серверный и домашний сервер."
        let ranges = SnippetBuilder.findRanges(in: text, terms: [phrase("домашний сервер")])
        XCTAssertEqual(slices(text, ranges), ["домашний сервер"])
        XCTAssertEqual(offsets(text, ranges), [21])
    }

    func testRangesAreSortedByPosition() {
        let text = "beta alpha beta alpha"
        let ranges = SnippetBuilder.findRanges(in: text, terms: [word("alpha"), word("beta")])
        XCTAssertEqual(slices(text, ranges), ["beta", "alpha", "beta", "alpha"])
    }

    func testAnalyzeCountsTotalAndWholeWordMatches() {
        let stat = SnippetBuilder.analyze(text: "server serverless Server", term: word("server"))
        XCTAssertEqual(stat.total, 3)
        XCTAssertEqual(stat.whole, 2)
    }

    func testAnalyzeIgnoresMidWordMatches() {
        let stat = SnippetBuilder.analyze(text: "observer", term: word("serv"))
        XCTAssertEqual(stat.total, 0)
        XCTAssertEqual(stat.whole, 0)
    }

    func testSnippetContextIs180CharsBeforeAnd300After() {
        var before = Array(repeating: "a", count: 500)
        before[321] = "S"
        var tail = [" "] + Array(repeating: "b", count: 600)
        tail[299] = "E"
        let text = before.joined() + " nsaccept" + tail.joined()

        let snippets = SnippetBuilder.build(text: text, terms: [word("nsaccept")])

        XCTAssertEqual(snippets.count, 1)
        let snippet = snippets[0]
        XCTAssertEqual(snippet.text.first, "S")
        XCTAssertEqual(snippet.text.last, "E")
        XCTAssertEqual(snippet.text.count, 180 + "nsaccept".count + 300)
        XCTAssertEqual(snippet.matchRanges.count, 1)
        XCTAssertEqual(slices(snippet.text, snippet.matchRanges), ["nsaccept"])
        XCTAssertEqual(snippet.lineNumber, 1)
    }

    func testNearbyMatchesShareOneSnippet() {
        let text = "token " + String(repeating: "x", count: 50) + " token"
        let snippets = SnippetBuilder.build(text: text, terms: [word("token")])
        XCTAssertEqual(snippets.count, 1)
        XCTAssertEqual(snippets[0].matchRanges.count, 2)
    }

    func testDistantMatchesGetSeparateSnippets() {
        let text = "token " + String(repeating: "x", count: 1000) + " token"
        let snippets = SnippetBuilder.build(text: text, terms: [word("token")])
        XCTAssertEqual(snippets.count, 2)
    }

    func testLineNumberPointsToSnippetStart() {
        let text = String(repeating: "x\n", count: 100) + "nsaccept"
        let snippets = SnippetBuilder.build(text: text, terms: [word("nsaccept")])
        XCTAssertEqual(snippets.count, 1)
        XCTAssertEqual(snippets[0].lineNumber, 11)
    }

    func testSnippetCountIsLimited() {
        let block = "token " + String(repeating: "x", count: 1000) + "\n"
        let text = String(repeating: block, count: 60)
        let snippets = SnippetBuilder.build(text: text, terms: [word("token")])
        XCTAssertEqual(snippets.count, 50)
    }

    func testNoMatchesGiveNoSnippets() {
        XCTAssertTrue(SnippetBuilder.build(text: "hello world", terms: [word("zzz")]).isEmpty)
    }
}
