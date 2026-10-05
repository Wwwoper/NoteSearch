import XCTest
@testable import NoteSearchCore

final class IndexFixture {
    let base: URL
    let root: URL
    let defaults: UserDefaults
    let suiteName: String
    let index: IndexService
    let search: SearchService

    init() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath()
        let baseURL = tmp.appendingPathComponent("NoteSearchTests-\(UUID().uuidString)", isDirectory: true)
        let rootURL = baseURL.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let suite = "NoteSearchTests-\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suite)!
        testDefaults.set(rootURL.path, forKey: IndexService.rootKey)

        let indexService = IndexService(
            directory: baseURL.appendingPathComponent("Data", isDirectory: true),
            defaults: testDefaults
        )

        base = baseURL
        root = rootURL
        suiteName = suite
        defaults = testDefaults
        index = indexService
        search = SearchService(databasePath: indexService.databasePath, rootProvider: { rootURL })
    }

    @discardableResult
    func write(_ relative: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    func writeData(_ relative: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        return url
    }

    func remove(_ relative: String) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(relative))
    }

    func move(_ from: String, to destination: String) throws {
        let target = root.appendingPathComponent(destination)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: root.appendingPathComponent(from), to: target)
    }

    @discardableResult
    func reindex() async throws -> Int {
        try await index.reindex { _ in }
    }

    func names(_ results: [SearchResult]) -> [String] {
        results.map { $0.fileName }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: base)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

class IndexTestCase: XCTestCase {
    var fx: IndexFixture!

    override func setUpWithError() throws {
        fx = try IndexFixture()
    }

    override func tearDownWithError() throws {
        fx.cleanup()
        fx = nil
    }
}
