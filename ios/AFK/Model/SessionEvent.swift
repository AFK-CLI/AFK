import Foundation

struct SessionEvent: Codable, Identifiable, Sendable {
    let id: String
    let sessionId: String
    let deviceId: String?
    let eventType: String
    let timestamp: String
    let payload: [String: String]?
    let content: [String: String]?
    let seq: Int?

    var displayTitle: String {
        switch eventType {
        case "session_started": "Session Started"
        case "turn_started": "Turn \(payload?["turnIndex"] ?? "?") Started"
        case "assistant_responding": "Assistant Responding"
        case "tool_started": "Tool: \(payload?["toolName"] ?? "unknown")"
        case "tool_finished": "Tool Finished"
        case "tool_result": "Tool Result: \(payload?["toolName"] ?? "")"
        case "turn_completed": "Turn Completed"
        case "usage_update": "Usage Update"
        case "session_idle": "Session Idle"
        case "session_completed": "Session Completed"
        case "permission_needed": "Permission Needed"
        case "error_raised": "Error: \(payload?["toolName"] ?? "")"
        default: eventType
        }
    }

    var iconName: String {
        switch eventType {
        case "session_started": "play.fill"
        case "turn_started": "arrow.right.circle"
        case "assistant_responding": "text.bubble"
        case "tool_started": "wrench.fill"
        case "tool_finished": "checkmark"
        case "tool_result": "doc.text.magnifyingglass"
        case "turn_completed": "checkmark.circle"
        case "usage_update": "chart.bar"
        case "session_idle": "pause.fill"
        case "session_completed": "stop.fill"
        case "permission_needed": "lock.fill"
        case "error_raised": "exclamationmark.triangle"
        default: "questionmark"
        }
    }

    // MARK: - Content-free telemetry properties

    var toolName: String? { payload?["toolName"] }
    var toolCategory: String? { payload?["toolCategory"] }
    var isToolError: Bool { payload?["isError"] == "true" }
    var turnIndex: Int? { payload?["turnIndex"].flatMap(Int.init) }
    var toolUseId: String? { payload?["toolUseId"] }

    // MARK: - Rich content properties

    var userSnippet: String? { content?["userSnippet"] }
    var assistantSnippet: String? { content?["assistantSnippet"] }
    var toolInputSummary: String? { content?["toolInputSummary"] }
    var toolResultSummary: String? { content?["toolResultSummary"] }

    // MARK: - Provider-agnostic tool display properties

    var toolIcon: String? { payload?["toolIcon"] }
    var toolIconColor: String? { payload?["toolIconColor"] }
    var toolDescription: String? { payload?["toolDescription"] }

    var toolInputFields: [ToolInputField]? {
        guard let json = content?["toolInputFields"],
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([ToolInputField].self, from: data)
    }

    var toolResultImages: [ToolResultImage]? {
        guard let json = content?["toolResultImages"],
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([ToolResultImage].self, from: data)
    }

    /// True when the event has a toolResultImages field but it couldn't be parsed
    /// (e.g. it's "[encrypted]" because E2EE decryption failed).
    var hasEncryptedImages: Bool {
        guard let raw = content?["toolResultImages"] else { return false }
        return raw == "[encrypted]"
    }

    func withContent(_ newContent: [String: String]?) -> SessionEvent {
        SessionEvent(
            id: id, sessionId: sessionId, deviceId: deviceId,
            eventType: eventType, timestamp: timestamp,
            payload: payload, content: newContent, seq: seq
        )
    }
}
