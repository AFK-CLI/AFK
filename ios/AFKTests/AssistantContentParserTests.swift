import XCTest
@testable import AFK

final class AssistantContentParserTests: XCTestCase {

    // MARK: - Plain Text (Fast Path)

    func testPlainTextReturnsTextBlock() {
        let text = "Hello, this is a normal assistant response."
        let blocks = AssistantContentParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        if case .text(let content) = blocks[0] {
            XCTAssertEqual(content, text)
        } else {
            XCTFail("Expected .text block")
        }
    }

    func testEmptyTextReturnsTextBlock() {
        let blocks = AssistantContentParser.parse("")
        XCTAssertEqual(blocks.count, 1)
        if case .text(let content) = blocks[0] {
            XCTAssertEqual(content, "")
        } else {
            XCTFail("Expected .text block")
        }
    }

    // MARK: - Task Notifications

    func testParseTaskNotification() {
        let text = """
        <task-notification><task-id>42</task-id><status>completed</status><summary>Build passed</summary></task-notification>
        """
        let blocks = AssistantContentParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        if case .taskNotification(let data) = blocks[0] {
            XCTAssertEqual(data.taskId, "42")
            XCTAssertEqual(data.status, "completed")
            XCTAssertEqual(data.summary, "Build passed")
        } else {
            XCTFail("Expected .taskNotification block")
        }
    }

    func testTaskNotificationWithResult() {
        let text = """
        <task-notification><task-id>1</task-id><status>done</status><summary>Tests ran</summary><result>All 42 tests passed</result></task-notification>
        """
        let blocks = AssistantContentParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        if case .taskNotification(let data) = blocks[0] {
            XCTAssertEqual(data.result, "All 42 tests passed")
        } else {
            XCTFail("Expected .taskNotification block")
        }
    }

    func testTaskNotificationWithOptionalToolUseId() {
        let text = """
        <task-notification><task-id>1</task-id><tool-use-id>tu-123</tool-use-id><status>pending</status><summary>Waiting</summary></task-notification>
        """
        let blocks = AssistantContentParser.parse(text)
        if case .taskNotification(let data) = blocks[0] {
            XCTAssertEqual(data.toolUseId, "tu-123")
        } else {
            XCTFail("Expected .taskNotification block")
        }
    }

    // MARK: - Teammate Messages

    func testParseTeammateMessage() {
        let text = """
        <teammate-message teammate_id="researcher">{"type":"status","from":"researcher","message":"Found 3 results"}</teammate-message>
        """
        let blocks = AssistantContentParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        if case .teammateMessage(let data) = blocks[0] {
            XCTAssertEqual(data.teammateId, "researcher")
            XCTAssertEqual(data.messageType, "status")
            XCTAssertEqual(data.from, "researcher")
            XCTAssertEqual(data.displayMessage, "Found 3 results")
        } else {
            XCTFail("Expected .teammateMessage block")
        }
    }

    func testTeammateMessageWithColor() {
        let text = """
        <teammate-message teammate_id="coder" color="#FF6600">{"type":"progress","message":"Working"}</teammate-message>
        """
        let blocks = AssistantContentParser.parse(text)
        if case .teammateMessage(let data) = blocks[0] {
            XCTAssertEqual(data.color, "#FF6600")
        } else {
            XCTFail("Expected .teammateMessage block")
        }
    }

    func testIdleNotificationShouldHide() {
        let text = """
        <teammate-message teammate_id="worker">{"type":"idle_notification"}</teammate-message>
        """
        let blocks = AssistantContentParser.parse(text)
        if case .teammateMessage(let data) = blocks[0] {
            XCTAssertTrue(data.shouldHide)
        } else {
            XCTFail("Expected .teammateMessage block")
        }
    }

    func testTeammateMessageWithSummaryAndPlainTextBody() {
        let text = """
        <teammate-message teammate_id="beta-analyst" color="green" summary="Go file count in backend/internal/">
        Counted Go files in backend/internal/ using glob pattern **/*.go

        **Total: 73 Go files**
        </teammate-message>
        """
        let blocks = AssistantContentParser.parse(text)
        XCTAssertEqual(blocks.count, 1)
        if case .teammateMessage(let data) = blocks[0] {
            XCTAssertEqual(data.teammateId, "beta-analyst")
            XCTAssertEqual(data.color, "green")
            XCTAssertEqual(data.summary, "Go file count in backend/internal/")
            XCTAssertEqual(data.messageType, "message")
            XCTAssertEqual(data.from, "beta-analyst")
            XCTAssertTrue(data.displayMessage?.contains("73 Go files") ?? false)
            XCTAssertFalse(data.shouldHide)
        } else {
            XCTFail("Expected .teammateMessage block")
        }
    }

    // MARK: - Mixed Content

    func testTextBeforeTask() {
        let text = """
        Here is an update:
        <task-notification><task-id>1</task-id><status>done</status><summary>Build</summary></task-notification>
        """
        let blocks = AssistantContentParser.parse(text)
        XCTAssertEqual(blocks.count, 2)
        if case .text(let t) = blocks[0] {
            XCTAssertTrue(t.contains("Here is an update"))
        } else {
            XCTFail("Expected .text block first")
        }
        if case .taskNotification = blocks[1] { /* pass */ }
        else { XCTFail("Expected .taskNotification second") }
    }

    func testTextAfterTask() {
        let text = """
        <task-notification><task-id>1</task-id><status>done</status><summary>Build</summary></task-notification>
        All done!
        """
        let blocks = AssistantContentParser.parse(text)
        XCTAssertEqual(blocks.count, 2)
        if case .taskNotification = blocks[0] { /* pass */ }
        else { XCTFail("Expected .taskNotification first") }
        if case .text(let t) = blocks[1] {
            XCTAssertTrue(t.contains("All done"))
        } else {
            XCTFail("Expected .text block second")
        }
    }

    func testMultipleTasksInterleaved() {
        let text = """
        Starting...\
        <task-notification><task-id>1</task-id><status>done</status><summary>Step 1</summary></task-notification>\
        Middle text\
        <task-notification><task-id>2</task-id><status>done</status><summary>Step 2</summary></task-notification>\
        Done!
        """
        let blocks = AssistantContentParser.parse(text)
        // Should have: text, task, text, task, text
        XCTAssertEqual(blocks.count, 5)
    }

    func testMixedTaskAndTeammateBlocks() {
        let text = """
        <task-notification><task-id>1</task-id><status>done</status><summary>Build</summary></task-notification>\
        <teammate-message teammate_id="tester">{"type":"message","message":"Tests passed"}</teammate-message>
        """
        let blocks = AssistantContentParser.parse(text)
        XCTAssertEqual(blocks.count, 2)
        if case .taskNotification = blocks[0] { /* pass */ }
        else { XCTFail("Expected .taskNotification") }
        if case .teammateMessage = blocks[1] { /* pass */ }
        else { XCTFail("Expected .teammateMessage") }
    }

    // MARK: - Malformed Tags

    func testMalformedTaskNotificationSkipped() {
        // Missing closing tag
        let text = "<task-notification><task-id>1</task-id>no closing tag"
        let blocks = AssistantContentParser.parse(text)
        // Should not crash; parser should skip past the malformed tag
        XCTAssertFalse(blocks.isEmpty)
    }

    func testMalformedTeammateMessageSkipped() {
        // Missing closing tag
        let text = "<teammate-message teammate_id=\"x\">no closing tag"
        let blocks = AssistantContentParser.parse(text)
        XCTAssertFalse(blocks.isEmpty)
    }

    // MARK: - Checkbox Prefix Stripping

    func testCheckboxPrefixBeforeTaskStripped() {
        let text = "- [ ] <task-notification><task-id>1</task-id><status>pending</status><summary>Task</summary></task-notification>"
        let blocks = AssistantContentParser.parse(text)
        // The checkbox prefix should be stripped, leaving just the task notification
        let hasTask = blocks.contains { if case .taskNotification = $0 { return true }; return false }
        XCTAssertTrue(hasTask)
    }

    func testCheckedBoxPrefixBeforeTaskStripped() {
        let text = "- [x] <task-notification><task-id>1</task-id><status>done</status><summary>Task</summary></task-notification>"
        let blocks = AssistantContentParser.parse(text)
        let hasTask = blocks.contains { if case .taskNotification = $0 { return true }; return false }
        XCTAssertTrue(hasTask)
    }
}
