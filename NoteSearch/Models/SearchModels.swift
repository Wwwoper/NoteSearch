import Foundation

struct SearchResult: Identifiable, Equatable {
    let id: UUID
    let fileURL: URL
    let fileName: String
    let relativePath: String
    let matchCount: Int
    let modifiedAt: Date
    let score: Double
    let snippets: [SearchSnippet]

    init(
        id: UUID = UUID(),
        fileURL: URL,
        fileName: String,
        relativePath: String,
        matchCount: Int,
        modifiedAt: Date,
        score: Double = 0.0,
        snippets: [SearchSnippet] = []
    ) {
        self.id = id
        self.fileURL = fileURL
        self.fileName = fileName
        self.relativePath = relativePath
        self.matchCount = matchCount
        self.modifiedAt = modifiedAt
        self.score = score
        self.snippets = snippets
    }

    static func == (lhs: SearchResult, rhs: SearchResult) -> Bool {
        lhs.id == rhs.id
    }
}

struct SearchSnippet: Identifiable {
    let id: UUID
    let text: String
    let matchRanges: [Range<String.Index>]
    let lineNumber: Int?
    let startsInCodeBlock: Bool
    let codeLanguage: String?

    init(
        id: UUID = UUID(),
        text: String,
        matchRanges: [Range<String.Index>] = [],
        lineNumber: Int? = nil,
        startsInCodeBlock: Bool = false,
        codeLanguage: String? = nil
    ) {
        self.id = id
        self.text = text
        self.matchRanges = matchRanges
        self.lineNumber = lineNumber
        self.startsInCodeBlock = startsInCodeBlock
        self.codeLanguage = codeLanguage
    }
}
enum ExactPhrase {
    /// Оборачивает запрос в кавычки, а если он уже в кавычках, снимает их.
    static func toggle(_ query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return query }
        if q.count >= 2, q.hasPrefix("\""), q.hasSuffix("\"") {
            return String(q.dropFirst().dropLast())
        }
        return "\"\(q)\""
    }
}
