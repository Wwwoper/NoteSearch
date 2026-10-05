import XCTest
@testable import NoteSearchCore

final class IndexUpdateTests: IndexTestCase {
    private func reconcile() async -> ReconcileResult {
        await fx.index.reconcile { _ in }
    }

    private func search(_ query: String) throws -> [String] {
        fx.names(try fx.search.search(query: query))
    }

    // MARK: - Сверка при старте

    func testReconcileDetectsAddedUpdatedAndRemovedFiles() async throws {
        try fx.write("a.md", "alpha")
        try fx.write("b.md", "beta")
        try fx.write("c.md", "gamma")
        try await fx.reindex()

        try fx.write("d.md", "delta")
        try fx.write("b.md", "beta changed with longer content")
        try fx.remove("c.md")

        let result = await reconcile()

        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(fx.index.getDocumentCount(), 3)
        XCTAssertEqual(try search("delta"), ["d.md"])
        XCTAssertEqual(try search("changed"), ["b.md"])
        XCTAssertTrue(try search("gamma").isEmpty)
    }

    func testReconcileWithoutChangesReportsNothing() async throws {
        try fx.write("a.md", "alpha")
        try await fx.reindex()

        let result = await reconcile()

        XCTAssertEqual(result.changed, 0)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(fx.index.getDocumentCount(), 1)
    }

    func testReconcileTreatsMoveAsRemoveAndAdd() async throws {
        try fx.write("a.md", "moving note")
        try await fx.reindex()

        try fx.move("a.md", to: "sub/a2.md")
        let result = await reconcile()

        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(try search("moving"), ["a2.md"])
    }

    func testReconcileRemovesFilesThatBecameExcluded() async throws {
        try fx.write("sub/a.md", "inside sub")
        try fx.write("keep.md", "stay here")
        try await fx.reindex()
        XCTAssertEqual(fx.index.getDocumentCount(), 2)

        fx.index.setExcludedEntries(IndexService.defaultExclusions + ["sub"])
        let result = await reconcile()

        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(fx.index.getDocumentCount(), 1)
    }

    func testReconcileKeepsIndexWhenRootIsMissing() async throws {
        try fx.write("a.md", "alpha")
        try fx.write("b.md", "beta")
        try await fx.reindex()

        try FileManager.default.removeItem(at: fx.root)
        let result = await reconcile()

        XCTAssertEqual(result.changed, 0)
        XCTAssertEqual(fx.index.getDocumentCount(), 2)
    }

    func testReconcileRetriesBrokenFilesWithoutReportingChanges() async throws {
        try fx.write("good.md", "text")
        try fx.writeData("broken.md", Data([0xFF, 0xFE, 0xFA]))
        try await fx.reindex()

        let result = await reconcile()

        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.changed, 0)
    }

    // MARK: - События файловой системы

    func testApplyChangesIndexesCreatedFile() throws {
        let file = try fx.write("new.md", "fresh note")

        let changed = fx.index.applyChanges([FileEvent(path: file.path, flags: FSFlag.created)])

        XCTAssertTrue(changed)
        XCTAssertEqual(try search("fresh"), ["new.md"])
    }

    func testApplyChangesUpdatesModifiedFile() async throws {
        let file = try fx.write("a.md", "old content")
        try await fx.reindex()

        try fx.write("a.md", "brand new content")
        let changed = fx.index.applyChanges([FileEvent(path: file.path, flags: FSFlag.modified)])

        XCTAssertTrue(changed)
        XCTAssertTrue(try search("old").isEmpty)
        XCTAssertEqual(try search("brand"), ["a.md"])
        XCTAssertEqual(fx.index.getDocumentCount(), 1)
    }

    func testApplyChangesRemovesDeletedFile() async throws {
        let file = try fx.write("a.md", "to delete")
        try await fx.reindex()

        try fx.remove("a.md")
        let changed = fx.index.applyChanges([FileEvent(path: file.path, flags: FSFlag.removed)])

        XCTAssertTrue(changed)
        XCTAssertEqual(fx.index.getDocumentCount(), 0)
    }

    func testApplyChangesRemovesWholeDeletedDirectory() async throws {
        try fx.write("dir/one.md", "first")
        try fx.write("dir/two.md", "second")
        try fx.write("keep.md", "third")
        try await fx.reindex()
        XCTAssertEqual(fx.index.getDocumentCount(), 3)

        try fx.remove("dir")
        let dirPath = fx.root.appendingPathComponent("dir").path
        let changed = fx.index.applyChanges([FileEvent(path: dirPath, flags: FSFlag.removed)])

        XCTAssertTrue(changed)
        XCTAssertEqual(fx.index.getDocumentCount(), 1)
    }

    func testApplyChangesIndexesDirectoryMovedIntoRoot() throws {
        try fx.write("incoming/a.md", "moved in alpha")
        try fx.write("incoming/deep/b.md", "moved in beta")
        let dirPath = fx.root.appendingPathComponent("incoming").path

        let changed = fx.index.applyChanges([FileEvent(path: dirPath, flags: FSFlag.created)])

        XCTAssertTrue(changed)
        XCTAssertEqual(fx.index.getDocumentCount(), 2)
    }

    func testApplyChangesIgnoresExcludedAndOutsidePaths() throws {
        let excluded = try fx.write("node_modules/pkg/index.md", "ignored")
        let outside = fx.base.appendingPathComponent("outside.md")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)

        let changed = fx.index.applyChanges([
            FileEvent(path: excluded.path, flags: FSFlag.created),
            FileEvent(path: outside.path, flags: FSFlag.created)
        ])

        XCTAssertFalse(changed)
        XCTAssertEqual(fx.index.getDocumentCount(), 0)
    }

    func testApplyChangesIgnoresUnsupportedExtension() throws {
        let image = try fx.writeData("pic.png", Data([0x89, 0x50]))

        let changed = fx.index.applyChanges([FileEvent(path: image.path, flags: FSFlag.created)])

        XCTAssertFalse(changed)
        XCTAssertEqual(fx.index.getDocumentCount(), 0)
    }

    func testRenamedFileKeepsSingleDocument() async throws {
        let oldFile = try fx.write("a.md", "renamed note")
        try await fx.reindex()

        try fx.move("a.md", to: "b.md")
        let newPath = fx.root.appendingPathComponent("b.md").path
        let changed = fx.index.applyChanges([
            FileEvent(path: oldFile.path, flags: FSFlag.renamed),
            FileEvent(path: newPath, flags: FSFlag.renamed)
        ])

        XCTAssertTrue(changed)
        XCTAssertEqual(fx.index.getDocumentCount(), 1)
        XCTAssertEqual(try search("renamed"), ["b.md"])
    }

    // MARK: - FileWatcher

    func testWatcherReportsCreatedFile() throws {
        let watcher = FileWatcher()
        let expectation = expectation(description: "FSEvents reported the new file")
        expectation.assertForOverFulfill = false
        let marker = "watched-\(UUID().uuidString).md"

        watcher.start(path: fx.root.path) { events in
            if events.contains(where: { $0.path.hasSuffix(marker) }) {
                expectation.fulfill()
            }
        }
        Thread.sleep(forTimeInterval: 0.7)

        try fx.write(marker, "text")
        wait(for: [expectation], timeout: 10)
        watcher.stop()
    }
}
