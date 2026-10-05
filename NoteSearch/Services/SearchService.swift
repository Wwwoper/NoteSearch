import Foundation
import OSLog
import SQLite3

enum TextNormalizer {
    static func nfc(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }

    static func forIndex(_ text: String) -> String {
        nfc(text)
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "Ё", with: "Е")
    }
}

struct QueryTerm: Equatable {
    let text: String
    let isPhrase: Bool
}

struct QueryParser {
    static func terms(from query: String) -> [QueryTerm] {
        var result: [QueryTerm] = []
        var current = ""
        var inQuotes = false

        func flush(asPhrase: Bool) {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            guard !trimmed.isEmpty,
                  trimmed.contains(where: { $0.isLetter || $0.isNumber }) else {
                return
            }
            result.append(QueryTerm(text: trimmed, isPhrase: asPhrase))
        }

        for ch in query {
            if ch == "\"" {
                flush(asPhrase: inQuotes)
                inQuotes.toggle()
            } else if ch.isWhitespace && !inQuotes {
                flush(asPhrase: false)
            } else {
                current.append(ch)
            }
        }
        flush(asPhrase: inQuotes)
        return result
    }

    static func ftsQuery(from terms: [QueryTerm]) -> String {
        terms.map { term -> String in
            let normalized = TextNormalizer.forIndex(term.text)
            let escaped = normalized.replacingOccurrences(of: "\"", with: "\"\"")
            return term.isPhrase ? "\"\(escaped)\"" : "\"\(escaped)\"*"
        }
        .joined(separator: " AND ")
    }
}

enum SnippetBuilder {
    static let charsBefore = 180
    static let charsAfter = 300

    private static func isWordCharacter(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber
    }

    private static func isWordStart(_ index: String.Index, in text: String) -> Bool {
        if index == text.startIndex { return true }
        return !isWordCharacter(text[text.index(before: index)])
    }

    private static func isWordEnd(_ index: String.Index, in text: String) -> Bool {
        if index == text.endIndex { return true }
        return !isWordCharacter(text[index])
    }

    /// Регулярное выражение для слова: регистр не важен, «е» и «ё» равнозначны,
    /// «й» и «и» различаются, остальные символы экранируются.
    private static func searchPattern(for term: String) -> String {
        var pattern = ""
        for ch in TextNormalizer.nfc(term) {
            switch ch {
            case "е", "Е", "ё", "Ё":
                pattern += "[еёЕЁ]"
            default:
                pattern += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        return pattern
    }

    private static func scan(
        text: String,
        term: QueryTerm,
        _ body: (Range<String.Index>, Bool) -> Void
    ) {
        guard !term.text.isEmpty else { return }

        let pattern = searchPattern(for: term.text)
        var start = text.startIndex

        while start < text.endIndex,
              let r = text.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive],
                range: start..<text.endIndex
              ) {
            let startsOK = isWordStart(r.lowerBound, in: text)
            let endsOK = isWordEnd(r.upperBound, in: text)

            if startsOK && (!term.isPhrase || endsOK) {
                body(r, endsOK)
                start = r.upperBound
            } else {
                start = text.index(after: r.lowerBound)
            }
        }
    }

    static func findRanges(in text: String, terms: [QueryTerm]) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        for term in terms {
            scan(text: text, term: term) { range, _ in
                ranges.append(range)
            }
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    static func analyze(text: String, term: QueryTerm) -> (total: Int, whole: Int) {
        var total = 0
        var whole = 0
        scan(text: text, term: term) { _, isWholeWord in
            total += 1
            if isWholeWord { whole += 1 }
        }
        return (total, whole)
    }

    // MARK: Огороженные блоки кода

    struct FenceBlock {
        let contentStart: String.Index
        let end: String.Index
        let language: String?
    }

    static func parseOpeningFence(_ trimmed: String) -> (marker: Character, count: Int, language: String?)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }

        let count = trimmed.prefix { $0 == first }.count
        guard count >= 3 else { return nil }

        let info = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
        if first == "`" && info.contains("`") { return nil }

        let token = info
            .split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," })
            .first
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".}")) }

        let language = (token?.isEmpty ?? true) ? nil : token?.lowercased()
        return (first, count, language)
    }

    static func isClosingFence(_ trimmed: String, marker: Character?, minCount: Int) -> Bool {
        guard let first = trimmed.first, first == "`" || first == "~" else { return false }
        if let marker, marker != first { return false }

        let count = trimmed.prefix { $0 == first }.count
        return count >= minCount && count == trimmed.count
    }

    static func fenceBlocks(in text: String) -> [FenceBlock] {
        var blocks: [FenceBlock] = []
        var open: (marker: Character, count: Int, language: String?, contentStart: String.Index)? = nil
        var index = text.startIndex

        while index < text.endIndex {
            let full = text.lineRange(for: index..<index)

            var contentEnd = full.upperBound
            while contentEnd > full.lowerBound, text[text.index(before: contentEnd)].isNewline {
                contentEnd = text.index(before: contentEnd)
            }
            let trimmed = text[full.lowerBound..<contentEnd].trimmingCharacters(in: .whitespaces)

            if let current = open {
                if isClosingFence(trimmed, marker: current.marker, minCount: current.count) {
                    blocks.append(
                        FenceBlock(
                            contentStart: current.contentStart,
                            end: full.lowerBound,
                            language: current.language
                        )
                    )
                    open = nil
                }
            } else if let fence = parseOpeningFence(trimmed) {
                open = (
                    marker: fence.marker,
                    count: fence.count,
                    language: fence.language,
                    contentStart: full.upperBound
                )
            }

            if full.upperBound <= index { break }
            index = full.upperBound
        }

        if let current = open {
            blocks.append(
                FenceBlock(
                    contentStart: current.contentStart,
                    end: text.endIndex,
                    language: current.language
                )
            )
        }
        return blocks
    }

    static func build(text: String, terms: [QueryTerm], maxSnippets: Int = 50) -> [SearchSnippet] {
        let matches = findRanges(in: text, terms: terms)
        guard !matches.isEmpty else { return [] }

        var windows: [(start: String.Index, end: String.Index)] = []
        for m in matches {
            let s = text.index(m.lowerBound, offsetBy: -charsBefore, limitedBy: text.startIndex) ?? text.startIndex
            let e = text.index(m.upperBound, offsetBy: charsAfter, limitedBy: text.endIndex) ?? text.endIndex
            if let last = windows.last, s <= last.end {
                windows[windows.count - 1].end = max(last.end, e)
            } else {
                windows.append((start: s, end: e))
            }
        }

        let blocks = fenceBlocks(in: text)

        return windows.prefix(maxSnippets).map { w in
            let snippetText = String(text[w.start..<w.end])
            let line = text[text.startIndex..<w.start].reduce(1) { $1.isNewline ? $0 + 1 : $0 }
            let block = blocks.first { $0.contentStart <= w.start && w.start <= $0.end }
            return SearchSnippet(
                text: snippetText,
                matchRanges: findRanges(in: snippetText, terms: terms),
                lineNumber: line,
                startsInCodeBlock: block != nil,
                codeLanguage: block?.language
            )
        }
    }
}

private struct Candidate {
    let path: String
    let name: String
    let modified: Date
    let relevance: Double
    let count: Int
    let exactTerms: Int
    let nameTerms: Int
}

final class SearchService: @unchecked Sendable {
    static let shared = SearchService()

    private let openLock = NSLock()

    private let dbPath: String
    private var db: OpaquePointer?
    private let rootProvider: () -> URL

    init(databasePath: String? = nil, rootProvider: (() -> URL)? = nil) {
        if let databasePath {
            dbPath = databasePath
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            let dir = support.appendingPathComponent("NoteSearch", isDirectory: true)
            dbPath = dir.appendingPathComponent("index.db").path
        }
        self.rootProvider = rootProvider ?? { IndexService.shared.rootURL() }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func openDatabase() -> OpaquePointer? {
        openLock.lock()
        defer { openLock.unlock() }

        if db == nil {
            guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return nil }
            sqlite3_busy_timeout(db, 3000)
        }
        return db
    }

    func search(query: String) throws -> [SearchResult] {
        guard let database = openDatabase() else {
            throw NSError(domain: "SearchService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Не удалось открыть базу данных"])
        }

        let terms = QueryParser.terms(from: query)
        guard !terms.isEmpty else { return [] }
        let fts = QueryParser.ftsQuery(from: terms)

        let rankExpression = "bm25(documents_fts, 8.0, 0.5, 1.0, 0.0)"

        let sql = """
        SELECT d.path, d.file_name, d.modified_at, \(rankExpression), documents_fts.content
        FROM documents_fts
        JOIN documents d ON documents_fts.rowid = d.id
        WHERE documents_fts MATCH ?
        ORDER BY \(rankExpression) ASC
        LIMIT 200
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "SearchService", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Не удалось подготовить SQL-запрос"])
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, fts, -1, transient)

        var candidates: [Candidate] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            try Task.checkCancellation()

            guard
                let pathC = sqlite3_column_text(statement, 0),
                let nameC = sqlite3_column_text(statement, 1)
            else { continue }

            let path = String(cString: pathC)
            let name = String(cString: nameC)
            let modified = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            let bm25 = sqlite3_column_double(statement, 3)

            var count = 0
            var exactTerms = 0
            var nameTerms = 0

            if let contentC = sqlite3_column_text(statement, 4) {
                let content = String(cString: contentC)
                for term in terms {
                    let stat = SnippetBuilder.analyze(text: content, term: term)
                    count += stat.total
                    if stat.whole > 0 { exactTerms += 1 }
                }
            }

            let normalizedName = TextNormalizer.nfc(name)
            for term in terms where SnippetBuilder.analyze(text: normalizedName, term: term).total > 0 {
                nameTerms += 1
            }

            candidates.append(
                Candidate(
                    path: path,
                    name: name,
                    modified: modified,
                    relevance: -bm25,
                    count: count,
                    exactTerms: exactTerms,
                    nameTerms: nameTerms
                )
            )
        }

        AppLog.search.debug("Поиск завершён: терминов \(terms.count, privacy: .public), кандидатов \(candidates.count, privacy: .public)")
        return rank(candidates, termCount: terms.count)
    }

    private func rank(_ candidates: [Candidate], termCount: Int) -> [SearchResult] {
        guard !candidates.isEmpty, termCount > 0 else { return [] }

        let maxRelevance = max(candidates.map { $0.relevance }.max() ?? 0, 1e-9)
        let now = Date()

        let scored: [(candidate: Candidate, score: Double)] = candidates.map { c in
            let relevance = max(c.relevance, 0) / maxRelevance
            let exact = Double(c.exactTerms) / Double(termCount)
            let name = Double(c.nameTerms) / Double(termCount)
            let ageDays = max(0, now.timeIntervalSince(c.modified) / 86_400)
            let recency = max(0, 1 - ageDays / 90)
            let score = relevance + 2.0 * exact + 1.5 * name + 0.3 * recency
            return (candidate: c, score: score)
        }

        let sorted = scored.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.candidate.name.localizedStandardCompare(right.candidate.name) == .orderedAscending
        }

        return sorted.prefix(100).map { item in
            let c = item.candidate
            let url = URL(fileURLWithPath: c.path)
            return SearchResult(
                fileURL: url,
                fileName: c.name,
                relativePath: relativePath(for: url),
                matchCount: max(c.count, 1),
                modifiedAt: c.modified,
                score: item.score,
                snippets: []
            )
        }
    }

    private func relativePath(for url: URL) -> String {
        let root = IndexService.realPath(rootProvider().path)
        let path = IndexService.realPath(url.path)
        if path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return path
    }
}

// MARK: - Сегменты фрагмента: текст и блоки кода

struct SnippetSegment: Identifiable, Equatable {
    let id: Int
    let isCode: Bool
    let language: String?
    let text: String
}

enum SnippetSegmenter {
    static func segments(for snippet: SearchSnippet) -> [SnippetSegment] {
        var result: [SnippetSegment] = []
        var buffer: [String] = []
        var inCode = snippet.startsInCodeBlock
        var language = snippet.codeLanguage
        var marker: (marker: Character, count: Int)? = nil

        func flush() {
            defer { buffer.removeAll() }
            let joined = buffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            result.append(
                SnippetSegment(
                    id: result.count,
                    isCode: inCode,
                    language: inCode ? language : nil,
                    text: joined
                )
            )
        }

        for rawLine in snippet.text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if inCode {
                if SnippetBuilder.isClosingFence(trimmed, marker: marker?.marker, minCount: marker?.count ?? 3) {
                    flush()
                    inCode = false
                    language = nil
                    marker = nil
                } else {
                    buffer.append(line)
                }
            } else if let fence = SnippetBuilder.parseOpeningFence(trimmed) {
                flush()
                inCode = true
                language = fence.language
                marker = (marker: fence.marker, count: fence.count)
            } else {
                buffer.append(line)
            }
        }
        flush()
        return result
    }
}

// MARK: - Подсветка синтаксиса

enum TokenKind: Equatable {
    case keyword, string, comment, number, variable, flag, key, literal, tag
}

struct CodeToken {
    let range: Range<String.Index>
    let kind: TokenKind
}

struct SyntaxRules {
    var lineComments: [String] = []
    var commentNeedsSpace = false
    var blockComment: (open: String, close: String)? = nil
    var quotes: [Character] = ["\"", "'"]
    var keywords: Set<String> = []
    var literals: Set<String> = []
    var caseInsensitive = false
    var hyphenInWords = false
    var shell = false
    var jsonKeys = false
    var colonKeys = false
    var markup = false
    var tripleQuotes = false
    var atRules = false
    var hexColors = false
}

enum CodeHighlighter {
    private static func words(_ list: String) -> Set<String> {
        Set(list.split(separator: " ").map(String.init))
    }

    static func canonicalLanguage(_ raw: String?) -> String? {
        guard let value = raw?.lowercased(), !value.isEmpty else { return nil }
        switch value {
        case "bash", "sh", "shell", "zsh", "console", "terminal", "shell-session", "shellsession":
            return "shell"
        case "py", "python", "python3", "py3":
            return "python"
        case "js", "javascript", "jsx", "mjs", "cjs", "ts", "typescript", "tsx":
            return "javascript"
        case "json", "jsonc", "json5":
            return "json"
        case "yaml", "yml":
            return "yaml"
        case "swift":
            return "swift"
        case "html", "htm", "xml", "svg", "xhtml":
            return "markup"
        case "css", "scss", "less":
            return "css"
        case "sql", "psql", "sqlite", "mysql":
            return "sql"
        case "go", "golang", "rust", "rs", "java", "kotlin", "kt", "c", "h", "cpp", "c++",
             "hpp", "cs", "csharp", "php":
            return "clike"
        default:
            return nil
        }
    }

    static func rules(for canonical: String) -> SyntaxRules? {
        switch canonical {
        case "shell":
            var r = SyntaxRules()
            r.lineComments = ["#"]
            r.commentNeedsSpace = true
            r.hyphenInWords = true
            r.shell = true
            r.keywords = words(
                "if then else elif fi for while until do done case esac function in select return exit break "
                + "continue export local readonly declare unset source alias cd echo set read shift trap eval exec"
            )
            return r
        case "python":
            var r = SyntaxRules()
            r.lineComments = ["#"]
            r.tripleQuotes = true
            r.keywords = words(
                "and as assert async await break class continue def del elif else except finally for from "
                + "global if import in is lambda nonlocal not or pass raise return try while with yield match case"
            )
            r.literals = words("True False None")
            return r
        case "javascript":
            var r = SyntaxRules()
            r.lineComments = ["//"]
            r.blockComment = (open: "/*", close: "*/")
            r.quotes = ["\"", "'", "`"]
            r.keywords = words(
                "const let var function return if else for while do switch case break continue new class "
                + "extends import from export default async await try catch finally throw typeof instanceof in "
                + "of this super interface type enum implements public private protected readonly static void "
                + "delete yield abstract declare namespace as"
            )
            r.literals = words("true false null undefined NaN Infinity")
            return r
        case "json":
            var r = SyntaxRules()
            r.quotes = ["\""]
            r.jsonKeys = true
            r.literals = words("true false null")
            return r
        case "yaml":
            var r = SyntaxRules()
            r.lineComments = ["#"]
            r.commentNeedsSpace = true
            r.hyphenInWords = true
            r.colonKeys = true
            r.literals = words("true false null")
            return r
        case "swift":
            var r = SyntaxRules()
            r.lineComments = ["//"]
            r.blockComment = (open: "/*", close: "*/")
            r.quotes = ["\""]
            r.keywords = words(
                "let var func class struct enum protocol extension import return if else guard switch case "
                + "default for while in repeat break continue try catch throw throws async await actor init "
                + "deinit self super static private public internal fileprivate final override lazy weak "
                + "unowned where as is inout mutating some any typealias subscript defer do"
            )
            r.literals = words("true false nil")
            return r
        case "markup":
            var r = SyntaxRules()
            r.blockComment = (open: "<!--", close: "-->")
            r.markup = true
            return r
        case "css":
            var r = SyntaxRules()
            r.blockComment = (open: "/*", close: "*/")
            r.hyphenInWords = true
            r.colonKeys = true
            r.atRules = true
            r.hexColors = true
            return r
        case "sql":
            var r = SyntaxRules()
            r.lineComments = ["--"]
            r.blockComment = (open: "/*", close: "*/")
            r.caseInsensitive = true
            r.keywords = words(
                "select from where insert into values update set delete create table alter drop join left "
                + "right inner outer on group by order having limit offset and or not as distinct union all "
                + "is in like between case when then else end primary key foreign references index view with "
                + "exists asc desc"
            )
            r.literals = words("null true false")
            return r
        case "clike":
            var r = SyntaxRules()
            r.lineComments = ["//"]
            r.blockComment = (open: "/*", close: "*/")
            r.keywords = words(
                "if else for while do switch case break continue return func fn let mut const struct enum "
                + "impl trait pub use mod package import class interface public private protected static void "
                + "int string bool char float double long short unsigned signed new delete extends implements "
                + "go defer chan select type var range match loop self Self async await namespace using "
                + "template typename virtual override final try catch throw throws finally fun val"
            )
            r.literals = words("true false null nil")
            return r
        default:
            return nil
        }
    }

    static func tokens(in text: String, language: String?) -> [CodeToken] {
        guard let canonical = canonicalLanguage(language),
              let rules = rules(for: canonical) else {
            return []
        }

        let tripleQuotes = [String(repeating: "\"", count: 3), String(repeating: "'", count: 3)]
        let chars = Array(text)
        let indices = Array(text.indices) + [text.endIndex]
        let n = chars.count
        var tokens: [CodeToken] = []
        var inTag = false
        var i = 0

        func add(_ kind: TokenKind, _ from: Int, _ to: Int) {
            guard from < to, to <= n else { return }
            tokens.append(CodeToken(range: indices[from]..<indices[to], kind: kind))
        }

        func matches(_ pattern: String, at position: Int) -> Bool {
            var p = position
            for c in pattern {
                if p >= n || chars[p] != c { return false }
                p += 1
            }
            return true
        }

        func isWordStart(_ c: Character) -> Bool {
            c.isLetter || c == "_"
        }

        func isWordPart(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "_" || (rules.hyphenInWords && c == "-")
        }

        func isKeyColon(after position: Int) -> Bool {
            guard position < n, chars[position] == ":" else { return false }
            return position + 1 >= n || chars[position + 1] == " " || chars[position + 1].isNewline
        }

        while i < n {
            let c = chars[i]

            if c.isWhitespace {
                i += 1
                continue
            }

            if let block = rules.blockComment, matches(block.open, at: i) {
                var j = i + block.open.count
                while j < n && !matches(block.close, at: j) { j += 1 }
                j = min(n, j + block.close.count)
                add(.comment, i, j)
                i = j
                continue
            }

            var consumed = false
            for prefix in rules.lineComments where matches(prefix, at: i) {
                if rules.commentNeedsSpace && i > 0 && !chars[i - 1].isWhitespace { continue }
                var j = i
                while j < n && !chars[j].isNewline { j += 1 }
                add(.comment, i, j)
                i = j
                consumed = true
                break
            }
            if consumed { continue }

            if rules.hexColors && c == "#" {
                var j = i + 1
                while j < n && chars[j].isHexDigit { j += 1 }
                if j > i + 1 {
                    add(.number, i, j)
                    i = j
                    continue
                }
            }

            if rules.atRules && c == "@" {
                var j = i + 1
                while j < n && (chars[j].isLetter || chars[j] == "-") { j += 1 }
                add(.keyword, i, j)
                i = max(j, i + 1)
                continue
            }

            if rules.tripleQuotes {
                for quote in tripleQuotes where matches(quote, at: i) {
                    var j = i + 3
                    while j < n && !matches(quote, at: j) { j += 1 }
                    j = min(n, j + 3)
                    add(.string, i, j)
                    i = j
                    consumed = true
                    break
                }
                if consumed { continue }
            }

            if rules.quotes.contains(c) && (!rules.markup || inTag) {
                var j = i + 1
                let multiline = c == "`"
                while j < n {
                    if chars[j] == "\\" {
                        j += 2
                        continue
                    }
                    if chars[j] == c {
                        j += 1
                        break
                    }
                    if !multiline && chars[j].isNewline { break }
                    j += 1
                }
                j = min(j, n)

                var kind = TokenKind.string
                if rules.jsonKeys {
                    var k = j
                    while k < n && (chars[k] == " " || chars[k] == "\t") { k += 1 }
                    if k < n && chars[k] == ":" { kind = .key }
                }
                add(kind, i, j)
                i = j
                continue
            }

            if rules.shell && c == "$" {
                var j = i + 1
                if j < n && chars[j] == "{" {
                    while j < n && chars[j] != "}" && !chars[j].isNewline { j += 1 }
                    j = min(n, j + 1)
                } else if j < n && chars[j] == "(" {
                    j += 1
                } else {
                    while j < n && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") { j += 1 }
                    if j == i + 1, j < n, "?!#@*$".contains(chars[j]) { j += 1 }
                }
                if j > i + 1 {
                    add(.variable, i, j)
                    i = j
                    continue
                }
            }

            if rules.shell && c == "-" && (i == 0 || chars[i - 1].isWhitespace),
               i + 1 < n, chars[i + 1].isLetter || chars[i + 1] == "-" {
                var j = i + 1
                while j < n && (chars[j].isLetter || chars[j].isNumber || chars[j] == "-" || chars[j] == "_") {
                    j += 1
                }
                add(.flag, i, j)
                i = j
                continue
            }

            if rules.markup {
                if c == "<" {
                    var j = i + 1
                    if j < n && (chars[j] == "/" || chars[j] == "!" || chars[j] == "?") { j += 1 }
                    while j < n && (chars[j].isLetter || chars[j].isNumber || chars[j] == "-" || chars[j] == ":") {
                        j += 1
                    }
                    add(.tag, i, j)
                    inTag = true
                    i = j
                    continue
                }
                if c == "/" && i + 1 < n && chars[i + 1] == ">" {
                    add(.tag, i, i + 2)
                    inTag = false
                    i += 2
                    continue
                }
                if c == ">" {
                    add(.tag, i, i + 1)
                    inTag = false
                    i += 1
                    continue
                }
            }

            if c.isNumber && !(i > 0 && isWordPart(chars[i - 1])) {
                var j = i
                if matches("0x", at: i) {
                    j += 2
                    while j < n && chars[j].isHexDigit { j += 1 }
                } else {
                    while j < n && (chars[j].isNumber || (chars[j] == "." && j + 1 < n && chars[j + 1].isNumber)) {
                        j += 1
                    }
                }
                add(.number, i, j)
                i = max(j, i + 1)
                continue
            }

            if isWordStart(c) {
                var j = i
                while j < n && isWordPart(chars[j]) { j += 1 }
                while j > i + 1 && chars[j - 1] == "-" { j -= 1 }

                let word = String(chars[i..<j])
                let lookup = rules.caseInsensitive ? word.lowercased() : word

                if rules.colonKeys && isKeyColon(after: j) {
                    add(.key, i, j)
                } else if rules.keywords.contains(lookup) {
                    add(.keyword, i, j)
                } else if rules.literals.contains(lookup) {
                    add(.literal, i, j)
                }
                i = j
                continue
            }

            i += 1
        }
        return tokens
    }
}
