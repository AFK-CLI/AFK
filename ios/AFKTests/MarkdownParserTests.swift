import XCTest
@testable import AFK

final class MarkdownParserTests: XCTestCase {

    // MARK: - Paragraphs

    func testPlainParagraph() {
        let blocks = MarkdownParser.parse("Hello world")
        XCTAssertEqual(blocks.count, 1)
        if case .paragraph = blocks[0] { /* pass */ }
        else { XCTFail("Expected paragraph") }
    }

    func testMultiLineParagraph() {
        let text = "Line one\nLine two\nLine three"
        let blocks = MarkdownParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        if case .paragraph = blocks[0] { /* pass */ }
        else { XCTFail("Expected single paragraph") }
    }

    func testParagraphsSplitByEmptyLine() {
        let text = "First paragraph\n\nSecond paragraph"
        let blocks = MarkdownParser.parse(text)
        XCTAssertEqual(blocks.count, 2)
    }

    // MARK: - Headings

    func testH1() {
        let blocks = MarkdownParser.parse("# Heading 1")
        XCTAssertEqual(blocks.count, 1)
        if case .heading(let level, _) = blocks[0] {
            XCTAssertEqual(level, 1)
        } else { XCTFail("Expected heading") }
    }

    func testH2() {
        let blocks = MarkdownParser.parse("## Heading 2")
        if case .heading(let level, _) = blocks[0] {
            XCTAssertEqual(level, 2)
        } else { XCTFail("Expected heading") }
    }

    func testH3() {
        let blocks = MarkdownParser.parse("### Heading 3")
        if case .heading(let level, _) = blocks[0] {
            XCTAssertEqual(level, 3)
        } else { XCTFail("Expected heading") }
    }

    func testH6() {
        let blocks = MarkdownParser.parse("###### Heading 6")
        if case .heading(let level, _) = blocks[0] {
            XCTAssertEqual(level, 6)
        } else { XCTFail("Expected heading") }
    }

    func testHashWithoutSpaceIsNotHeading() {
        let blocks = MarkdownParser.parse("#NotAHeading")
        XCTAssertEqual(blocks.count, 1)
        if case .paragraph = blocks[0] { /* pass */ }
        else { XCTFail("Expected paragraph, not heading") }
    }

    // MARK: - Code Blocks

    func testFencedCodeBlock() {
        let text = "```swift\nlet x = 42\nprint(x)\n```"
        let blocks = MarkdownParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        if case .codeBlock(let language, let code) = blocks[0] {
            XCTAssertEqual(language, "swift")
            XCTAssertEqual(code, "let x = 42\nprint(x)")
        } else { XCTFail("Expected code block") }
    }

    func testCodeBlockWithoutLanguage() {
        let text = "```\nhello\n```"
        let blocks = MarkdownParser.parse(text)
        if case .codeBlock(let language, let code) = blocks[0] {
            XCTAssertNil(language)
            XCTAssertEqual(code, "hello")
        } else { XCTFail("Expected code block") }
    }

    func testCodeBlockPreservesInternalNewlines() {
        let text = "```\nline1\n\nline3\n```"
        let blocks = MarkdownParser.parse(text)
        if case .codeBlock(_, let code) = blocks[0] {
            XCTAssertEqual(code, "line1\n\nline3")
        } else { XCTFail("Expected code block") }
    }

    // MARK: - Unordered Lists

    func testUnorderedListDash() {
        let blocks = MarkdownParser.parse("- Item one")
        XCTAssertEqual(blocks.count, 1)
        if case .unorderedListItem = blocks[0] { /* pass */ }
        else { XCTFail("Expected unordered list item") }
    }

    func testUnorderedListAsterisk() {
        let blocks = MarkdownParser.parse("* Item one")
        XCTAssertEqual(blocks.count, 1)
        if case .unorderedListItem = blocks[0] { /* pass */ }
        else { XCTFail("Expected unordered list item") }
    }

    func testUnorderedListPlus() {
        let blocks = MarkdownParser.parse("+ Item one")
        XCTAssertEqual(blocks.count, 1)
        if case .unorderedListItem = blocks[0] { /* pass */ }
        else { XCTFail("Expected unordered list item") }
    }

    func testMultipleUnorderedItems() {
        let text = "- First\n- Second\n- Third"
        let blocks = MarkdownParser.parse(text)
        XCTAssertEqual(blocks.count, 3)
        for block in blocks {
            if case .unorderedListItem = block { /* pass */ }
            else { XCTFail("Expected unordered list item") }
        }
    }

    // MARK: - Ordered Lists

    func testOrderedListItem() {
        let blocks = MarkdownParser.parse("1. First item")
        XCTAssertEqual(blocks.count, 1)
        if case .orderedListItem(let index, _) = blocks[0] {
            XCTAssertEqual(index, 1)
        } else { XCTFail("Expected ordered list item") }
    }

    func testOrderedListMultipleItems() {
        let text = "1. First\n2. Second\n3. Third"
        let blocks = MarkdownParser.parse(text)
        XCTAssertEqual(blocks.count, 3)
        if case .orderedListItem(let index, _) = blocks[2] {
            XCTAssertEqual(index, 3)
        } else { XCTFail("Expected ordered list item") }
    }

    // MARK: - Blockquotes

    func testBlockquote() {
        let blocks = MarkdownParser.parse("> Quote text")
        XCTAssertEqual(blocks.count, 1)
        if case .blockquote = blocks[0] { /* pass */ }
        else { XCTFail("Expected blockquote") }
    }

    func testMultiLineBlockquote() {
        let text = "> Line 1\n> Line 2\n> Line 3"
        let blocks = MarkdownParser.parse(text)
        // Consecutive blockquote lines should be grouped
        XCTAssertEqual(blocks.count, 1)
        if case .blockquote = blocks[0] { /* pass */ }
        else { XCTFail("Expected single blockquote") }
    }

    func testEmptyBlockquoteLine() {
        let text = "> Line 1\n>\n> Line 3"
        let blocks = MarkdownParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
    }

    // MARK: - Tables

    func testTable() {
        let text = """
        | Name | Age |
        |------|-----|
        | Alice | 30 |
        | Bob | 25 |
        """
        let blocks = MarkdownParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        if case .table(let headers, let rows) = blocks[0] {
            XCTAssertEqual(headers, ["Name", "Age"])
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows[0], ["Alice", "30"])
            XCTAssertEqual(rows[1], ["Bob", "25"])
        } else { XCTFail("Expected table") }
    }

    // MARK: - Thematic Break

    func testThematicBreakDashes() {
        let blocks = MarkdownParser.parse("---")
        XCTAssertEqual(blocks.count, 1)
        if case .thematicBreak = blocks[0] { /* pass */ }
        else { XCTFail("Expected thematic break") }
    }

    func testThematicBreakAsterisks() {
        let blocks = MarkdownParser.parse("***")
        XCTAssertEqual(blocks.count, 1)
        if case .thematicBreak = blocks[0] { /* pass */ }
        else { XCTFail("Expected thematic break") }
    }

    func testThematicBreakUnderscores() {
        let blocks = MarkdownParser.parse("___")
        XCTAssertEqual(blocks.count, 1)
        if case .thematicBreak = blocks[0] { /* pass */ }
        else { XCTFail("Expected thematic break") }
    }

    // MARK: - Complex Document

    func testComplexDocument() {
        let text = """
        # Title

        Some intro text.

        ## Section 1

        - Item A
        - Item B

        ```python
        print("hello")
        ```

        > A wise quote

        ---

        1. Step one
        2. Step two
        """
        let blocks = MarkdownParser.parse(text)
        // Verify we got a reasonable number of blocks and no crashes
        XCTAssertGreaterThan(blocks.count, 5)

        // Check first block is heading
        if case .heading(let level, _) = blocks[0] {
            XCTAssertEqual(level, 1)
        } else { XCTFail("Expected heading as first block") }
    }

    // MARK: - Empty Input

    func testEmptyInput() {
        let blocks = MarkdownParser.parse("")
        XCTAssertTrue(blocks.isEmpty)
    }

    func testWhitespaceOnlyInput() {
        let blocks = MarkdownParser.parse("   \n   \n   ")
        XCTAssertTrue(blocks.isEmpty)
    }

    // MARK: - Inline Markdown

    func testInlineMarkdownDoesNotCrash() {
        // Just verify it returns something and doesn't crash
        let result = MarkdownParser.inlineMarkdown("**bold** and *italic* and `code`")
        XCTAssertFalse(result.characters.isEmpty)
    }
}
