import Foundation

struct ConversationTurn: Identifiable {
    let id: String
    let turnIndex: Int
    let events: [SessionEvent]
    let toolPairs: [ToolCallPair]

    var userSnippet: String? {
        events.first { $0.eventType == "turn_started" }?.userSnippet
    }

    var assistantSnippet: String? {
        // Take the last assistant_responding event with actual content
        // (earlier ones during thinking phase may have empty/nil snippets)
        guard let raw = events.last(where: { $0.eventType == "assistant_responding" && ($0.assistantSnippet ?? "").isEmpty == false })?.assistantSnippet else {
            return nil
        }
        // Strip artifacts meaningless outside the CLI
        let cleaned = raw
            // Remove <thinking>...</thinking> blocks
            .replacingOccurrences(of: "<thinking>[\\s\\S]*?</thinking>", with: "", options: .regularExpression)
            // Remove [Image #N] placeholders
            .replacingOccurrences(of: "\\[Image #\\d+\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

struct ToolCallPair: Identifiable {
    let started: SessionEvent
    let finished: SessionEvent?

    var id: String { started.id }
    var toolName: String { started.toolName ?? "Unknown" }
    var toolCategory: String { started.toolCategory ?? "tool" }
    var isComplete: Bool { finished != nil }
    var isError: Bool { finished?.isToolError ?? false }

    var toolInputSummary: String? { started.toolInputSummary }
    var toolResultSummary: String? { finished?.toolResultSummary }

    // Provider-agnostic display properties
    var toolIcon: String? { started.toolIcon }
    var toolIconColor: String? { started.toolIconColor }
    var toolDescription: String? { started.toolDescription }
    var toolInputFields: [ToolInputField]? { started.toolInputFields }
}

enum TurnBuilder {
    static func buildTurns(from events: [SessionEvent]) -> [ConversationTurn] {
        // Sort by seq (REST events), then by timestamp as fallback.
        // WS events have seq=nil so they sort after REST events.
        let sorted = events.sorted {
            let seq0 = $0.seq ?? Int.max
            let seq1 = $1.seq ?? Int.max
            if seq0 != seq1 { return seq0 < seq1 }
            return $0.timestamp < $1.timestamp
        }

        // Step 1: Build global tool-finish map (toolUseId -> event)
        var finishMap: [String: SessionEvent] = [:]
        for event in sorted where event.eventType == "tool_finished" {
            if let toolUseId = event.toolUseId {
                finishMap[toolUseId] = event
            }
        }

        // Step 2: Split into turn groups
        var turnGroups: [(index: Int, events: [SessionEvent])] = []
        var currentEvents: [SessionEvent] = []
        var currentIndex = 0

        for event in sorted {
            if event.eventType == "turn_started" {
                if !currentEvents.isEmpty {
                    turnGroups.append((currentIndex, currentEvents))
                }
                currentIndex = event.turnIndex ?? (currentIndex + 1)
                currentEvents = [event]
            } else {
                currentEvents.append(event)
            }
        }
        if !currentEvents.isEmpty {
            turnGroups.append((currentIndex, currentEvents))
        }

        // Step 3: Build turns with globally-paired tools
        return turnGroups.enumerated().map { offset, group in
            let pairs = group.events
                .filter { $0.eventType == "tool_started" }
                .compactMap { event -> ToolCallPair? in
                    guard let toolUseId = event.toolUseId else { return nil }
                    return ToolCallPair(started: event, finished: finishMap[toolUseId])
                }

            return ConversationTurn(
                id: "turn-\(offset)",
                turnIndex: group.index,
                events: group.events,
                toolPairs: pairs
            )
        }
    }
}
