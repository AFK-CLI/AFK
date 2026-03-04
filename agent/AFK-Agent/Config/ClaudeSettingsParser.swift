//
//  ClaudeSettingsParser.swift
//  AFK-Agent
//
//  Parses Claude's settings.json allow/deny rules to auto-approve or auto-deny
//  permission requests without forwarding to iOS.
//

import Foundation
import OSLog

enum SettingsPermissionDecision {
    case allow
    case deny
    case ask
}

struct ClaudeSettingsParser {
    let allowRules: [String]
    let denyRules: [String]

    init(projectPath: String?) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // 1. Parse global ~/.claude/settings.json
        let globalPath = "\(home)/.claude/settings.json"
        let globalPermissions = Self.parsePermissions(at: globalPath)

        // 2. Parse local project settings.json (if available)
        // Also check .claude/settings.local.json for local overrides
        var localPermissions = SettingsPermissions(allow: [], deny: [])
        if let projectPath, !projectPath.isEmpty {
            let projectSettingsPath = "\(projectPath)/.claude/settings.json"
            let projectLocalSettingsPath = "\(projectPath)/.claude/settings.local.json"
            let projectSettings = Self.parsePermissions(at: projectSettingsPath)
            let localSettings = Self.parsePermissions(at: projectLocalSettingsPath)
            // Merge project + local: union both
            localPermissions = SettingsPermissions(
                allow: projectSettings.allow + localSettings.allow,
                deny: projectSettings.deny + localSettings.deny
            )
        }

        // 3. Merge global + project: union both arrays
        self.allowRules = globalPermissions.allow + localPermissions.allow
        self.denyRules = globalPermissions.deny + localPermissions.deny

        let allowCount = self.allowRules.count
        let denyCount = self.denyRules.count
        if allowCount > 0 || denyCount > 0 {
            AppLogger.permission.debug("Settings rules loaded: \(allowCount, privacy: .public) allow, \(denyCount, privacy: .public) deny")
        }
    }

    func decision(for toolName: String, toolInput: String?) -> SettingsPermissionDecision {
        // Deny rules take precedence over allow rules
        for rule in denyRules {
            if matches(rule: rule, toolName: toolName, toolInput: toolInput) {
                AppLogger.permission.info("Settings deny rule matched: \(rule, privacy: .public) for \(toolName, privacy: .public)")
                return .deny
            }
        }

        for rule in allowRules {
            if matches(rule: rule, toolName: toolName, toolInput: toolInput) {
                AppLogger.permission.info("Settings allow rule matched: \(rule, privacy: .public) for \(toolName, privacy: .public)")
                return .allow
            }
        }

        return .ask
    }

    // MARK: - Rule Matching

    /// Match a rule against a tool name and optional input.
    ///
    /// Rule formats:
    ///   "Edit"              — matches any use of the Edit tool
    ///   "Bash(npm test)"    — matches Bash with input exactly "npm test"
    ///   "Bash(npm *)"       — matches Bash with input starting with "npm "
    ///   "Write(**/docs/**)" — matches Write with path matching the glob
    private func matches(rule: String, toolName: String, toolInput: String?) -> Bool {
        // Parse rule into tool name + optional pattern
        let (ruleTool, rulePattern) = Self.parseRule(rule)

        // Tool name must match
        guard ruleTool == toolName else { return false }

        // No pattern means match any use of this tool
        guard let pattern = rulePattern else { return true }

        // Need input to match against
        guard let input = toolInput, !input.isEmpty else { return false }

        return Self.globMatch(pattern: pattern, text: input)
    }

    /// Parse a rule string into (toolName, optionalPattern).
    /// "Bash(npm test)" -> ("Bash", "npm test")
    /// "Edit" -> ("Edit", nil)
    static func parseRule(_ rule: String) -> (tool: String, pattern: String?) {
        guard let openParen = rule.firstIndex(of: "("),
              rule.hasSuffix(")") else {
            return (rule.trimmingCharacters(in: .whitespaces), nil)
        }

        let tool = String(rule[rule.startIndex..<openParen]).trimmingCharacters(in: .whitespaces)
        let patternStart = rule.index(after: openParen)
        let patternEnd = rule.index(before: rule.endIndex)
        let pattern = String(rule[patternStart..<patternEnd])
        return (tool, pattern)
    }

    /// Simple glob matching supporting `*` (any chars within segment) and `**` (any path segments).
    ///
    /// Uses Darwin fnmatch for glob matching with FNM_PATHNAME disabled so `*` can
    /// match path separators when `**` is not present. For `**` patterns, we use
    /// FNM_PATHNAME with `**` expanded to match any depth.
    static func globMatch(pattern: String, text: String) -> Bool {
        // If no wildcards, do exact comparison
        if !pattern.contains("*") && !pattern.contains("?") {
            return pattern == text
        }

        // Convert ** to match any path segments by replacing with a marker,
        // then use fnmatch. For patterns with **, we split and check segments.
        if pattern.contains("**") {
            return doubleStarMatch(pattern: pattern, text: text)
        }

        // Simple * glob: use fnmatch without FNM_PATHNAME so * matches /
        return fnmatch(pattern, text, 0) == 0
    }

    /// Handle ** glob patterns by splitting on ** and matching each segment.
    private static func doubleStarMatch(pattern: String, text: String) -> Bool {
        let segments = pattern.components(separatedBy: "**")

        // Single ** means match everything
        if segments.count == 2 && segments[0].isEmpty && segments[1].isEmpty {
            return true
        }

        // For patterns like "**/docs/**", split and verify:
        // - Everything before ** must match the start of the text
        // - Everything after ** must match the end of the text
        // - Middle ** matches any path segments

        // Check first segment (before first **)
        let first = segments[0]
        if !first.isEmpty {
            let firstTrimmed = first.hasSuffix("/") ? String(first.dropLast()) : first
            if !firstTrimmed.isEmpty {
                let prefix = String(text.prefix(firstTrimmed.count))
                guard fnmatch(firstTrimmed, prefix, 0) == 0 || text.hasPrefix(firstTrimmed) else {
                    return false
                }
            }
        }

        // Check last segment (after last **)
        let last = segments[segments.count - 1]
        if !last.isEmpty {
            let lastTrimmed = last.hasPrefix("/") ? String(last.dropFirst()) : last
            if !lastTrimmed.isEmpty {
                let suffix = String(text.suffix(lastTrimmed.count))
                guard fnmatch(lastTrimmed, suffix, 0) == 0 else {
                    return false
                }
            }
        }

        // Collapse ** into * and use fnmatch for the full pattern
        let expandedPattern = pattern.replacingOccurrences(of: "**", with: "*")
        return fnmatch(expandedPattern, text, 0) == 0
    }

    // MARK: - JSON Parsing

    private struct SettingsPermissions {
        let allow: [String]
        let deny: [String]
    }

    private static func parsePermissions(at path: String) -> SettingsPermissions {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let permissions = json["permissions"] as? [String: Any] else {
            return SettingsPermissions(allow: [], deny: [])
        }

        let allow = permissions["allow"] as? [String] ?? []
        let deny = permissions["deny"] as? [String] ?? []
        return SettingsPermissions(allow: allow, deny: deny)
    }
}
