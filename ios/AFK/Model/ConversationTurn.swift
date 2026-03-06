import Foundation

struct ConversationTurn: Identifiable, Equatable {
    let id: String
    let turnIndex: Int
    let events: [SessionEvent]
    let toolPairs: [ToolCallPair]
    let cachedAssistantContentBlocks: [AssistantContentBlock]?
    let cachedUserContentBlocks: [AssistantContentBlock]?

    init(id: String, turnIndex: Int, events: [SessionEvent], toolPairs: [ToolCallPair], cachedAssistantContentBlocks: [AssistantContentBlock]? = nil, cachedUserContentBlocks: [AssistantContentBlock]? = nil) {
        self.id = id
        self.turnIndex = turnIndex
        self.events = events
        self.toolPairs = toolPairs
        self.cachedAssistantContentBlocks = cachedAssistantContentBlocks
        self.cachedUserContentBlocks = cachedUserContentBlocks
    }

    static func == (lhs: ConversationTurn, rhs: ConversationTurn) -> Bool {
        lhs.id == rhs.id &&
        lhs.events.count == rhs.events.count &&
        lhs.toolPairs.count == rhs.toolPairs.count &&
        lhs.cachedUserContentBlocks?.count == rhs.cachedUserContentBlocks?.count
    }

    var userSnippet: String? {
        guard let raw = events.first(where: { $0.eventType == "turn_started" })?.userSnippet else {
            return nil
        }
        // Strip CLI system/meta XML tags that aren't meaningful in the mobile UI
        var cleaned = raw
            .replacingOccurrences(
                of: "<(local-command-caveat|command-name|command-message|command-args|local-command-stdout|system-reminder)>[\\s\\S]*?</\\1>",
                with: "",
                options: .regularExpression
            )
        // Strip teammate/task XML tags (rendered as cards separately)
        cleaned = cleaned
            .replacingOccurrences(
                of: "(?:-\\s*\\[[ x]\\]\\s*)?<teammate-message[\\s\\S]*?</teammate-message>",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "(?:-\\s*\\[[ x]\\]\\s*)?<task-notification>[\\s\\S]*?</task-notification>",
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
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

    /// Parsed assistant content blocks (pre-computed at build time by TurnBuilder).
    var assistantContentBlocks: [AssistantContentBlock]? {
        cachedAssistantContentBlocks
    }

    /// Parsed user content blocks (teammate/task cards from user messages).
    var userContentBlocks: [AssistantContentBlock]? {
        cachedUserContentBlocks
    }

    /// Compute user content blocks (teammate/task cards) from the user snippet.
    static func buildUserContentBlocks(from events: [SessionEvent]) -> [AssistantContentBlock]? {
        guard let raw = events.first(where: { $0.eventType == "turn_started" })?.userSnippet else {
            return nil
        }
        // Only parse if tags are present
        guard raw.contains("<teammate-message") || raw.contains("<task-notification>") else {
            return nil
        }
        let blocks = AssistantContentParser.parse(raw)
        // Only return teammate/task blocks, not surrounding text
        let specialBlocks = blocks.filter { block in
            switch block {
            case .text: return false
            case .taskNotification, .teammateMessage: return true
            }
        }
        return specialBlocks.isEmpty ? nil : specialBlocks
    }

    /// Compute assistant content blocks from events (used by TurnBuilder at build time).
    static func buildContentBlocks(from events: [SessionEvent]) -> [AssistantContentBlock]? {
        guard let raw = events.last(where: {
            $0.eventType == "assistant_responding" && ($0.assistantSnippet ?? "").isEmpty == false
        })?.assistantSnippet else {
            return nil
        }
        let cleaned = raw
            .replacingOccurrences(of: "<thinking>[\\s\\S]*?</thinking>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[Image #\\d+\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let blocks = AssistantContentParser.parse(cleaned)
        let hasContent = blocks.contains { block in
            switch block {
            case .text(let t): return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .taskNotification, .teammateMessage: return true
            }
        }
        return hasContent ? blocks : nil
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
                toolPairs: pairs,
                cachedAssistantContentBlocks: ConversationTurn.buildContentBlocks(from: group.events),
                cachedUserContentBlocks: ConversationTurn.buildUserContentBlocks(from: group.events)
            )
        }
    }
}
