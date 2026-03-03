import XCTest
@testable import AFK

final class ConversationTurnTests: XCTestCase {

    // MARK: - Helpers

    private func makeEvent(
        id: String = UUID().uuidString,
        sessionId: String = "session-1",
        eventType: String,
        payload: [String: String]? = nil,
        content: [String: String]? = nil,
        seq: Int? = nil,
        timestamp: String = "2024-01-01T00:00:00Z"
    ) -> SessionEvent {
        SessionEvent(
            id: id,
            sessionId: sessionId,
            deviceId: nil,
            eventType: eventType,
            timestamp: timestamp,
            payload: payload,
            content: content,
            seq: seq
        )
    }

    // MARK: - User Snippet Stripping

    func testUserSnippetStripsSystemTags() {
        let rawSnippet = "<system-reminder>some system info</system-reminder>Actual user message"
        let events = [
            makeEvent(eventType: "turn_started", content: ["userSnippet": rawSnippet], seq: 1)
        ]
        let turn = ConversationTurn(id: "t1", turnIndex: 0, events: events, toolPairs: [])
        let snippet = turn.userSnippet
        XCTAssertNotNil(snippet)
        XCTAssertFalse(snippet!.contains("<system-reminder>"))
        XCTAssertTrue(snippet!.contains("Actual user message"))
    }

    func testUserSnippetStripsCommandTags() {
        let rawSnippet = "<command-name>test</command-name><command-args>--flag</command-args>User message"
        let events = [
            makeEvent(eventType: "turn_started", content: ["userSnippet": rawSnippet], seq: 1)
        ]
        let turn = ConversationTurn(id: "t1", turnIndex: 0, events: events, toolPairs: [])
        let snippet = turn.userSnippet
        XCTAssertNotNil(snippet)
        XCTAssertFalse(snippet!.contains("<command-name>"))
        XCTAssertFalse(snippet!.contains("<command-args>"))
        XCTAssertTrue(snippet!.contains("User message"))
    }

    func testUserSnippetNilWhenNoTurnStarted() {
        let events = [
            makeEvent(eventType: "assistant_responding", content: ["assistantSnippet": "hi"], seq: 1)
        ]
        let turn = ConversationTurn(id: "t1", turnIndex: 0, events: events, toolPairs: [])
        XCTAssertNil(turn.userSnippet)
    }

    func testUserSnippetNilWhenOnlyTags() {
        let rawSnippet = "<system-reminder>only system content</system-reminder>"
        let events = [
            makeEvent(eventType: "turn_started", content: ["userSnippet": rawSnippet], seq: 1)
        ]
        let turn = ConversationTurn(id: "t1", turnIndex: 0, events: events, toolPairs: [])
        XCTAssertNil(turn.userSnippet)
    }

    // MARK: - Assistant Snippet Stripping

    func testAssistantSnippetStripsThinking() {
        let rawSnippet = "<thinking>Let me think about this...</thinking>Here is my answer."
        let events = [
            makeEvent(
                eventType: "assistant_responding",
                content: ["assistantSnippet": rawSnippet],
                seq: 1
            )
        ]
        let turn = ConversationTurn(id: "t1", turnIndex: 0, events: events, toolPairs: [])
        let snippet = turn.assistantSnippet
        XCTAssertNotNil(snippet)
        XCTAssertFalse(snippet!.contains("<thinking>"))
        XCTAssertTrue(snippet!.contains("Here is my answer"))
    }

    func testAssistantSnippetStripsImagePlaceholders() {
        let rawSnippet = "Some text [Image #1] more text [Image #23]"
        let events = [
            makeEvent(
                eventType: "assistant_responding",
                content: ["assistantSnippet": rawSnippet],
                seq: 1
            )
        ]
        let turn = ConversationTurn(id: "t1", turnIndex: 0, events: events, toolPairs: [])
        let snippet = turn.assistantSnippet
        XCTAssertNotNil(snippet)
        XCTAssertFalse(snippet!.contains("[Image #"))
        XCTAssertTrue(snippet!.contains("Some text"))
        XCTAssertTrue(snippet!.contains("more text"))
    }

    func testAssistantSnippetUsesLastRespondingEvent() {
        let events = [
            makeEvent(
                eventType: "assistant_responding",
                content: ["assistantSnippet": ""],
                seq: 1
            ),
            makeEvent(
                eventType: "assistant_responding",
                content: ["assistantSnippet": "Final answer"],
                seq: 2
            )
        ]
        let turn = ConversationTurn(id: "t1", turnIndex: 0, events: events, toolPairs: [])
        XCTAssertEqual(turn.assistantSnippet, "Final answer")
    }

    func testAssistantSnippetNilWhenNoContent() {
        let events = [
            makeEvent(eventType: "turn_started", seq: 1)
        ]
        let turn = ConversationTurn(id: "t1", turnIndex: 0, events: events, toolPairs: [])
        XCTAssertNil(turn.assistantSnippet)
    }

    // MARK: - TurnBuilder

    func testBuildTurnsFromEvents() {
        let events = [
            makeEvent(eventType: "turn_started", payload: ["turnIndex": "0"], seq: 1),
            makeEvent(eventType: "assistant_responding", content: ["assistantSnippet": "Hello"], seq: 2),
            makeEvent(eventType: "turn_completed", seq: 3),
            makeEvent(eventType: "turn_started", payload: ["turnIndex": "1"], seq: 4),
            makeEvent(eventType: "assistant_responding", content: ["assistantSnippet": "Second"], seq: 5),
        ]
        let turns = TurnBuilder.buildTurns(from: events)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].turnIndex, 0)
        XCTAssertEqual(turns[1].turnIndex, 1)
    }

    func testBuildTurnsEmptyEvents() {
        let turns = TurnBuilder.buildTurns(from: [])
        XCTAssertTrue(turns.isEmpty)
    }

    func testBuildTurnsPairsToolCalls() {
        let toolUseId = "tool-123"
        let events = [
            makeEvent(eventType: "turn_started", payload: ["turnIndex": "0"], seq: 1),
            makeEvent(
                id: "ts1",
                eventType: "tool_started",
                payload: ["toolUseId": toolUseId, "toolName": "Read"],
                seq: 2
            ),
            makeEvent(
                id: "tf1",
                eventType: "tool_finished",
                payload: ["toolUseId": toolUseId],
                seq: 3
            ),
        ]
        let turns = TurnBuilder.buildTurns(from: events)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].toolPairs.count, 1)
        XCTAssertEqual(turns[0].toolPairs[0].toolName, "Read")
        XCTAssertTrue(turns[0].toolPairs[0].isComplete)
    }

    func testBuildTurnsUnfinishedToolCall() {
        let toolUseId = "tool-456"
        let events = [
            makeEvent(eventType: "turn_started", payload: ["turnIndex": "0"], seq: 1),
            makeEvent(
                id: "ts1",
                eventType: "tool_started",
                payload: ["toolUseId": toolUseId, "toolName": "Bash"],
                seq: 2
            ),
        ]
        let turns = TurnBuilder.buildTurns(from: events)
        XCTAssertEqual(turns[0].toolPairs.count, 1)
        XCTAssertFalse(turns[0].toolPairs[0].isComplete)
    }

    func testBuildTurnsSortsBySeq() {
        // Provide events out of order
        let events = [
            makeEvent(eventType: "assistant_responding", content: ["assistantSnippet": "Second"], seq: 5),
            makeEvent(eventType: "turn_started", payload: ["turnIndex": "1"], seq: 4),
            makeEvent(eventType: "turn_started", payload: ["turnIndex": "0"], seq: 1),
            makeEvent(eventType: "assistant_responding", content: ["assistantSnippet": "First"], seq: 2),
        ]
        let turns = TurnBuilder.buildTurns(from: events)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].turnIndex, 0)
        XCTAssertEqual(turns[1].turnIndex, 1)
    }

    // MARK: - ToolCallPair Properties

    func testToolCallPairErrorDetection() {
        let started = makeEvent(
            id: "ts1",
            eventType: "tool_started",
            payload: ["toolUseId": "t1", "toolName": "Bash"]
        )
        let finished = makeEvent(
            id: "tf1",
            eventType: "tool_finished",
            payload: ["toolUseId": "t1", "isError": "true"]
        )
        let pair = ToolCallPair(started: started, finished: finished)
        XCTAssertTrue(pair.isError)
        XCTAssertTrue(pair.isComplete)
    }

    func testToolCallPairNoError() {
        let started = makeEvent(
            id: "ts1",
            eventType: "tool_started",
            payload: ["toolUseId": "t1", "toolName": "Read"]
        )
        let finished = makeEvent(
            id: "tf1",
            eventType: "tool_finished",
            payload: ["toolUseId": "t1"]
        )
        let pair = ToolCallPair(started: started, finished: finished)
        XCTAssertFalse(pair.isError)
    }
}
