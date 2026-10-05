import XCTest
@testable import NoteSearchCore

final class IndexServiceTests: IndexTestCase {
    func testIndexesOnlySupportedVisibleFiles() async throws {
        try fx.write("a.md", "alpha")
        try fx.write("B.TXT", "beta")
        try fx.write("sub/d.json", "{\"k\": 1}")
        try fx.writeData("c.png", Data([0x89, 0x50, 0x4E, 0x47]))
        try fx.write("node_modules/x.md", "ignored")
        try fx.write("Images/y.md", "ignored")
        try fx.write(".hidden/z.md", "ignored")

        let skipped = try await fx.reindex()

        XCTAssertEqual(skipped, 0)
        XCTAssertEqual(fx.index.getDocumentCount(), 3)
    }

    func testBrokenFileIsSkippedAndDoesNotStopIndexing() async throws {
        try fx.write("good.md", "normal text")
        try fx.writeData("broken.md", Data([0xFF, 0xFE, 0xFA, 0x0A]))

        let skipped = try await fx.reindex()

        XCTAssertEqual(skipped, 1)
        XCTAssertEqual(fx.index.getDocumentCount(), 1)
    }

    func testOversizedFileIsSkipped() async throws {
        try fx.write("small.md", "ok")
        try fx.writeData("huge.md", Data(repeating: 0x61, count: 10_000_001))

        let skipped = try await fx.reindex()

        XCTAssertEqual(skipped, 1)
        XCTAssertEqual(fx.index.getDocumentCount(), 1)
    }

    func testExclusionsByNameAndByPath() async throws {
        let excludedPath = fx.root.appendingPathComponent("Учёба/Скрытые").path
        fx.index.setExcludedEntries(IndexService.defaultExclusions + ["drafts", excludedPath])

        try fx.write("drafts/a.md", "hidden by name")
        try fx.write("Учёба/Скрытые/b.md", "hidden by path")
        try fx.write("Учёба/ok.md", "visible")

        try await fx.reindex()

        XCTAssertEqual(fx.index.getDocumentCount(), 1)
        XCTAssertEqual(fx.names(try fx.search.search(query: "visible")), ["ok.md"])
    }

    func testChangingSupportedExtensions() async throws {
        fx.index.setSupportedExtensions(["log"])
        try fx.write("a.log", "log entry")
        try fx.write("b.md", "markdown note")

        try await fx.reindex()

        XCTAssertEqual(fx.index.getDocumentCount(), 1)
    }

    func testReindexReplacesPreviousContent() async throws {
        try fx.write("a.md", "first version")
        try await fx.reindex()

        try fx.remove("a.md")
        try fx.write("b.md", "second version")
        try await fx.reindex()

        XCTAssertEqual(fx.index.getDocumentCount(), 1)
        XCTAssertEqual(fx.names(try fx.search.search(query: "second")), ["b.md"])
        XCTAssertTrue(try fx.search.search(query: "first").isEmpty)
    }

    func testClearIndexRemovesEverything() async throws {
        try fx.write("a.md", "alpha")
        try await fx.reindex()
        XCTAssertEqual(fx.index.getDocumentCount(), 1)

        fx.index.clearIndex()

        XCTAssertEqual(fx.index.getDocumentCount(), 0)
        XCTAssertTrue(try fx.search.search(query: "alpha").isEmpty)
        XCTAssertNil(fx.index.lastIndexedDate)
    }

    func testIndexSizeAndLastIndexedDateAfterIndexing() async throws {
        XCTAssertNil(fx.index.lastIndexedDate)

        try fx.write("a.md", String(repeating: "text ", count: 200))
        try await fx.reindex()

        XCTAssertNotNil(fx.index.lastIndexedDate)
        XCTAssertGreaterThan(fx.index.indexSizeBytes(), 0)
    }

    func testIndexExistsReflectsDocuments() async throws {
        XCTAssertFalse(fx.index.indexExists())
        try fx.write("a.md", "alpha")
        try await fx.reindex()
        XCTAssertTrue(fx.index.indexExists())
    }
}
