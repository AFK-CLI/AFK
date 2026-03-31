//
//  OpenCodeToolProvider.swift
//  AFK-Agent
//

import Foundation

/// Tool display hints for OpenCode's built-in tools.
struct OpenCodeToolProvider: ToolProvider, Sendable {
    let providerName = "opencode"

    private struct ToolMeta {
        let icon: String
        let color: String
        let category: String
    }

    private static let toolMetaMap: [String: ToolMeta] = [
        "bash":         ToolMeta(icon: "terminal.fill",                     color: "#64D2FF", category: "shell"),
        "edit":         ToolMeta(icon: "pencil.line",                       color: "#BF5AF2", category: "file_edit"),
        "patch":        ToolMeta(icon: "pencil.line",                       color: "#BF5AF2", category: "file_edit"),
        "write":        ToolMeta(icon: "doc.badge.plus",                    color: "#5E5CE6", category: "file_write"),
        "read":         ToolMeta(icon: "doc.text.fill",                     color: "#30D158", category: "file_read"),
        "file":         ToolMeta(icon: "doc.text.fill",                     color: "#30D158", category: "file_read"),
        "view":         ToolMeta(icon: "doc.text.fill",                     color: "#30D158", category: "file_read"),
        "glob":         ToolMeta(icon: "folder.badge.magnifyingglass",      color: "#FF9F0A", category: "search"),
        "grep":         ToolMeta(icon: "magnifyingglass",                   color: "#FF9F0A", category: "search"),
        "ls":           ToolMeta(icon: "folder.fill",                       color: "#30D158", category: "file_read"),
        "question":     ToolMeta(icon: "questionmark.bubble.fill",           color: "#FFD60A", category: "tool"),
        "diagnostics":  ToolMeta(icon: "stethoscope",                       color: "#FF453A", category: "tool"),
        "fetch":        ToolMeta(icon: "globe",                             color: "#0A84FF", category: "web"),
        "sourcegraph":  ToolMeta(icon: "magnifyingglass.circle.fill",       color: "#0A84FF", category: "web"),
    ]

    private static let mcpMeta = ToolMeta(icon: "puzzlepiece.extension.fill", color: "#AC8E68", category: "mcp")
    private static let defaultMeta = ToolMeta(icon: "wrench.fill", color: "#8E8E93", category: "tool")

    private static func meta(for toolName: String) -> ToolMeta {
        if let m = toolMetaMap[toolName] { return m }
        if toolName.hasPrefix("mcp__") { return mcpMeta }
        return defaultMeta
    }

    func displayHints(toolName: String, input: [String: String]) -> ToolDisplayHints {
        let m = Self.meta(for: toolName)
        let desc = Self.description(for: toolName, input: input)
        return ToolDisplayHints(iconName: m.icon, iconColor: m.color, category: m.category, description: desc)
    }

    func structuredFields(toolName: String, input: [String: String]) -> [ToolInputField] {
        switch toolName {
        case "file", "view", "read":
            // OpenCode uses "filePath", Claude Code uses "path"
            let pathKey = input["filePath"] != nil ? "filePath" : "path"
            return Self.fields(from: input, specs: [("File", pathKey, "path")])
        case "write":
            return Self.fields(from: input, specs: [("File", "path", "path")])
        case "edit":
            return Self.fields(from: input, specs: [
                ("File", "path", "path"),
                ("Find", "old_string", "code"),
                ("Replace", "new_string", "code"),
            ])
        case "patch":
            return Self.fields(from: input, specs: [
                ("File", "path", "path"),
                ("Diff", "diff", "code"),
            ])
        case "bash":
            return Self.fields(from: input, specs: [
                ("Command", "command", "code"),
                ("Timeout", "timeout", "badge"),
            ])
        case "grep":
            return Self.fields(from: input, specs: [
                ("Pattern", "pattern", "code"),
                ("Path", "path", "path"),
                ("Glob", "include", "code"),
            ])
        case "glob":
            return Self.fields(from: input, specs: [
                ("Pattern", "pattern", "code"),
                ("Path", "path", "path"),
            ])
        case "ls":
            return Self.fields(from: input, specs: [("Path", "path", "path")])
        case "fetch":
            return Self.fields(from: input, specs: [("URL", "url", "text")])
        case "question":
            return Self.parseQuestionFields(input)
        case "diagnostics":
            return Self.fields(from: input, specs: [("Path", "path", "path")])
        case "sourcegraph":
            return Self.fields(from: input, specs: [("Query", "query", "text")])
        default:
            return Array(input.prefix(5)).map { key, value in
                ToolInputField(label: key, value: value, style: "text")
            }
        }
    }

    // MARK: - Description

    private static func description(for toolName: String, input: [String: String]) -> String {
        switch toolName {
        case "file", "view", "read":
            if let path = input["filePath"] ?? input["path"], !path.isEmpty {
                return "Reading \(filename(from: path))"
            }
            return "Reading file"
        case "write":
            if let path = input["path"], !path.isEmpty {
                return "Writing \(filename(from: path))"
            }
            return "Writing file"
        case "edit":
            if let path = input["path"], !path.isEmpty {
                return "Editing \(filename(from: path))"
            }
            return "Editing file"
        case "patch":
            if let path = input["path"], !path.isEmpty {
                return "Patching \(filename(from: path))"
            }
            return "Patching file"
        case "bash":
            if let cmd = input["command"], !cmd.isEmpty {
                return truncateDesc(cmd, maxLength: 80)
            }
            return "Running command"
        case "grep":
            if let pattern = input["pattern"], !pattern.isEmpty {
                return "Searching for \(truncateDesc(pattern))"
            }
            return "Searching files"
        case "glob":
            if let pattern = input["pattern"], !pattern.isEmpty {
                return "Finding files matching \(truncateDesc(pattern))"
            }
            return "Finding files"
        case "ls":
            if let path = input["path"], !path.isEmpty {
                return "Listing \(filename(from: path))"
            }
            return "Listing directory"
        case "fetch":
            if let url = input["url"], !url.isEmpty {
                return "Fetching \(truncateDesc(url))"
            }
            return "Fetching URL"
        case "question":
            if let qs = input["questions"] {
                let text = Self.extractQuestionText(qs)
                if !text.isEmpty { return "Asking: \(truncateDesc(text))" }
            }
            return "Asking a question"
        case "diagnostics":
            return "Running diagnostics"
        case "sourcegraph":
            if let query = input["query"], !query.isEmpty {
                return "Sourcegraph: \(truncateDesc(query))"
            }
            return "Searching Sourcegraph"
        default:
            if toolName.hasPrefix("mcp__") {
                return "MCP: \(toolName)"
            }
            return toolName
        }
    }

    // MARK: - Helpers

    private static func filename(from path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func truncateDesc(_ text: String, maxLength: Int = 60) -> String {
        if text.count <= maxLength { return text }
        return String(text.prefix(maxLength)) + "..."
    }

    private static func fields(from input: [String: String], specs: [(label: String, key: String, style: String)]) -> [ToolInputField] {
        specs.compactMap { spec in
            guard let value = input[spec.key], !value.isEmpty else { return nil }
            return ToolInputField(label: spec.label, value: value, style: spec.style)
        }
    }

    /// Parse the "questions" JSON array string from the question tool input.
    /// Returns structured fields showing each question and its options.
    private static func parseQuestionFields(_ input: [String: String]) -> [ToolInputField] {
        guard let questionsJSON = input["questions"],
              let data = questionsJSON.data(using: .utf8),
              let questions = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        var fields: [ToolInputField] = []
        for q in questions {
            if let question = q["question"] as? String, !question.isEmpty {
                fields.append(ToolInputField(label: "Question", value: question, style: "text"))
            }
            if let options = q["options"] as? [[String: Any]] {
                let labels = options.compactMap { $0["label"] as? String }
                if !labels.isEmpty {
                    fields.append(ToolInputField(label: "Options", value: labels.joined(separator: ", "), style: "text"))
                }
            }
        }
        return fields
    }

    /// Extract the first question text from the JSON questions array.
    private static func extractQuestionText(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let questions = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = questions.first,
              let text = first["question"] as? String else {
            return ""
        }
        return text
    }
}
