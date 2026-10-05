import SwiftUI
import AppKit

private enum FileKind {
    case markdown
    case code(language: String)
    case plain
}

enum CodePalette {
    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        let lightColor = rgb(light)
        let darkColor = rgb(dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        })
    }

    static func color(for kind: TokenKind) -> Color {
        switch kind {
        case .keyword: return dynamic(light: 0xAD3DA4, dark: 0xFF7AB2)
        case .string: return dynamic(light: 0xC41A16, dark: 0xFF8170)
        case .comment: return dynamic(light: 0x6C7986, dark: 0x7F8C98)
        case .number: return dynamic(light: 0x1C00CF, dark: 0xD9C97C)
        case .variable: return dynamic(light: 0x0F68A0, dark: 0x6BDFFF)
        case .flag: return dynamic(light: 0xB35900, dark: 0xFFB454)
        case .key: return dynamic(light: 0x0B4F79, dark: 0x4EB0CC)
        case .literal: return dynamic(light: 0x9B2393, dark: 0xFC5FA3)
        case .tag: return dynamic(light: 0x326D74, dark: 0x6BDFFF)
        }
    }
}

struct CodeBlockView: View {
    let language: String?
    let text: String
    let terms: [QueryTerm]

    private var label: String {
        if let language, !language.isEmpty { return language }
        return "код"
    }

    private var attributed: AttributedString {
        var result = AttributedString(text)

        for token in CodeHighlighter.tokens(in: text, language: language) {
            if let r = Range<AttributedString.Index>(token.range, in: result) {
                result[r].foregroundColor = CodePalette.color(for: token.kind)
            }
        }

        for range in SnippetBuilder.findRanges(in: text, terms: terms) {
            if let r = Range<AttributedString.Index>(range, in: result) {
                result[r].backgroundColor = Color.yellow.opacity(0.5)
                result[r].foregroundColor = Color.black
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Копировать код")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12))

            Text(attributed)
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }
}

struct PreviewView: View {
    @EnvironmentObject var appState: AppState
    @State private var snippets: [SearchSnippet] = []
    @State private var visibleCount = 5
    @State private var isLoading = false

    private let monoFont = Font.system(size: 13, design: .monospaced)

    private var fileKind: FileKind {
        guard let ext = appState.selectedResult?.fileURL.pathExtension.lowercased() else {
            return .plain
        }
        if ext == "md" || ext == "markdown" { return .markdown }
        if CodeHighlighter.canonicalLanguage(ext) != nil { return .code(language: ext) }
        return .plain
    }

    private var terms: [QueryTerm] {
        QueryParser.terms(from: appState.searchQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let result = appState.selectedResult {
                header(for: result)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if snippets.isEmpty {
                            Text(isLoading ? "Загрузка..." : "Не удалось прочитать файл")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(Array(snippets.prefix(visibleCount).enumerated()), id: \.element.id) { index, snippet in
                                VStack(alignment: .leading, spacing: 6) {
                                    if index > 0 { Divider() }
                                    if let line = snippet.lineNumber {
                                        Text("строка \(line)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    snippetContent(snippet)
                                }
                            }
                            if snippets.count > visibleCount {
                                Button("Показать ещё (\(snippets.count - visibleCount))") {
                                    visibleCount += 5
                                }
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .task(id: "\(result.id.uuidString)|\(appState.searchQuery)") {
                    await loadSnippets(for: result)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Выберите файл для просмотра")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func snippetContent(_ snippet: SearchSnippet) -> some View {
        switch fileKind {
        case .code(let language):
            CodeBlockView(language: language, text: snippet.text, terms: terms)
        case .markdown:
            segmentedView(snippet, markdown: true)
        case .plain:
            segmentedView(snippet, markdown: false)
        }
    }

    private func segmentedView(_ snippet: SearchSnippet, markdown: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(SnippetSegmenter.segments(for: snippet)) { segment in
                if segment.isCode {
                    CodeBlockView(language: segment.language, text: segment.text, terms: terms)
                } else {
                    Text(highlightedProse(segment.text, markdown: markdown))
                        .font(monoFont)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func header(for result: SearchResult) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.fileName)
                    .font(.system(size: 13, weight: .semibold))
                Text(result.relativePath)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Открыть в Finder") { appState.revealSelected() }
            Button("Открыть файл") { appState.openSelected() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func loadSnippets(for result: SearchResult) async {
        isLoading = true
        visibleCount = 5
        let url = result.fileURL
        let queryTerms = terms

        let built = await Task.detached(priority: .userInitiated) { () -> [SearchSnippet] in
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            let text = TextNormalizer.nfc(raw)
            let found = SnippetBuilder.build(text: text, terms: queryTerms)
            if found.isEmpty {
                return [SearchSnippet(text: String(text.prefix(600)), matchRanges: [], lineNumber: 1)]
            }
            return found
        }.value

        snippets = built
        isLoading = false
    }

    // MARK: - Подсветка обычного текста и Markdown

    private func highlightedProse(_ text: String, markdown: Bool) -> AttributedString {
        var attributed = AttributedString(text)

        if markdown {
            applyMarkdownStyle(to: &attributed, text: text)
        }

        for range in SnippetBuilder.findRanges(in: text, terms: terms) {
            if let r = Range<AttributedString.Index>(range, in: attributed) {
                attributed[r].backgroundColor = Color.yellow.opacity(0.5)
                attributed[r].foregroundColor = Color.black
                attributed[r].font = Font.system(size: 13, design: .monospaced).bold()
            }
        }
        return attributed
    }

    private func applyMarkdownStyle(to attributed: inout AttributedString, text: String) {
        var index = text.startIndex

        while index < text.endIndex {
            let full = text.lineRange(for: index..<index)

            var end = full.upperBound
            while end > full.lowerBound, text[text.index(before: end)].isNewline {
                end = text.index(before: end)
            }

            let contentRange = full.lowerBound..<end
            let line = String(text[contentRange])
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let range = Range<AttributedString.Index>(contentRange, in: attributed) {
                if isHeading(trimmed) {
                    attributed[range].foregroundColor = Color.accentColor
                    attributed[range].font = Font.system(size: 14, weight: .bold, design: .monospaced)
                } else if trimmed.hasPrefix(">") {
                    attributed[range].foregroundColor = Color.secondary
                } else if let markerLength = listMarkerLength(in: line) {
                    let markerEnd = text.index(contentRange.lowerBound, offsetBy: markerLength)
                    if let markerRange = Range<AttributedString.Index>(
                        contentRange.lowerBound..<markerEnd,
                        in: attributed
                    ) {
                        attributed[markerRange].foregroundColor = Color.orange
                        attributed[markerRange].font = Font.system(size: 13, weight: .bold, design: .monospaced)
                    }
                }
            }

            if full.upperBound <= index { break }
            index = full.upperBound
        }
    }

    private func isHeading(_ trimmed: String) -> Bool {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return false }
        return trimmed.dropFirst(hashes.count).first == " "
    }

    private func listMarkerLength(in line: String) -> Int? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }.count
        let rest = line.dropFirst(leading)

        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return leading + 1
        }

        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " {
                return leading + digits.count + 1
            }
        }
        return nil
    }
}
