import Foundation
import OSLog
import SQLite3
import CoreServices
import CryptoKit

enum NoteSearchRootAccessError: LocalizedError, Equatable {
    case unavailable(String)
    case denied(String)
    case notDirectory(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let path): return "Каталог недоступен: \(path)"
        case .denied(let path): return "Нет доступа к каталогу: \(path)"
        case .notDirectory(let path): return "Выбранный путь не является каталогом: \(path)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unavailable:
            return "Проверьте, что диск подключён, а выбранный каталог существует."
        case .denied:
            return "Разрешите NoteSearch доступ к этой папке в System Settings → Privacy & Security → Files and Folders, затем повторите индексацию."
        case .notDirectory:
            return "Выберите каталог с заметками."
        }
    }
}

struct IndexProgress {
    let current: Int
    let total: Int
}

struct ReconcileResult {
    var added = 0
    var updated = 0
    var removed = 0
    var skipped = 0

    var changed: Int { added + updated + removed }
}

struct FileEvent {
    let path: String
    let flags: UInt32
}

enum FSFlag {
    static let mustScanSubDirs: UInt32 = 0x1
    static let created: UInt32 = 0x100
    static let removed: UInt32 = 0x200
    static let renamed: UInt32 = 0x800
    static let modified: UInt32 = 0x1000
}

final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private var handler: (@Sendable ([FileEvent]) -> Void)?
    private let queue = DispatchQueue(label: "notesearch.filewatcher")

    func start(path: String, handler: @escaping @Sendable ([FileEvent]) -> Void) {
        stop()
        self.handler = handler

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self)
            var events: [FileEvent] = []
            for i in 0..<count {
                if let p = paths[i] as? String {
                    events.append(FileEvent(path: p, flags: eventFlags[i]))
                }
            }
            if !events.isEmpty {
                watcher.handler?(events)
            }
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else {
            AppLog.watch.error("Не удалось создать FSEvents-поток для пути: \(path, privacy: .private)")
            return
        }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        handler = nil
    }

    deinit {
        stop()
    }
}

final class IndexService: @unchecked Sendable {
    static let shared = IndexService()
    static let rootKey = "rootPath"
    private static let schemaVersion = 4
    private static let maxFileSize: Int64 = 10_000_000

    private let dbPath: String
    private var db: OpaquePointer?
    private let mutationLock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static let defaultExtensions: [String] = [
        "md", "markdown", "txt", "json", "yaml", "yml",
        "py", "js", "ts", "html", "htm", "css"
    ]

    static let defaultExclusions: [String] = [
        ".git", ".venv", "venv", "node_modules",
        "__pycache__", ".cache", ".build", "DerivedData", "Images"
    ]

    static let extensionsKey = "supportedExtensions"
    static let exclusionsKey = "excludedEntries"
    static let lastIndexedKey = "lastIndexedAt"

    var supportedExtensions: [String] {
        defaults.stringArray(forKey: Self.extensionsKey) ?? Self.defaultExtensions
    }

    var excludedEntries: [String] {
        defaults.stringArray(forKey: Self.exclusionsKey) ?? Self.defaultExclusions
    }

    var excludedDirectories: Set<String> {
        Set(excludedEntries.filter { !$0.contains("/") })
    }

    var excludedPaths: [String] {
        excludedEntries.filter { $0.hasPrefix("/") }
    }

    private let defaults: UserDefaults

    var databasePath: String { dbPath }

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let dir: URL
        if let directory {
            dir = directory
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            dir = support.appendingPathComponent("NoteSearch", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("index.db").path

        sqlite3_open_v2(
            dbPath,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        sqlite3_busy_timeout(db, 3000)
        execute("PRAGMA journal_mode=WAL")
        migrateIfNeeded()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Публичный API

    func rootURL() -> URL {
        if let path = defaults.string(forKey: Self.rootKey) {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Notes")
    }

    func getIndexedPath() -> URL? {
        rootURL()
    }

    func indexExists() -> Bool {
        getDocumentCount() > 0
    }

    func getDocumentCount() -> Int {
        scalarInt("SELECT COUNT(*) FROM documents")
    }

    @discardableResult
    func reindex(progressHandler: @escaping (IndexProgress) -> Void) async throws -> Int {
        performReindex(progressHandler)
    }

    func applyChanges(_ events: [FileEvent]) -> Bool {
        mutationLock.lock()
        defer { mutationLock.unlock() }

        let userRoot = rootURL().path
        let root = Self.realPath(userRoot)

        func normalize(_ p: String) -> String {
            if p == root || p.hasPrefix(root + "/") { return p }
            if p == userRoot || p.hasPrefix(userRoot + "/") {
                return root + String(p.dropFirst(userRoot.count))
            }
            return p
        }

        var changed = false

        for event in events {
            let path = normalize(event.path)
            guard path.hasPrefix(root + "/") else { continue }
            if isExcluded(path: path, root: root) { continue }

            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)

            if !exists {
                if removeDocument(path: path) { changed = true }
                if removeDocuments(underDirectory: path) { changed = true }
            } else if isDir.boolValue {
                let interesting = FSFlag.created | FSFlag.renamed | FSFlag.mustScanSubDirs
                if event.flags & interesting != 0 {
                    for file in scanDirectory(root: URL(fileURLWithPath: path)) {
                        if (try? upsert(file)) != nil { changed = true }
                    }
                }
            } else {
                let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
                if supportedExtensions.contains(ext) {
                    if (try? upsert(URL(fileURLWithPath: path))) != nil { changed = true }
                } else if removeDocument(path: path) {
                    changed = true
                }
            }
        }

        return changed
    }

    // MARK: - Канонические пути

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func canonicalExcludedPaths() -> [String] {
        let userRoot = rootURL().path
        let root = Self.realPath(userRoot)

        return excludedPaths
            .map { entry -> String in
                if entry == userRoot || entry.hasPrefix(userRoot + "/") {
                    return root + String(entry.dropFirst(userRoot.count))
                }
                return Self.realPath(entry)
            }
            .flatMap { pathVariants($0) }
    }

    // MARK: - Настройки и обслуживание индекса

    func setSupportedExtensions(_ values: [String]) {
        defaults.set(values, forKey: Self.extensionsKey)
    }

    func setExcludedEntries(_ values: [String]) {
        defaults.set(values, forKey: Self.exclusionsKey)
    }

    var lastIndexedDate: Date? {
        defaults.object(forKey: Self.lastIndexedKey) as? Date
    }

    func indexSizeBytes() -> Int64 {
        ["", "-wal", "-shm"].reduce(Int64(0)) { total, suffix in
            let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath + suffix)
            return total + ((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    func clearIndex() {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        execute("DELETE FROM documents_fts")
        execute("DELETE FROM documents")
        execute("VACUUM")
        defaults.removeObject(forKey: Self.lastIndexedKey)
    }

    private func isExcludedDirectory(_ url: URL) -> Bool {
        if excludedDirectories.contains(url.lastPathComponent) { return true }
        let path = url.path
        return excludedPaths.contains { pathVariants($0).contains(path) }
    }

    // MARK: - Сверка индекса с диском

    func reconcile(progressHandler: @escaping (IndexProgress) -> Void) async -> ReconcileResult {
        performReconcile(progressHandler)
    }

    private func performReconcile(_ progress: (IndexProgress) -> Void) -> ReconcileResult {
        mutationLock.lock()
        defer { mutationLock.unlock() }

        var result = ReconcileResult()
        let root = rootURL()

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return result
        }

        var disk: [String: (url: URL, modified: Double, size: Int64)] = [:]
        for url in scanDirectory(root: URL(fileURLWithPath: Self.realPath(root.path))) {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let size = Int64(values?.fileSize ?? 0)
            disk[url.path.precomposedStringWithCanonicalMapping] = (url: url, modified: modified, size: size)
        }

        var known: [String: (id: Int64, modified: Double, size: Int64)] = [:]
        var removedIDs: [Int64] = []

        if let db {
            var stmt: OpaquePointer?
            let sql = "SELECT id, path, modified_at, file_size FROM documents"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let pathC = sqlite3_column_text(stmt, 1) else { continue }
                    let key = String(cString: pathC).precomposedStringWithCanonicalMapping
                    let id = sqlite3_column_int64(stmt, 0)
                    if let old = known[key] {
                        removedIDs.append(old.id)
                    }
                    known[key] = (
                        id: id,
                        modified: sqlite3_column_double(stmt, 2),
                        size: sqlite3_column_int64(stmt, 3)
                    )
                }
                sqlite3_finalize(stmt)
            }
        }

        var items: [(url: URL, isNew: Bool)] = []

        for (key, file) in disk {
            if let doc = known[key] {
                if abs(doc.modified - file.modified) > 0.01 || doc.size != file.size {
                    items.append((url: file.url, isNew: false))
                }
            } else {
                items.append((url: file.url, isNew: true))
            }
        }

        for (key, doc) in known where disk[key] == nil {
            removedIDs.append(doc.id)
        }

        guard !items.isEmpty || !removedIDs.isEmpty else {
            return result
        }

        execute("BEGIN")

        for id in removedIDs {
            deleteDocument(id: id)
            result.removed += 1
        }

        for (index, item) in items.enumerated() {
            do {
                try upsert(item.url)
                if item.isNew {
                    result.added += 1
                } else {
                    result.updated += 1
                }
            } catch {
                result.skipped += 1
                AppLog.index.error("Пропущен файл при сверке: \(item.url.path, privacy: .private); причина: \(error.localizedDescription, privacy: .public)")
            }
            progress(IndexProgress(current: index + 1, total: items.count))
        }

        execute("COMMIT")

        if result.changed > 0 {
            defaults.set(Date(), forKey: Self.lastIndexedKey)
        }
        return result
    }

    // MARK: - Полная индексация

    private func performReindex(_ progress: (IndexProgress) -> Void) -> Int {
        mutationLock.lock()
        defer { mutationLock.unlock() }

        let root = rootURL()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        execute("BEGIN")
        execute("DELETE FROM documents_fts")
        execute("DELETE FROM documents")

        let files = scanDirectory(root: URL(fileURLWithPath: Self.realPath(root.path)))
        var skipped = 0

        for (i, file) in files.enumerated() {
            do {
                try upsert(file)
            } catch {
                skipped += 1
                AppLog.index.error("Пропущен файл: \(file.path, privacy: .private); причина: \(error.localizedDescription, privacy: .public)")
            }
            progress(IndexProgress(current: i + 1, total: files.count))
        }

        execute("COMMIT")
        defaults.set(Date(), forKey: Self.lastIndexedKey)
        return skipped
    }

    private func scanDirectory(root: URL) -> [URL] {
        var files: [URL] = []
        let excludedNames = excludedDirectories
        let excludedFullPaths = canonicalExcludedPaths()
        let extensions = Set(supportedExtensions)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return files
        }

        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                if excludedNames.contains(url.lastPathComponent) || excludedFullPaths.contains(url.path) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if extensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        return files
    }

    private func isExcluded(path: String, root: String) -> Bool {
        for excluded in canonicalExcludedPaths() {
            if path == excluded || path.hasPrefix(excluded + "/") { return true }
        }
        let relative = String(path.dropFirst(root.count))
        return relative.split(separator: "/").contains { component in
            component.hasPrefix(".") || excludedDirectories.contains(String(component))
        }
    }

    // MARK: - Операции с документами

    private func upsert(_ url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if size > Self.maxFileSize {
            throw NSError(domain: "IndexService", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Файл слишком большой"])
        }

        let content = try String(contentsOf: url, encoding: .utf8)
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let path = url.path
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let hash = SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let transient = self.transient

        removeDocument(path: path)

        let inserted = execute("""
        INSERT INTO documents
        (path, file_name, extension, modified_at, file_size, content_hash)
        VALUES (?, ?, ?, ?, ?, ?)
        """) { stmt in
            sqlite3_bind_text(stmt, 1, path, -1, transient)
            sqlite3_bind_text(stmt, 2, name, -1, transient)
            sqlite3_bind_text(stmt, 3, ext, -1, transient)
            sqlite3_bind_double(stmt, 4, modified)
            sqlite3_bind_int64(stmt, 5, size)
            sqlite3_bind_text(stmt, 6, hash, -1, transient)
        }

        guard inserted, let db else {
            throw NSError(domain: "IndexService", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Не удалось записать документ"])
        }

        let id = sqlite3_last_insert_rowid(db)

        execute("""
        INSERT INTO documents_fts (rowid, file_name, path, content, modified_at)
        VALUES (?, ?, ?, ?, ?)
        """) { stmt in
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_bind_text(stmt, 2, TextNormalizer.forIndex(name), -1, transient)
            sqlite3_bind_text(stmt, 3, TextNormalizer.forIndex(path), -1, transient)
            sqlite3_bind_text(stmt, 4, TextNormalizer.forIndex(content), -1, transient)
            sqlite3_bind_double(stmt, 5, modified)
        }
    }

    @discardableResult
    private func removeDocument(path: String) -> Bool {
        var removed = false
        for variant in pathVariants(path) {
            let ids = queryIDs("SELECT id FROM documents WHERE path = ?") { stmt in
                sqlite3_bind_text(stmt, 1, variant, -1, self.transient)
            }
            for id in ids {
                deleteDocument(id: id)
                removed = true
            }
        }
        return removed
    }

    private func removeDocuments(underDirectory path: String) -> Bool {
        var removed = false
        for variant in pathVariants(path) {
            let prefix = variant + "/"
            let length = Int32(prefix.unicodeScalars.count)
            let ids = queryIDs("SELECT id FROM documents WHERE substr(path, 1, ?) = ?") { stmt in
                sqlite3_bind_int(stmt, 1, length)
                sqlite3_bind_text(stmt, 2, prefix, -1, self.transient)
            }
            for id in ids {
                deleteDocument(id: id)
                removed = true
            }
        }
        return removed
    }

    private func deleteDocument(id: Int64) {
        execute("DELETE FROM documents_fts WHERE rowid = ?") { stmt in
            sqlite3_bind_int64(stmt, 1, id)
        }
        execute("DELETE FROM documents WHERE id = ?") { stmt in
            sqlite3_bind_int64(stmt, 1, id)
        }
    }

    private func pathVariants(_ path: String) -> [String] {
        var result = [path]
        let candidates = [
            path.precomposedStringWithCanonicalMapping,
            path.decomposedStringWithCanonicalMapping
        ]
        for candidate in candidates where !result.contains(candidate) {
            result.append(candidate)
        }
        return result
    }

    // MARK: - SQLite

    private func migrateIfNeeded() {
        if scalarInt("PRAGMA user_version") < Self.schemaVersion {
            execute("DROP TABLE IF EXISTS documents_fts")
            execute("DROP TABLE IF EXISTS documents")
            execute("""
            CREATE TABLE documents (
                id INTEGER PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                file_name TEXT NOT NULL,
                extension TEXT NOT NULL,
                modified_at REAL NOT NULL,
                file_size INTEGER NOT NULL,
                content_hash TEXT NOT NULL
            )
            """)
            execute("""
            CREATE VIRTUAL TABLE documents_fts USING fts5(
                file_name,
                path,
                content,
                modified_at UNINDEXED,
                tokenize='unicode61 remove_diacritics 2',
                prefix='2 3 4'
            )
            """)
            execute("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    @discardableResult
    private func execute(_ sql: String, bind: (OpaquePointer) -> Void = { _ in }) -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        let rc = sqlite3_step(stmt)
        return rc == SQLITE_DONE || rc == SQLITE_ROW
    }

    private func scalarInt(_ sql: String) -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private func queryIDs(_ sql: String, bind: (OpaquePointer) -> Void) -> [Int64] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        return ids
    }
}
