import XCTest
@testable import AFK_Agent

final class TodoParserTests: XCTestCase {

    // MARK: - Basic Parsing

    func testParseUncheckedItem() {
        let content = "- [ ] Buy groceries"
        let items = TodoParser.parse(content)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "Buy groceries")
        XCTAssertFalse(items[0].checked)
        XCTAssertFalse(items[0].inProgress)
        XCTAssertEqual(items[0].line, 1)
    }

    func testParseCheckedItem() {
        let content = "- [x] Buy groceries"
        let items = TodoParser.parse(content)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "Buy groceries")
        XCTAssertTrue(items[0].checked)
        XCTAssertFalse(items[0].inProgress)
    }

    func testParseCheckedItemUppercaseX() {
        let content = "- [X] Buy groceries"
        let items = TodoParser.parse(content)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].checked)
    }

    func testParseInProgressItem() {
        let content = "- [*] Deploy service"
        let items = TodoParser.parse(content)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "Deploy service")
        XCTAssertFalse(items[0].checked)
        XCTAssertTrue(items[0].inProgress)
        XCTAssertEqual(items[0].line, 1)
    }

    func testParsePlainListItem() {
        let content = "- Plain item"
        let items = TodoParser.parse(content)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "Plain item")
        XCTAssertFalse(items[0].checked)
        XCTAssertFalse(items[0].inProgress)
    }

    // MARK: - Multiple Items

    func testParseMultipleItems() {
        let content = """
        - [ ] First task
        - [x] Second task
        - Third task
        """
        let items = TodoParser.parse(content)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].text, "First task")
        XCTAssertFalse(items[0].checked)
        XCTAssertEqual(items[1].text, "Second task")
        XCTAssertTrue(items[1].checked)
        XCTAssertEqual(items[2].text, "Third task")
        XCTAssertFalse(items[2].checked)
    }

    // MARK: - Line Numbers

    func testLineNumbersCorrect() {
        let content = """
        # My Todos

        - [ ] First task
        - [x] Second task
        """
        let items = TodoParser.parse(content)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].line, 3)
        XCTAssertEqual(items[1].line, 4)
    }

    // MARK: - Edge Cases

    func testEmptyContentReturnsEmpty() {
        let items = TodoParser.parse("")
        XCTAssertTrue(items.isEmpty)
    }

    func testNonListLinesIgnored() {
        let content = """
        # Header
        Some paragraph text
        Another paragraph
        """
        let items = TodoParser.parse(content)
        XCTAssertTrue(items.isEmpty)
    }

    func testEmptyTextItemIgnored() {
        // "- [ ] " with no text after the checkbox should be ignored
        let content = "- [ ] "
        let items = TodoParser.parse(content)
        XCTAssertTrue(items.isEmpty)
    }

    func testEmptyPlainItemIgnored() {
        // "- " with nothing after should be ignored
        let content = "- "
        let items = TodoParser.parse(content)
        XCTAssertTrue(items.isEmpty)
    }

    func testLeadingWhitespaceHandled() {
        let content = "  - [ ] Indented task"
        let items = TodoParser.parse(content)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "Indented task")
    }

    func testLinesWithoutDashPrefixIgnored() {
        let content = """
        * Not a todo
        + Also not a todo
        - [ ] This is a todo
        """
        let items = TodoParser.parse(content)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "This is a todo")
    }

    func testMixedContent() {
        let content = """
        # Project Todos

        - [x] Set up project
        - [ ] Write tests

        ## Notes

        Some notes here.

        - [ ] Deploy to production
        """
        let items = TodoParser.parse(content)
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items[0].checked)
        XCTAssertFalse(items[1].checked)
        XCTAssertFalse(items[2].checked)
    }
}
