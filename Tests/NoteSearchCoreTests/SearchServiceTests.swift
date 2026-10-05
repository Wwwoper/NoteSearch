import XCTest
@testable import NoteSearchCore

final class SearchServiceTests: IndexTestCase {
    private func seed() async throws {
        try fx.write("Настройка сервера.md",
                     "# Домашний сервер\n\nНастройка docker compose для домашнего сервера.")
        try fx.write("Заметка.md", "ДОМАШНИЙ СЕРВЕР в верхнем регистре")
        try fx.write("only-docker.md", "docker only")
        try fx.write("only-compose.txt", "compose only")
        try fx.write("01-uv-proekt.md", "uv-proekt-i-docker")
        try fx.write("observer.md", "observer")
        try await fx.reindex()
    }

    private func search(_ query: String) throws -> [String] {
        fx.names(try fx.search.search(query: query))
    }

    func testMultipleWordsRequireAllOfThem() async throws {
        try await seed()
        XCTAssertEqual(try search("docker compose"), ["Настройка сервера.md"])
    }

    func testSearchIsCaseInsensitiveForRussian() async throws {
        try await seed()
        XCTAssertEqual(Set(try search("ДОМАШНИЙ")), ["Настройка сервера.md", "Заметка.md"])
        XCTAssertEqual(Set(try search("домашний")), ["Настройка сервера.md", "Заметка.md"])
    }

    func testQuotedPhraseIsExact() async throws {
        try await seed()
        XCTAssertEqual(Set(try search("\"домашний сервер\"")), ["Настройка сервера.md", "Заметка.md"])
    }

    func testPhraseDoesNotMatchWordPrefix() async throws {
        try await seed()
        XCTAssertTrue(try search("\"домашний серв\"").isEmpty)
    }

    func testPrefixSearchFindsWordsByBeginning() async throws {
        try await seed()
        XCTAssertEqual(
            Set(try search("dock")),
            ["Настройка сервера.md", "only-docker.md", "01-uv-proekt.md"]
        )
        XCTAssertEqual(Set(try search("comp")), ["Настройка сервера.md", "only-compose.txt"])
    }

    func testPrefixSearchDoesNotMatchMiddleOfWord() async throws {
        try await seed()
        XCTAssertTrue(try search("serv").isEmpty)
    }

    func testPrefixesOfSeveralWordsAreCombined() async throws {
        try await seed()
        XCTAssertEqual(try search("dock comp"), ["Настройка сервера.md"])
    }

    func testHyphenatedQueryWorks() async throws {
        try await seed()
        XCTAssertEqual(try search("uv-proekt"), ["01-uv-proekt.md"])
        XCTAssertEqual(try search("uv-pro"), ["01-uv-proekt.md"])
    }

    func testPunctuationOnlyQueryReturnsNothing() async throws {
        try await seed()
        XCTAssertTrue(try search("---").isEmpty)
    }

    func testEmptyIndexReturnsNothing() throws {
        XCTAssertTrue(try search("anything").isEmpty)
    }

    func testRelativePathIsBuiltFromRoot() async throws {
        try fx.write("Учёба/Конспекты (2026)/Лекция.md", "lecturetoken")
        try await fx.reindex()

        let results = try fx.search.search(query: "lecturetoken")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].relativePath, "Учёба/Конспекты (2026)/Лекция.md")
        XCTAssertEqual(results[0].fileName, "Лекция.md")
    }

    func testMatchCountCountsAllOccurrences() async throws {
        try fx.write("many.md", "token one token two token three")
        try await fx.reindex()

        let results = try fx.search.search(query: "token")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].matchCount, 3)
    }

    func testRankingPrefersFilenameThenWholeWordThenPrefix() async throws {
        try fx.write("setup.md", "serverless setup nsrank")
        try fx.write("misc.md", "a long text mentioning server once nsrank")
        try fx.write("server.md", "the server config nsrank")
        try await fx.reindex()

        XCTAssertEqual(try search("server"), ["server.md", "misc.md", "setup.md"])
    }

    func testChangedContentIsSearchableAfterReindex() async throws {
        try fx.write("a.md", "initial words")
        try await fx.reindex()
        XCTAssertEqual(try search("initial"), ["a.md"])

        try fx.write("a.md", "replacement text")
        try await fx.reindex()

        XCTAssertTrue(try search("initial").isEmpty)
        XCTAssertEqual(try search("replacement"), ["a.md"])
    }
}
