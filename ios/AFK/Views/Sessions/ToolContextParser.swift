import Foundation

enum ToolContextParser {
    /// Parses a tool's input summary into a short one-liner for display on collapsed cards and LiveActivity.
    static func contextLine(toolName: String, toolInputSummary: String?) -> String? {
        guard let summary = toolInputSummary, !summary.isEmpty else { return nil }

        switch toolName {
        case "Bash":
            // Prefer `description` field, fall back to truncated `command`
            if let desc = extractField("description", from: summary) {
                return desc
            }
            if let cmd = extractField("command", from: summary) {
                return truncate(cmd, to: 60)
            }
            return truncate(summary, to: 60)

        case "Read":
            if let path = extractField("file_path", from: summary) {
                return shortenPath(path)
            }
            return truncate(summary, to: 60)

        case "Write":
            if let path = extractField("file_path", from: summary) {
                return "Writing \(shortenPath(path))"
            }
            return "Writing file"

        case "Edit":
            if let path = extractField("file_path", from: summary) {
                return "Editing \(shortenPath(path))"
            }
            return "Editing file"

        case "Grep":
            if let pattern = extractField("pattern", from: summary) {
                return truncate(pattern, to: 60)
            }
            return truncate(summary, to: 60)

        case "Glob":
            if let pattern = extractField("pattern", from: summary) {
                return truncate(pattern, to: 60)
            }
            return truncate(summary, to: 60)

        case "TaskCreate", "TaskUpdate":
            if let subject = extractField("subject", from: summary) {
                return truncate(subject, to: 60)
            }
            return truncate(summary, to: 60)

        case "AskUserQuestion":
            if let question = extractField("question", from: summary) {
                return truncate(question, to: 60)
            }
            return truncate(summary, to: 60)

        default:
            return truncate(summary, to: 60)
        }
    }

    /// Extracts a JSON field value from a summary string.
    /// Handles both pretty-printed JSON and "key: value" style summaries.
    static func extractField(_ field: String, from summary: String) -> String? {
        // Try JSON parsing first
        if let data = summary.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = dict[field] {
            if let str = value as? String, !str.isEmpty {
                return str
            }
        }

        // Fallback: look for "field": "value" pattern in text
        let pattern = "\"\(field)\"\\s*:\\s*\"([^\"]*)\""
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: summary, range: NSRange(summary.startIndex..., in: summary)),
           let range = Range(match.range(at: 1), in: summary) {
            let value = String(summary[range])
            return value.isEmpty ? nil : value
        }

        return nil
    }

    /// Shortens a file path to just the last 2 components.
    static func shortenPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        if components.count <= 2 {
            return path
        }
        return components.suffix(2).joined(separator: "/")
    }

    private static func truncate(_ text: String, to maxLength: Int) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if cleaned.count <= maxLength {
            return cleaned
        }
        return String(cleaned.prefix(maxLength - 1)) + "\u{2026}"
    }
}
