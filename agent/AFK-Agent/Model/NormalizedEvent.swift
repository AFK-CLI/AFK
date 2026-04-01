//
//  NormalizedEvent.swift
//  AFK-Agent
//

import Foundation

enum NormalizedEventType: String, Codable, Sendable {
    case sessionStarted = "session_started"
    case turnStarted = "turn_started"
    case assistantResponding = "assistant_responding"
    case toolStarted = "tool_started"
    case toolFinished = "tool_finished"
    case turnCompleted = "turn_completed"
    case usageUpdate = "usage_update"
    case sessionIdle = "session_idle"
    case sessionCompleted = "session_completed"
    case permissionNeeded = "permission_needed"
    case toolResult = "tool_result"
    case errorRaised = "error_raised"
}

struct NormalizedEvent: Codable, Sendable {
    let sessionId: String
    let eventType: NormalizedEventType
    let timestamp: Date
    let data: [String: String]
    let content: [String: String]?

    init(sessionId: String, eventType: NormalizedEventType, data: [String: String] = [:], content: [String: String]? = nil) {
        self.sessionId = sessionId
        self.eventType = eventType
        self.timestamp = Date()
        self.data = data
        self.content = content
    }
}
