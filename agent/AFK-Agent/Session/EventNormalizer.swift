//
//  EventNormalizer.swift
//  AFK-Agent
//

import Foundation

struct EventNormalizer: Sendable {
    private var turnIndex: [String: Int] = [:]
    private var pendingToolUses: [String: ToolUseInfo] = [:]  // toolUseId -> info
    private let redactor = ContentRedactor()
    let toolProvider: ToolProvider

    init(toolProvider: ToolProvider = ClaudeCodeToolProvider()) {
        self.toolProvider = toolProvider
    }

    struct ToolUseInfo: Sendable {
        let toolName: String
        let sessionId: String
        let timestamp: Date
        let turnIndex: Int
        var stallEmitted: Bool = false
    }

    /// Returns the current turn index for a session as a string, suitable for event data dictionaries.
    private func currentTurnIndex(for sessionId: String) -> String {
        "\(turnIndex[sessionId] ?? 0)"
    }

    // Tools that legitimately take >10s — never emit permission stall for these
    private static let slowToolNames: Set<String> = [
        "Task", "Bash", "EnterPlanMode", "ExitPlanMode", "AskUserQuestion"
    ]
    private static func isKnownSlowTool(_ name: String) -> Bool {
        slowToolNames.contains(name) || name.hasPrefix("mcp__")
    }

    /// Agent always extracts and redacts content regardless of privacy mode.
    /// Privacy mode controls backend-side storage, not agent-side extraction.
    /// The backend decides whether to persist content to DB or only relay via WS.
    private static func includesContent(_ privacyMode: String) -> Bool {
        return true
    }

    /// Optional content encryptor for E2EE mode. Set by the Agent when a session
    /// key is available. Accepts (content, sessionId) and returns the encrypted version.
    var contentEncryptor: (@Sendable ([String: String], String) -> [String: String]?)?

    /// If an encryptor is set and privacy mode is "encrypted", encrypt content fields.
    private func maybeEncryptContent(_ content: [String: String]?, privacyMode: String, sessionId: String) -> [String: String]? {
        guard let content, privacyMode == "encrypted", let encryptor = contentEncryptor else {
            return content
        }
        return encryptor(content, sessionId)
    }

    mutating func normalize(entry: RawJSONLEntry, sessionId: String, projectPath: String, privacyMode: String = "telemetry_only") -> [NormalizedEvent] {
        var events: [NormalizedEvent] = []
        let sendContent = Self.includesContent(privacyMode)

        switch entry.type {
        case "user":
            // Check if this is the session start (first entry with no parent)
            if entry.parentUuid == nil && (turnIndex[sessionId] ?? 0) == 0 {
                events.append(NormalizedEvent(
                    sessionId: sessionId,
                    eventType: .sessionStarted,
                    data: [
                        "projectPath": projectPath,
                        "gitBranch": entry.gitBranch ?? "",
                        "cwd": entry.cwd ?? "",
                        "turnIndex": "0"
                    ]
                ))
            }

            // External user message = new turn
            if entry.userType == "external" {
                let idx = (turnIndex[sessionId] ?? 0) + 1
                turnIndex[sessionId] = idx

                // Build content snippet for user message if privacy mode allows
                var turnContent: [String: String]? = nil
                if sendContent, let msgContent = entry.message?.content {
                    let userText = Self.stripSystemTags(msgContent.textContent)
                    if !userText.isEmpty {
                        turnContent = ["userSnippet": redactor.redactSnippet(userText)]
                    }
                    // Extract images from user message (e.g. screenshots pasted to Claude Code)
                    let images = msgContent.imageBlocks
                    if !images.isEmpty {
                        if turnContent == nil { turnContent = [:] }
                        Self.encodeResultImages(images, into: &turnContent!)
                    }
                }

                events.append(NormalizedEvent(
                    sessionId: sessionId,
                    eventType: .turnStarted,
                    data: ["turnIndex": "\(idx)"],
                    content: turnContent
                ))
            }

            // Check for tool_result in content
            if let content = entry.message?.content {
                switch content {
                case .blocks(let blocks):
                    for block in blocks where block.type == "tool_result" {
                        if let toolUseId = block.toolUseId {
                            // Build content for tool result if privacy mode allows
                            var resultContent: [String: String]? = nil
                            if sendContent, let resultBody = block.content {
                                let resultText = resultBody.textContent
                                if !resultText.isEmpty {
                                    resultContent = ["toolResultSummary": redactor.redactToolResult(resultText)]
                                }
                                // Extract image data from tool result (e.g. Read tool on image files)
                                let images = resultBody.imageBlocks
                                if !images.isEmpty {
                                    if resultContent == nil { resultContent = [:] }
                                    Self.encodeResultImages(images, into: &resultContent!)
                                }
                            }

                            let toolTurnIndex = pendingToolUses[toolUseId].map { "\($0.turnIndex)" } ?? currentTurnIndex(for: sessionId)
                            let toolName = pendingToolUses[toolUseId]?.toolName ?? "unknown"

                            // AskUserQuestion answered from iOS comes back as a hook denial (is_error=true)
                            // but it's not a real error — suppress it
                            let resultText = block.content?.textContent ?? ""
                            let isAnsweredFromMobile = toolName == "AskUserQuestion" && resultText.contains("User answered from AFK mobile")
                            let effectiveError = (block.isError ?? false) && !isAnsweredFromMobile

                            events.append(NormalizedEvent(
                                sessionId: sessionId,
                                eventType: .toolFinished,
                                data: [
                                    "toolUseId": toolUseId,
                                    "isError": "\(effectiveError)",
                                    "turnIndex": toolTurnIndex
                                ],
                                content: resultContent
                            ))
                            if effectiveError {
                                events.append(NormalizedEvent(
                                    sessionId: sessionId,
                                    eventType: .errorRaised,
                                    data: [
                                        "toolName": toolName,
                                        "turnIndex": toolTurnIndex
                                    ]
                                ))
                            }
                            pendingToolUses.removeValue(forKey: toolUseId)
                        }
                    }
                default:
                    break
                }
            }

        case "assistant":
            // Check content blocks for text and tool_use
            if let content = entry.message?.content {
                switch content {
                case .text(let text):
                    var assistantContent: [String: String]? = nil
                    if sendContent && !text.isEmpty {
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
                case .blocks(let blocks):
                    var hasText = false
                    for block in blocks {
                        if block.type == "text", let text = block.text {
                            if !hasText {
                                var assistantContent: [String: String]? = nil
                                if sendContent && !text.isEmpty {
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
                                hasText = true
                            }
                        }
                        if block.type == "tool_use", let id = block.id {
                            let toolName = block.name ?? "unknown"
                            pendingToolUses[id] = ToolUseInfo(
                                toolName: toolName,
                                sessionId: sessionId,
                                timestamp: Date(),
                                turnIndex: turnIndex[sessionId] ?? 0
                            )

                            // Use provider for display hints
                            let inputDict = block.input?.asStringDictionary ?? [:]
                            let hints = toolProvider.displayHints(toolName: toolName, input: inputDict)

                            // Build content for tool input if privacy mode allows
                            var toolContent: [String: String]? = nil
                            if sendContent, !inputDict.isEmpty {
                                let redacted = redactor.redactToolInput(inputDict, toolName: toolName)

                                // Legacy flat summary (backward compat)
                                let summary = redacted.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
                                toolContent = ["toolInputSummary": redactor.truncate(summary, maxLength: 1000)]

                                // Structured fields — provider builds them, we redact the values
                                var fields = toolProvider.structuredFields(toolName: toolName, input: redacted)
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
                                "toolName": toolName,
                                "toolUseId": id,
                                "toolCategory": hints.category,
                                "toolIcon": hints.iconName,
                                "toolIconColor": hints.iconColor,
                                "toolDescription": hints.description,
                                "turnIndex": currentTurnIndex(for: sessionId)
                            ]

                            // Add file path for write-type tools (in data, not content — never encrypted)
                            if ["Edit", "Write", "NotebookEdit"].contains(toolName) {
                                if let path = inputDict["file_path"] ?? inputDict["notebook_path"], !path.isEmpty {
                                    toolData["filePath"] = path
                                }
                            }

                            events.append(NormalizedEvent(
                                sessionId: sessionId,
                                eventType: .toolStarted,
                                data: toolData,
                                content: toolContent
                            ))
                        }
                    }
                case .dictionary:
                    break
                }
            }

            // Usage update
            if let usage = entry.message?.usage,
               let input = usage.inputTokens, let output = usage.outputTokens {
                let cacheRead = usage.cacheReadInputTokens ?? 0
                let cacheCreation = usage.cacheCreationInputTokens ?? 0
                events.append(NormalizedEvent(
                    sessionId: sessionId,
                    eventType: .usageUpdate,
                    data: [
                        "inputTokens": "\(input)",
                        "outputTokens": "\(output)",
                        "cacheReadInputTokens": "\(cacheRead)",
                        "cacheCreationInputTokens": "\(cacheCreation)",
                        "turnIndex": currentTurnIndex(for: sessionId)
                    ]
                ))
            }

        case "system":
            if entry.subtype == "turn_duration", let duration = entry.durationMs {
                events.append(NormalizedEvent(
                    sessionId: sessionId,
                    eventType: .turnCompleted,
                    data: [
                        "durationMs": "\(duration)",
                        "turnIndex": currentTurnIndex(for: sessionId)
                    ]
                ))
            }

        default:
            break
        }

        // If privacy mode is "encrypted" and an encryptor is set, encrypt content fields.
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

    // MARK: - Tool Description Builder

    /// Builds a human-readable one-liner from tool name + input dict.
    /// This runs on the agent so iOS never needs to parse tool inputs.
    static func buildToolDescription(toolName: String, input: [String: String]) -> String {
        switch toolName {
        case "Bash":
            // Prefer the `description` field (Claude puts a human summary there)
            if let desc = input["description"], !desc.isEmpty {
                return truncate(desc, maxLength: 80)
            }
            if let cmd = input["command"], !cmd.isEmpty {
                return truncate(cmd, maxLength: 80)
            }
            return "Bash"

        case "Read":
            if let path = input["file_path"], !path.isEmpty {
                return "Reading \(shortenPath(path))"
            }
            return "Reading file"

        case "Write":
            if let path = input["file_path"], !path.isEmpty {
                return "Writing \(shortenPath(path))"
            }
            return "Writing file"

        case "Edit":
            if let path = input["file_path"], !path.isEmpty {
                return "Editing \(shortenPath(path))"
            }
            return "Editing file"

        case "Grep":
            if let pattern = input["pattern"], !pattern.isEmpty {
                return "Searching \(truncate(pattern, maxLength: 50))"
            }
            return "Searching"

        case "Glob":
            if let pattern = input["pattern"], !pattern.isEmpty {
                return "Finding \(truncate(pattern, maxLength: 50))"
            }
            return "Finding files"

        case "WebFetch":
            if let url = input["url"], !url.isEmpty {
                return "Fetching \(truncate(url, maxLength: 60))"
            }
            return "Fetching URL"

        case "WebSearch":
            if let query = input["query"], !query.isEmpty {
                return "Searching \(truncate(query, maxLength: 60))"
            }
            return "Web search"

        case "TaskCreate":
            if let subject = input["subject"], !subject.isEmpty {
                return truncate(subject, maxLength: 80)
            }
            return "Creating task"

        case "TaskUpdate":
            if let subject = input["subject"], !subject.isEmpty {
                return truncate(subject, maxLength: 80)
            }
            if let status = input["status"] {
                return "Task → \(status)"
            }
            return "Updating task"

        case "Task":
            if let desc = input["description"], !desc.isEmpty {
                return truncate(desc, maxLength: 80)
            }
            return "Spawning agent"

        case "AskUserQuestion":
            if let q = input["question"], !q.isEmpty {
                return truncate(q, maxLength: 80)
            }
            return "Asking question"

        case "EnterPlanMode":
            return "Entering plan mode"

        case "ExitPlanMode":
            return "Plan ready for review"

        case "NotebookEdit":
            return "Editing notebook"

        case "Skill":
            if let skill = input["skill"], !skill.isEmpty {
                return "Running /\(skill)"
            }
            return "Running skill"

        default:
            // MCP tools or unknown — show the tool name itself
            return toolName
        }
    }

    /// Max total base64 image data to include in a single event (500 KB).
    private static let maxImageDataBytes = 500 * 1024

    /// Encodes image blocks into the content dictionary as JSON.
    /// Stores as `toolResultImages`: `[{"mediaType":"image/png","data":"base64..."}]`
    private static func encodeResultImages(_ images: [ImageSource], into content: inout [String: String]) {
        struct ImageEntry: Codable {
            let mediaType: String
            let data: String
        }
        var entries: [ImageEntry] = []
        var totalBytes = 0
        for img in images {
            let dataBytes = img.data.utf8.count
            if totalBytes + dataBytes > maxImageDataBytes { break }
            entries.append(ImageEntry(mediaType: img.mediaType, data: img.data))
            totalBytes += dataBytes
        }
        guard !entries.isEmpty,
              let json = try? JSONEncoder().encode(entries),
              let str = String(data: json, encoding: .utf8) else { return }
        content["toolResultImages"] = str
    }

    /// Shortens a file path to just the last 2 components.
    private static func shortenPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        if components.count <= 2 { return path }
        return components.suffix(2).joined(separator: "/")
    }

    /// Strips CLI system/meta XML tags (e.g. `<local-command-caveat>`, `<command-name>`)
    /// that are injected by Claude Code but meaningless outside the terminal.
    private static func stripSystemTags(_ text: String) -> String {
        let pattern = "<(local-command-caveat|command-name|command-message|command-args|local-command-stdout|system-reminder)>[\\s\\S]*?</\\1>"
        return text
            .replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Truncates a string, collapsing whitespace.
    private static func truncate(_ text: String, maxLength: Int) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.count <= maxLength { return cleaned }
        return String(cleaned.prefix(maxLength - 1)) + "\u{2026}"
    }

    mutating func checkPermissionStalls(stallTimeout: TimeInterval, activeSessions: Set<String>) -> [NormalizedEvent] {
        var events: [NormalizedEvent] = []
        var toRemove: [String] = []
        let now = Date()
        for (toolUseId, info) in pendingToolUses {
            // Clean up tools for sessions that are no longer active
            guard activeSessions.contains(info.sessionId) else {
                toRemove.append(toolUseId)
                continue
            }
            // Never flag known-slow tools as permission stalls
            if Self.isKnownSlowTool(info.toolName) { continue }
            // Already emitted a stall for this tool — don't spam
            if info.stallEmitted { continue }

            if now.timeIntervalSince(info.timestamp) > stallTimeout {
                events.append(NormalizedEvent(
                    sessionId: info.sessionId,
                    eventType: .permissionNeeded,
                    data: [
                        "toolUseId": toolUseId,
                        "toolName": info.toolName,
                        "stalledSeconds": "\(Int(now.timeIntervalSince(info.timestamp)))",
                        "turnIndex": "\(info.turnIndex)"
                    ]
                ))
                // Mark as emitted instead of removing — toolFinished still needs the entry
                pendingToolUses[toolUseId]?.stallEmitted = true
            }
        }
        for id in toRemove {
            pendingToolUses.removeValue(forKey: id)
        }
        return events
    }
}
