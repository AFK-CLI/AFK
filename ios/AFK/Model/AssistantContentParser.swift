import Foundation

enum AssistantContentParser {

    /// Parse assistant text into interleaved content blocks.
    /// Returns a single `.text` block if no special tags are found (fast path).
    static func parse(_ text: String) -> [AssistantContentBlock] {
        let hasTask = text.contains("<task-notification>")
        let hasTeammate = text.contains("<teammate-message")
        guard hasTask || hasTeammate else {
            return [.text(text)]
        }

        // Strip checkbox prefixes before XML tags
        let preprocessed = text.replacingOccurrences(
            of: "(?m)^-\\s*\\[[ x]\\]\\s*(?=<(task-notification|teammate-message))",
            with: "",
            options: .regularExpression
        )

        var blocks: [AssistantContentBlock] = []
        var remaining = preprocessed[preprocessed.startIndex...]

        while !remaining.isEmpty {
            guard let (nextStart, isTask) = findNextTag(in: remaining) else {
                // No more tags; everything remaining is text
                appendTextIfNonEmpty(String(remaining), to: &blocks)
                break
            }

            // Capture text before this tag
            if nextStart > remaining.startIndex {
                appendTextIfNonEmpty(String(remaining[remaining.startIndex..<nextStart]), to: &blocks)
            }

            if isTask {
                if let (data, endIdx) = parseTaskNotification(remaining[nextStart...]) {
                    blocks.append(.taskNotification(data))
                    remaining = remaining[endIdx...]
                } else {
                    // Malformed tag; skip past the `<` to avoid infinite loop
                    let after = remaining.index(after: nextStart)
                    remaining = remaining[after...]
                }
            } else {
                if let (data, endIdx) = parseTeammateMessage(remaining[nextStart...]) {
                    blocks.append(.teammateMessage(data))
                    remaining = remaining[endIdx...]
                } else {
                    let after = remaining.index(after: nextStart)
                    remaining = remaining[after...]
                }
            }
        }

        return blocks.isEmpty ? [.text(text)] : blocks
    }

    /// Find the next `<task-notification>` or `<teammate-message` tag in the text.
    /// Returns the start index and whether it is a task notification (`true`) or teammate message (`false`).
    private static func findNextTag(in text: Substring) -> (String.Index, Bool)? {
        let taskRange = text.range(of: "<task-notification>")
        let teammateRange = text.range(of: "<teammate-message")

        switch (taskRange?.lowerBound, teammateRange?.lowerBound) {
        case let (t?, m?):
            return t < m ? (t, true) : (m, false)
        case let (t?, nil):
            return (t, true)
        case let (nil, m?):
            return (m, false)
        case (nil, nil):
            return nil
        }
    }

    // MARK: - Task Notification

    private static func parseTaskNotification(_ text: Substring) -> (TaskNotificationData, String.Index)? {
        let openTag = "<task-notification>"
        let closeTag = "</task-notification>"
        guard let openRange = text.range(of: openTag),
              let closeRange = text.range(of: closeTag) else { return nil }

        let body = String(text[openRange.upperBound..<closeRange.lowerBound])

        let data = TaskNotificationData(
            taskId: extractField("task-id", from: body) ?? UUID().uuidString,
            toolUseId: extractField("tool-use-id", from: body),
            status: extractField("status", from: body) ?? "unknown",
            summary: extractField("summary", from: body) ?? "",
            result: extractField("result", from: body)
        )
        return (data, closeRange.upperBound)
    }

    // MARK: - Teammate Message

    private static func parseTeammateMessage(_ text: Substring) -> (TeammateMessageData, String.Index)? {
        let closeTag = "</teammate-message>"
        guard let closeRange = text.range(of: closeTag) else { return nil }

        // Find the end of the opening tag `<teammate-message ... >`
        guard let openEnd = text.range(of: ">") else { return nil }
        let openTag = String(text[text.startIndex..<openEnd.upperBound])

        let teammateId = extractAttribute("teammate_id", from: openTag) ?? "unknown"
        let color = extractAttribute("color", from: openTag)

        let body = String(text[openEnd.upperBound..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse JSON body
        var messageType = "unknown"
        var from: String?
        var timestamp: String?
        var displayMessage: String?

        if let jsonData = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            messageType = json["type"] as? String ?? "unknown"
            from = json["from"] as? String
            timestamp = json["timestamp"] as? String
            displayMessage = json["message"] as? String
        }

        let data = TeammateMessageData(
            teammateId: teammateId,
            color: color,
            messageType: messageType,
            from: from,
            timestamp: timestamp,
            displayMessage: displayMessage
        )
        return (data, closeRange.upperBound)
    }

    // MARK: - Helpers

    private static func extractField(_ name: String, from body: String) -> String? {
        let pattern = "<\(name)>([\\s\\S]*?)</\(name)>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body) else { return nil }
        let value = String(body[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func extractAttribute(_ name: String, from tag: String) -> String? {
        let pattern = "\(name)=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range])
    }

    private static func appendTextIfNonEmpty(_ text: String, to blocks: inout [AssistantContentBlock]) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            blocks.append(.text(cleaned))
        }
    }
}
