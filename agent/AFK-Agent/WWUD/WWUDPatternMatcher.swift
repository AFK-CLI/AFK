//
//  WWUDPatternMatcher.swift
//  AFK-Agent
//
//  Pattern extraction and matching logic for WWUD.
//  Extracts structured patterns from tool inputs and matches them
//  against historical decisions at multiple specificity levels.
//

import Foundation

struct WWUDPatternMatcher {

    // MARK: - Pattern Extraction

    /// Extract patterns at decreasing specificity levels from a permission request.
    /// Returns patterns from most specific (level 1) to least specific (level 4).
    static func extractPatterns(
        toolName: String,
        toolInput: [String: String],
        projectPath: String
    ) -> [WWUDPattern] {
        var patterns: [WWUDPattern] = []

        let commandPrefix = extractCommandPrefix(toolInput: toolInput, toolName: toolName)
        let filePath = toolInput["file_path"] ?? toolInput["notebook_path"]
        let fileExt = filePath.flatMap { extractFileExtension($0) }
        let fileDir = filePath.flatMap { extractRelativeDirectory($0, projectPath: projectPath) }
        let domain = extractDomain(toolInput: toolInput, toolName: toolName)

        // Level 1: tool + project + exact input (commandPrefix or filePath or domain)
        if commandPrefix != nil || fileDir != nil || domain != nil {
            patterns.append(WWUDPattern(
                toolName: toolName,
                projectPath: projectPath,
                commandPrefix: commandPrefix,
                fileDirectory: fileDir,
                fileExtension: fileExt,
                targetDomain: domain
            ))
        }

        // Level 2: tool + project + partial input (prefix without sub-command, or ext only)
        let broadPrefix = commandPrefix.flatMap { extractBroadPrefix($0) }
        if broadPrefix != nil || fileExt != nil || domain != nil {
            let level2 = WWUDPattern(
                toolName: toolName,
                projectPath: projectPath,
                commandPrefix: broadPrefix,
                fileDirectory: nil,
                fileExtension: fileExt,
                targetDomain: domain
            )
            if !patterns.contains(level2) {
                patterns.append(level2)
            }
        }

        // Level 3: tool + project only
        patterns.append(WWUDPattern(
            toolName: toolName,
            projectPath: projectPath,
            commandPrefix: nil,
            fileDirectory: nil,
            fileExtension: nil,
            targetDomain: nil
        ))

        // Level 4: tool only (informational, not used for auto-decisions)
        patterns.append(WWUDPattern(
            toolName: toolName,
            projectPath: nil,
            commandPrefix: nil,
            fileDirectory: nil,
            fileExtension: nil,
            targetDomain: nil
        ))

        return patterns
    }

    // MARK: - Decision Matching

    /// Check if a historical decision matches a given pattern.
    static func matches(decision: WWUDDecision, pattern: WWUDPattern) -> Bool {
        // Tool name must always match
        guard decision.toolName == pattern.toolName else { return false }

        // Project path must match if pattern specifies one
        if let pp = pattern.projectPath {
            guard decision.projectPath == pp else { return false }
        }

        // Command prefix: pattern prefix must be a prefix of (or equal to) the decision's prefix
        if let patternPrefix = pattern.commandPrefix {
            guard let decisionPrefix = decision.commandPrefix,
                  decisionPrefix.hasPrefix(patternPrefix)
            else { return false }
        }

        // File directory
        if let patternDir = pattern.fileDirectory {
            guard decision.fileDirectory == patternDir else { return false }
        }

        // File extension
        if let patternExt = pattern.fileExtension {
            guard decision.fileExtension == patternExt else { return false }
        }

        // Target domain
        if let patternDomain = pattern.targetDomain {
            guard decision.targetDomain == patternDomain else { return false }
        }

        return true
    }

    // MARK: - Input Extraction Helpers

    /// Extract command prefix (first 2 tokens) from Bash commands.
    /// "npm test --verbose" → "npm test"
    /// "rm -rf /tmp" → "rm -rf"
    /// "ls" → "ls"
    static func extractCommandPrefix(toolInput: [String: String], toolName: String) -> String? {
        guard toolName == "Bash", let command = toolInput["command"] else { return nil }
        let tokens = command.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.prefix(2).joined(separator: " ")
    }

    /// Extract the broad prefix (first token only) for level 2 matching.
    /// "npm test" → "npm"
    static func extractBroadPrefix(_ prefix: String) -> String? {
        let tokens = prefix.components(separatedBy: .whitespaces)
        guard tokens.count > 1 else { return nil } // already at broadest
        return tokens.first
    }

    /// Extract file extension from a path.
    /// "/src/utils.ts" → ".ts"
    static func extractFileExtension(_ path: String) -> String? {
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? nil : ".\(ext)"
    }

    /// Extract directory path relative to the project root.
    /// "/project/src/lib/utils.ts" with project "/project" → "src/lib"
    static func extractRelativeDirectory(_ path: String, projectPath: String) -> String? {
        let dir = (path as NSString).deletingLastPathComponent
        if dir.hasPrefix(projectPath) {
            var relative = String(dir.dropFirst(projectPath.count))
            if relative.hasPrefix("/") { relative = String(relative.dropFirst()) }
            return relative.isEmpty ? "." : relative
        }
        return (dir as NSString).lastPathComponent
    }

    /// Extract the hostname from WebFetch/WebSearch URL.
    static func extractDomain(toolInput: [String: String], toolName: String) -> String? {
        guard toolName == "WebFetch" || toolName == "WebSearch" else { return nil }
        let urlString = toolInput["url"] ?? toolInput["query"]
        guard let urlString, let url = URL(string: urlString) else { return nil }
        return url.host
    }

    // MARK: - Decision Factory

    /// Create a WWUDDecision from a permission request context.
    static func createDecision(
        toolName: String,
        toolInput: [String: String],
        projectPath: String,
        action: String,
        source: String,
        weight: Double = 1.0
    ) -> WWUDDecision {
        let commandPrefix = extractCommandPrefix(toolInput: toolInput, toolName: toolName)
        let filePath = toolInput["file_path"] ?? toolInput["notebook_path"]
        let fileExt = filePath.flatMap { extractFileExtension($0) }
        let fileDir = filePath.flatMap { extractRelativeDirectory($0, projectPath: projectPath) }
        let domain = extractDomain(toolInput: toolInput, toolName: toolName)

        // Build input summary (truncated to 500 chars)
        let summary: String
        if let cmd = toolInput["command"] {
            summary = String(cmd.prefix(500))
        } else if let fp = filePath {
            summary = String(fp.prefix(500))
        } else {
            summary = String(toolInput.values.joined(separator: " ").prefix(500))
        }

        return WWUDDecision(
            id: UUID().uuidString,
            timestamp: Date(),
            toolName: toolName,
            projectPath: projectPath,
            commandPrefix: commandPrefix,
            filePath: filePath,
            fileExtension: fileExt,
            fileDirectory: fileDir,
            targetDomain: domain,
            inputSummary: summary,
            action: action,
            source: source,
            weight: weight
        )
    }
}
