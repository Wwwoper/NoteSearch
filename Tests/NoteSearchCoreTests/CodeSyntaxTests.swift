import XCTest
@testable import NoteSearchCore

final class CodeSyntaxTests: XCTestCase {
    private let fence = String(repeating: "`", count: 3)

    private func tokens(_ text: String, _ language: String?) -> [String] {
        CodeHighlighter.tokens(in: text, language: language).map { "\(text[$0.range])|\($0.kind)" }
    }

    // MARK: - Языки и токены

    func testLanguageAliases() {
        XCTAssertEqual(CodeHighlighter.canonicalLanguage("Bash"), "shell")
        XCTAssertEqual(CodeHighlighter.canonicalLanguage("zsh"), "shell")
        XCTAssertEqual(CodeHighlighter.canonicalLanguage("py"), "python")
        XCTAssertEqual(CodeHighlighter.canonicalLanguage("TS"), "javascript")
        XCTAssertEqual(CodeHighlighter.canonicalLanguage("yml"), "yaml")
        XCTAssertEqual(CodeHighlighter.canonicalLanguage("htm"), "markup")
        XCTAssertNil(CodeHighlighter.canonicalLanguage(nil))
        XCTAssertNil(CodeHighlighter.canonicalLanguage(""))
        XCTAssertNil(CodeHighlighter.canonicalLanguage("brainfuck"))
    }

    func testShellFlagsStringsAndComments() {
        XCTAssertEqual(
            tokens("ls -la \"$HOME/x\" # note", "bash"),
            ["-la|flag", "\"$HOME/x\"|string", "# note|comment"]
        )
    }

    func testShellKeywordsAndVariables() {
        XCTAssertEqual(
            tokens("if [ -n \"$X\" ]; then echo $HOME; fi", "sh"),
            ["if|keyword", "-n|flag", "\"$X\"|string", "then|keyword", "echo|keyword", "$HOME|variable", "fi|keyword"]
        )
    }

    func testPythonTokens() {
        XCTAssertEqual(
            tokens("def f(x): return None  # c", "py"),
            ["def|keyword", "return|keyword", "None|literal", "# c|comment"]
        )
    }

    func testPythonDocstringIsOneString() {
        let quotes = String(repeating: "\"", count: 3)
        let text = quotes + "doc" + quotes
        XCTAssertEqual(tokens(text, "python"), [text + "|string"])
    }

    func testJsonKeysAndLiterals() {
        XCTAssertEqual(
            tokens("{\"a\": 1, \"b\": true}", "json"),
            ["\"a\"|key", "1|number", "\"b\"|key", "true|literal"]
        )
    }

    func testYamlKeyAndComment() {
        XCTAssertEqual(
            tokens("name: nginx # c", "yaml"),
            ["name|key", "# c|comment"]
        )
    }

    func testJavascriptTokens() {
        XCTAssertEqual(
            tokens("const x = 'a'; // c", "js"),
            ["const|keyword", "'a'|string", "// c|comment"]
        )
    }

    func testSqlKeywordsAreCaseInsensitive() {
        XCTAssertEqual(
            tokens("SELECT * FROM t WHERE id = 5", "sql"),
            ["SELECT|keyword", "FROM|keyword", "WHERE|keyword", "5|number"]
        )
    }

    func testMarkupTagsAndAttributes() {
        XCTAssertEqual(
            tokens("<div class=\"a\">hi</div>", "html"),
            ["<div|tag", "\"a\"|string", ">|tag", "</div|tag", ">|tag"]
        )
    }

    func testUnknownLanguageHasNoTokens() {
        XCTAssertTrue(CodeHighlighter.tokens(in: "x = 1", language: "brainfuck").isEmpty)
        XCTAssertTrue(CodeHighlighter.tokens(in: "x = 1", language: nil).isEmpty)
    }

    // MARK: - Ограды блоков кода

    func testOpeningFenceParsing() {
        let bash = SnippetBuilder.parseOpeningFence(fence + "bash")
        XCTAssertEqual(bash?.language, "bash")
        XCTAssertEqual(bash?.count, 3)

        XCTAssertNotNil(SnippetBuilder.parseOpeningFence("~~~"))
        XCTAssertNil(SnippetBuilder.parseOpeningFence("~~~")?.language)
        XCTAssertEqual(SnippetBuilder.parseOpeningFence(fence + "py title=x")?.language, "py")
        XCTAssertEqual(SnippetBuilder.parseOpeningFence(fence + "{.bash}")?.language, "bash")
        XCTAssertNil(SnippetBuilder.parseOpeningFence("``"))
        XCTAssertNil(SnippetBuilder.parseOpeningFence(fence + "inline" + fence))
    }

    func testClosingFenceParsing() {
        XCTAssertTrue(SnippetBuilder.isClosingFence(fence, marker: "`", minCount: 3))
        XCTAssertTrue(SnippetBuilder.isClosingFence(fence + "`", marker: "`", minCount: 3))
        XCTAssertTrue(SnippetBuilder.isClosingFence("~~~", marker: nil, minCount: 3))
        XCTAssertFalse(SnippetBuilder.isClosingFence("``", marker: "`", minCount: 3))
        XCTAssertFalse(SnippetBuilder.isClosingFence(fence + "bash", marker: "`", minCount: 3))
        XCTAssertFalse(SnippetBuilder.isClosingFence("~~~", marker: "`", minCount: 3))
    }

    func testFenceBlocksFindLanguageAndContent() {
        let text = "intro\n" + fence + "bash\necho hi\n" + fence + "\noutro\n"
        let blocks = SnippetBuilder.fenceBlocks(in: text)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].language, "bash")
        XCTAssertEqual(String(text[blocks[0].contentStart..<blocks[0].end]), "echo hi\n")
    }

    func testUnclosedFenceRunsToEndOfText() {
        let text = fence + "py\nprint(1)\n"
        let blocks = SnippetBuilder.fenceBlocks(in: text)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].end, text.endIndex)
    }

    // MARK: - Фрагменты и сегменты

    func testSnippetInsideCodeBlockKnowsLanguage() {
        let filler = String(repeating: "x", count: 1000)
        let text = fence + "bash\n" + filler + "\necho nsaccept\n" + fence + "\nafter"

        let snippets = SnippetBuilder.build(
            text: text,
            terms: [QueryTerm(text: "nsaccept", isPhrase: false)]
        )

        XCTAssertEqual(snippets.count, 1)
        XCTAssertTrue(snippets[0].startsInCodeBlock)
        XCTAssertEqual(snippets[0].codeLanguage, "bash")
    }

    func testSnippetOutsideCodeBlockIsNotMarked() {
        let text = "intro nsaccept\n" + fence + "bash\ncode\n" + fence
        let snippets = SnippetBuilder.build(
            text: text,
            terms: [QueryTerm(text: "nsaccept", isPhrase: false)]
        )

        XCTAssertEqual(snippets.count, 1)
        XCTAssertFalse(snippets[0].startsInCodeBlock)
        XCTAssertNil(snippets[0].codeLanguage)
    }

    func testSegmenterSplitsProseAndCode() {
        let snippet = SearchSnippet(
            text: "before\n" + fence + "py\nprint(1)\n" + fence + "\nafter"
        )
        let segments = SnippetSegmenter.segments(for: snippet)

        XCTAssertEqual(segments.count, 3)
        XCTAssertFalse(segments[0].isCode)
        XCTAssertEqual(segments[0].text, "before")
        XCTAssertTrue(segments[1].isCode)
        XCTAssertEqual(segments[1].language, "py")
        XCTAssertEqual(segments[1].text, "print(1)")
        XCTAssertFalse(segments[2].isCode)
        XCTAssertEqual(segments[2].text, "after")
    }

    func testSegmenterHonoursInheritedCodeState() {
        let snippet = SearchSnippet(
            text: "print(1)\n" + fence + "\ntail",
            startsInCodeBlock: true,
            codeLanguage: "py"
        )
        let segments = SnippetSegmenter.segments(for: snippet)

        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments[0].isCode)
        XCTAssertEqual(segments[0].language, "py")
        XCTAssertEqual(segments[0].text, "print(1)")
        XCTAssertFalse(segments[1].isCode)
        XCTAssertEqual(segments[1].text, "tail")
    }

    func testSegmenterKeepsUnclosedBlockAsCode() {
        let snippet = SearchSnippet(text: "intro\n" + fence + "sh\necho hi")
        let segments = SnippetSegmenter.segments(for: snippet)

        XCTAssertEqual(segments.count, 2)
        XCTAssertFalse(segments[0].isCode)
        XCTAssertTrue(segments[1].isCode)
        XCTAssertEqual(segments[1].language, "sh")
        XCTAssertEqual(segments[1].text, "echo hi")
    }

    func testSegmenterSkipsEmptyBlocks() {
        let snippet = SearchSnippet(text: fence + "\n" + fence)
        XCTAssertTrue(SnippetSegmenter.segments(for: snippet).isEmpty)
    }
}
