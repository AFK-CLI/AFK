//
//  OpenCodeNormalizer.swift
//  AFK-Agent
//

import Foundation

/// Normalizes OpenCode parts into NormalizedEvents.
/// Key difference from Claude Code: OpenCode's "tool" parts contain the full lifecycle
/// (call + result in one row), so we emit both toolStarted and toolFinished from a single part.
struct OpenCodeNormalizer: Sendable {
    private var turnIndex: [String: Int] = [:]
    private var seenSessions: Set<String> = []
    /// Tracks pending tools where status was not "completed"/"error" yet.
    private var pendingTools: [String: PendingToolInfo] = [:]
    private let redactor = ContentRedactor()
    private let toolProvider: ToolProvider

    /// Optional content encryptor for E2EE mode.
    var contentEncryptor: (@Sendable ([String: String], String) -> [String: String]?)?

    struct PendingToolInfo: Sendable {
        let toolName: String
        let sessionId: String
        let timestamp: Date
        let turnIndex: Int
        var stallEmitted: Bool = false
    }

    init(toolProvider: ToolProvider) {
        self.toolProvider = toolProvider
    }

    /// Mark sessions as already known (e.g. resumed from previous run)
    /// so we don't emit duplicate session_started events.
    mutating func markSessionsSeen(_ sessionIds: [String]) {
        for id in sessionIds {
            seenSessions.insert(id)
        }
    }

    private func currentTurnIndex(for sessionId: String) -> String {
        "\(turnIndex[sessionId] ?? 0)"
    }

    private func maybeEncryptContent(_ content: [String: String]?, privacyMode: String, sessionId: String) -> [String: String]? {
        guard let content, privacyMode == "encrypted", let encryptor = contentEncryptor else {
            return content
        }
        return encryptor(content, sessionId)
    }

    mutating func normalize(
        part: OpenCodePart,
        privacyMode: String
    ) -> [NormalizedEvent] {
        let sessionId = part.sessionId
        let projectPath = part.projectPath
        var events: [NormalizedEvent] = []

        // Session start detection
        if !seenSessions.contains(sessionId) {
            seenSessions.insert(sessionId)
            events.append(NormalizedEvent(
                sessionId: sessionId,
                eventType: .sessionStarted,
                data: [
                    "projectPath": projectPath,
                    "gitBranch": "",
                    "cwd": projectPath,
                    "turnIndex": "0"
                ]
            ))
        }

        switch part.content {
        case .text(let text):
            if part.role == "user" {
                // User text = new turn
                let idx = (turnIndex[sessionId] ?? 0) + 1
                turnIndex[sessionId] = idx

                var turnContent: [String: String]? = nil
                if !text.isEmpty {
                    turnContent = ["userSnippet": redactor.redactSnippet(text)]
                }

                events.append(NormalizedEvent(
                    sessionId: sessionId,
                    eventType: .turnStarted,
                    data: ["turnIndex": "\(idx)"],
                    content: turnContent
                ))
            } else {
                // Assistant text
                var assistantContent: [String: String]? = nil
                if !text.isEmpty {
                    assistantContent = ["assistantSnippet": redactor.redactSnippet(text)]
                }
                events.append(NormalizedEvent(
                    sessionId: sessionId,
                    eventType: .assistantResponding,
                    data: [
                        "textLength": "\(text.count)",
                        "turnIndex": currentTurnIndex(for: sessionId)
                    ],
                    content: assistantContent
                ))
            }

        case .tool(let callId, let name, let status, let input, let output, let title):
            // OpenCode tool parts contain the full lifecycle.
            // Emit toolStarted with input, then toolFinished with output.
            let hints = toolProvider.displayHints(toolName: name, input: input)

            // --- Tool Started ---
            var toolContent: [String: String]? = nil
            if !input.isEmpty {
                let redacted = redactor.redactToolInput(input, toolName: name)
                let summary = redacted.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
                toolContent = ["toolInputSummary": redactor.truncate(summary, maxLength: 1000)]

                var fields = toolProvider.structuredFields(toolName: name, input: redacted)
                fields = fields.map { field in
                    let redactedValue = field.style == "path"
                        ? redactor.redactFilePath(field.value)
                        : redactor.truncate(field.value, maxLength: 500)
                    return ToolInputField(label: field.label, value: redactedValue, style: field.style)
                }
                if let json = try? JSONEncoder().encode(fields),
                   let str = String(data: json, encoding: .utf8) {
                    toolContent?["toolInputFields"] = str
                }
            }

            var toolData: [String: String] = [
                "toolName": name,
                "toolUseId": callId,
                "toolCategory": hints.category,
                "toolIcon": hints.iconName,
                "toolIconColor": hints.iconColor,
                "toolDescription": !title.isEmpty ? title : hints.description,
                "turnIndex": currentTurnIndex(for: sessionId)
            ]

            if ["edit", "write", "patch", "read"].contains(name) {
                if let path = input["path"] ?? input["filePath"], !path.isEmpty {
                    toolData["filePath"] = path
                }
            }

            events.append(NormalizedEvent(
                sessionId: sessionId,
                eventType: .toolStarted,
                data: toolData,
                content: toolContent
            ))

            // --- Tool Finished (if status is terminal) ---
            let isCompleted = status == "completed" || status == "error"
            if isCompleted {
                let isError = status == "error"
                var resultContent: [String: String]? = nil
                if !output.isEmpty {
                    resultContent = ["toolResultSummary": redactor.redactToolResult(output)]
                }

                events.append(NormalizedEvent(
                    sessionId: sessionId,
                    eventType: .toolFinished,
                    data: [
                        "toolUseId": callId,
                        "isError": "\(isError)",
                        "turnIndex": currentTurnIndex(for: sessionId)
                    ],
                    content: resultContent
                ))

                if isError {
                    events.append(NormalizedEvent(
                        sessionId: sessionId,
                        eventType: .errorRaised,
                        data: [
                            "toolName": name,
                            "turnIndex": currentTurnIndex(for: sessionId)
                        ]
                    ))
                }
                pendingTools.removeValue(forKey: callId)
            } else {
                // Tool is still running
                // Interactive tools (question) need immediate notification
                let interactiveTools: Set<String> = ["question"]
                if interactiveTools.contains(name) {
                    events.append(NormalizedEvent(
                        sessionId: sessionId,
                        eventType: .permissionNeeded,
                        data: [
                            "toolUseId": callId,
                            "toolName": name,
                            "toolDescription": !title.isEmpty ? title : hints.description,
                            "turnIndex": currentTurnIndex(for: sessionId)
                        ],
                        content: toolContent
                    ))
                }

                pendingTools[callId] = PendingToolInfo(
                    toolName: name,
                    sessionId: sessionId,
                    timestamp: Date(),
                    turnIndex: turnIndex[sessionId] ?? 0
                )
            }

        case .stepFinish(let reason, _, _, _):
            if reason == "stop" || reason == "end_turn" {
                events.append(NormalizedEvent(
                    sessionId: sessionId,
                    eventType: .turnCompleted,
                    data: [
                        "turnIndex": currentTurnIndex(for: sessionId)
                    ]
                ))
            }

        case .stepStart, .reasoning, .unknown:
            break
        }

        // Apply E2EE encryption if needed
        return events.map { event in
            if let encrypted = maybeEncryptContent(event.content, privacyMode: privacyMode, sessionId: sessionId) {
                return NormalizedEvent(
                    sessionId: event.sessionId,
                    eventType: event.eventType,
                    data: event.data,
                    content: encrypted
                )
            }
            return event
        }
    }

    mutating func checkPermissionStalls(stallTimeout: TimeInterval, activeSessions: Set<String>) -> [NormalizedEvent] {
        var events: [NormalizedEvent] = []
        var toRemove: [String] = []
        let now = Date()

        let slowTools: Set<String> = ["bash"]

        for (callId, info) in pendingTools {
            guard activeSessions.contains(info.sessionId) else {
                toRemove.append(callId)
                continue
            }
            if slowTools.contains(info.toolName) { continue }
            if info.stallEmitted { continue }

            if now.timeIntervalSince(info.timestamp) > stallTimeout {
                events.append(NormalizedEvent(
                    sessionId: info.sessionId,
                    eventType: .permissionNeeded,
                    data: [
                        "toolUseId": callId,
                        "toolName": info.toolName,
                        "stalledSeconds": "\(Int(now.timeIntervalSince(info.timestamp)))",
                        "turnIndex": "\(info.turnIndex)"
                    ]
                ))
                pendingTools[callId]?.stallEmitted = true
            }
        }
        for id in toRemove {
            pendingTools.removeValue(forKey: id)
        }
        return events
    }
}
