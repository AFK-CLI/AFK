//
//  ClaudeCodeToolProvider.swift
//  AFK-Agent
//

import Foundation

struct ClaudeCodeToolProvider: ToolProvider, Sendable {
    let providerName = "claude_code"

    // MARK: - Static tool metadata

    private struct ToolMeta {
        let icon: String
        let color: String
        let category: String
    }

    private static let toolMetaMap: [String: ToolMeta] = [
        "Read":             ToolMeta(icon: "doc.text.fill",                     color: "#30D158", category: "file_read"),
        "Write":            ToolMeta(icon: "doc.badge.plus",                    color: "#5E5CE6", category: "file_write"),
        "Edit":             ToolMeta(icon: "pencil.line",                       color: "#BF5AF2", category: "file_edit"),
        "Bash":             ToolMeta(icon: "terminal.fill",                     color: "#64D2FF", category: "shell"),
        "Grep":             ToolMeta(icon: "magnifyingglass",                   color: "#FF9F0A", category: "search"),
        "Glob":             ToolMeta(icon: "folder.badge.magnifyingglass",      color: "#FF9F0A", category: "search"),
        "WebFetch":         ToolMeta(icon: "globe",                             color: "#0A84FF", category: "web"),
        "WebSearch":        ToolMeta(icon: "magnifyingglass.circle.fill",       color: "#0A84FF", category: "web"),
        "Task":             ToolMeta(icon: "person.2.fill",                     color: "#AC8E68", category: "agent"),
        "TaskCreate":       ToolMeta(icon: "checklist",                         color: "#0A84FF", category: "task"),
        "TaskUpdate":       ToolMeta(icon: "checklist",                         color: "#0A84FF", category: "task"),
        "TodoWrite":        ToolMeta(icon: "checklist",                         color: "#0A84FF", category: "task"),
        "AskUserQuestion":  ToolMeta(icon: "questionmark.bubble.fill",          color: "#FF9500", category: "question"),
        "EnterPlanMode":    ToolMeta(icon: "map.fill",                          color: "#BF5AF2", category: "plan_enter"),
        "ExitPlanMode":     ToolMeta(icon: "map.fill",                          color: "#BF5AF2", category: "plan_exit"),
        "Skill":            ToolMeta(icon: "bolt.fill",                         color: "#FFD60A", category: "skill"),
    ]

    private static let mcpMeta = ToolMeta(icon: "puzzlepiece.extension.fill", color: "#AC8E68", category: "mcp")
    private static let defaultMeta = ToolMeta(icon: "wrench.fill", color: "#8E8E93", category: "tool")

    private static func meta(for toolName: String) -> ToolMeta {
        if let m = toolMetaMap[toolName] { return m }
        if toolName.hasPrefix("mcp__") { return mcpMeta }
        return defaultMeta
    }

    // MARK: - ToolProvider

    func displayHints(toolName: String, input: [String: String]) -> ToolDisplayHints {
        let m = Self.meta(for: toolName)
        let desc = Self.description(for: toolName, input: input)
        return ToolDisplayHints(iconName: m.icon, iconColor: m.color, category: m.category, description: desc)
    }

    func structuredFields(toolName: String, input: [String: String]) -> [ToolInputField] {
        switch toolName {
        case "Read":
            return Self.fields(from: input, specs: [
                ("File", "file_path", "path"),
                ("Offset", "offset", "badge"),
                ("Limit", "limit", "badge"),
            ])
        case "Write":
            return Self.fields(from: input, specs: [
                ("File", "file_path", "path"),
            ])
        case "Edit":
            return Self.fields(from: input, specs: [
                ("File", "file_path", "path"),
                ("Find", "old_string", "code"),
                ("Replace", "new_string", "code"),
            ])
        case "Bash":
            return Self.fields(from: input, specs: [
                ("Description", "description", "text"),
                ("Command", "command", "code"),
            ])
        case "Grep":
            return Self.fields(from: input, specs: [
                ("Pattern", "pattern", "code"),
                ("Path", "path", "path"),
                ("Glob", "glob", "code"),
            ])
        case "Glob":
            return Self.fields(from: input, specs: [
                ("Pattern", "pattern", "code"),
                ("Path", "path", "path"),
            ])
        case "WebFetch":
            return Self.fields(from: input, specs: [
                ("URL", "url", "text"),
                ("Prompt", "prompt", "text"),
            ])
        case "WebSearch":
            return Self.fields(from: input, specs: [
                ("Query", "query", "text"),
            ])
        case "Task":
            return Self.fields(from: input, specs: [
                ("Description", "description", "text"),
                ("Prompt", "prompt", "text"),
            ])
        case "TaskCreate":
            return Self.fields(from: input, specs: [
                ("Subject", "subject", "text"),
                ("Description", "description", "text"),
            ])
        case "TaskUpdate":
            return Self.fields(from: input, specs: [
                ("TaskID", "taskId", "badge"),
                ("Status", "status", "badge"),
            ])
        case "TodoWrite":
            return Self.parseTodoWriteFields(input: input)
        case "AskUserQuestion":
            return Self.parseAskUserQuestionFields(input: input)
        case "EnterPlanMode", "ExitPlanMode":
            return []
        case "Skill":
            return Self.fields(from: input, specs: [
                ("Skill", "skill", "badge"),
                ("Args", "args", "text"),
            ])
        default:
            // MCP and unknown tools: take first 5 input keys
            return Array(input.prefix(5)).map { key, value in
                ToolInputField(label: key, value: value, style: "text")
            }
        }
    }

    // MARK: - Description generation

    private static func description(for toolName: String, input: [String: String]) -> String {
        switch toolName {
        case "Read":
            return "Reading \(filename(from: input["file_path"]))"
        case "Write":
            return "Writing \(filename(from: input["file_path"]))"
        case "Edit":
            return "Editing \(filename(from: input["file_path"]))"
        case "Bash":
            if let desc = input["description"], !desc.isEmpty {
                return desc
            }
            return "Running command"
        case "Grep":
            if let pattern = input["pattern"], !pattern.isEmpty {
                return "Searching for \(truncateDesc(pattern))"
            }
            return "Searching files"
        case "Glob":
            if let pattern = input["pattern"], !pattern.isEmpty {
                return "Finding files matching \(truncateDesc(pattern))"
            }
            return "Finding files"
        case "WebFetch":
            if let url = input["url"], let host = urlHost(url) {
                return "Fetching \(host)"
            }
            return "Fetching URL"
        case "WebSearch":
            if let query = input["query"], !query.isEmpty {
                return "Searching for \(truncateDesc(query))"
            }
            return "Searching the web"
        case "Task":
            if let desc = input["description"], !desc.isEmpty {
                return "Spawning agent: \(truncateDesc(desc))"
            }
            return "Spawning agent"
        case "TaskCreate":
            if let subject = input["subject"], !subject.isEmpty {
                return "Creating task: \(truncateDesc(subject))"
            }
            return "Creating task"
        case "TaskUpdate":
            if let taskId = input["taskId"] {
                return "Updating task \(taskId)"
            }
            return "Updating task"
        case "TodoWrite":
            if let json = input["todos"],
               let data = json.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let total = arr.count
                let done = arr.filter { ($0["status"] as? String) == "completed" }.count
                return "Tasks (\(done)/\(total) done)"
            }
            return "Updating tasks"
        case "Skill":
            if let skill = input["skill"], !skill.isEmpty {
                return "Running skill: \(skill)"
            }
            return "Running skill"
        case "AskUserQuestion":
            if let q = Self.firstQuestionText(from: input["questions"]) {
                return truncateDesc(q, maxLength: 80)
            }
            return "Asking user a question"
        case "EnterPlanMode":
            return "Entering plan mode"
        case "ExitPlanMode":
            return "Exiting plan mode"
        default:
            if toolName.hasPrefix("mcp__") {
                return "MCP: \(toolName)"
            }
            return toolName
        }
    }

    // MARK: - Helpers

    private static func filename(from path: String?) -> String {
        guard let path, !path.isEmpty else { return "file" }
        return (path as NSString).lastPathComponent
    }

    private static func urlHost(_ urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        return url.host
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

    // MARK: - TodoWrite parsing

    /// Parses TodoWrite input into structured fields showing each todo item with status.
    private static func parseTodoWriteFields(input: [String: String]) -> [ToolInputField] {
        guard let json = input["todos"],
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return fields(from: input, specs: [("Todos", "todos", "text")])
        }
        return arr.compactMap { item in
            guard let content = item["content"] as? String, !content.isEmpty else { return nil }
            let status = item["status"] as? String ?? "pending"
            let activeForm = item["activeForm"] as? String
            // Encode status + activeForm into the style field for iOS to parse
            let style = "todo_\(status)"
            let value = activeForm.map { "\(content)\n\($0)" } ?? content
            return ToolInputField(label: status, value: value, style: style)
        }
    }

    // MARK: - AskUserQuestion parsing

    /// Extracts the first question text from the raw JSON "questions" value.
    private static func firstQuestionText(from questionsJSON: String?) -> String? {
        guard let json = questionsJSON,
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let q = arr.first?["question"] as? String, !q.isEmpty else { return nil }
        return q
    }

    /// Parses AskUserQuestion input into structured fields showing question + options.
    private static func parseAskUserQuestionFields(input: [String: String]) -> [ToolInputField] {
        guard let json = input["questions"],
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return fields(from: input, specs: [("Questions", "questions", "text")])
        }
        var result: [ToolInputField] = []
        for q in arr {
            if let text = q["question"] as? String, !text.isEmpty {
                result.append(ToolInputField(label: "Question", value: text, style: "text"))
            }
            if let options = q["options"] as? [[String: Any]] {
                let labels = options.compactMap { $0["label"] as? String }
                if !labels.isEmpty {
                    result.append(ToolInputField(label: "Options", value: labels.joined(separator: "  ·  "), style: "text"))
                }
            }
        }
        return result.isEmpty ? fields(from: input, specs: [("Questions", "questions", "text")]) : result
    }
}
