//
//  PermissionEvaluator.swift
//  AFK-Agent
//
//  Pure-function permission evaluation logic extracted from PermissionSocket.
//  Both PermissionSocket (Unix domain socket) and HookHTTPServer (HTTP) use
//  this to make consistent permission decisions without duplicating logic.
//

import Foundation
import OSLog

struct PermissionEvaluator: Sendable {

    enum Decision: Sendable {
        case allow(reason: String)
        case deny(reason: String)
        case askRemote                                      // forward to iOS for human decision
        case wwudAllow(confidence: Double, pattern: WWUDPattern, decisionId: String)
        case wwudDeny(confidence: Double, pattern: WWUDPattern, decisionId: String)
        case planAllowFile(path: String)                    // plan mode: allow write to plan file
    }

    /// Read-only tools that are always auto-approved.
    static let readOnlyTools: Set<String> = [
        "Read", "Glob", "Grep",
        "Task", "TodoRead",
        "TaskCreate", "TaskUpdate", "TaskList", "TaskGet",
        "EnterPlanMode", "NotebookRead"
    ]

    /// Edit tools that acceptEdits mode auto-approves.
    static let editTools: Set<String> = [
        "Write", "Edit", "NotebookEdit", "MultiEdit"
    ]

    /// Unsafe tools that plan mode blocks.
    static let unsafeTools: Set<String> = [
        "Write", "Edit", "NotebookEdit", "MultiEdit", "Bash"
    ]

    /// Evaluate a permission request and return a decision.
    ///
    /// This is a pure function with no side effects: no socket I/O, no WWUD
    /// recording, no audit logging. The caller is responsible for acting on
    /// the decision (writing responses, recording WWUD, etc.).
    static func evaluate(
        toolName: String,
        toolInput: [String: String],
        sessionId: String,
        claudePermissionMode: String?,
        agentMode: PermissionSocket.PermissionMode,
        remoteApprovalBypassed: Bool,
        settingsRulesEnabled: Bool,
        projectPath: String?,
        wwudEngine: WWUDEngine?,
        filePath: String?
    ) async -> Decision {

        // 1. Local bypass — hook disabled from menu bar
        if remoteApprovalBypassed {
            return .allow(reason: "Hook bypassed locally")
        }

        // 2. Read-only tools are always auto-approved
        if readOnlyTools.contains(toolName) {
            return .allow(reason: "Read-only tool auto-allowed by AFK agent")
        }

        // 3. Claude Code session in bypassPermissions mode
        if claudePermissionMode == "bypassPermissions" {
            return .allow(reason: "Bypassed via permission_mode")
        }

        // 4. Agent permission mode decisions
        switch agentMode {
        case .autoApprove:
            return .allow(reason: "Auto-approved via AFK permission mode")

        case .acceptEdits where Self.editTools.contains(toolName):
            return .allow(reason: "Edit auto-approved via AFK Accept Edits mode")

        case .plan where Self.unsafeTools.contains(toolName):
            // Allow writes to plan files so Claude can save the plan
            if let fp = filePath, fp.contains("/.claude/plans/") {
                return .planAllowFile(path: fp)
            }
            return .deny(reason: "Denied via AFK Plan Mode (read-only)")

        case .wwud:
            // Evaluate against learned patterns
            if let engine = wwudEngine {
                let wwudToolInput = toolInput
                let wwudResult = await engine.evaluate(
                    toolName: toolName,
                    toolInput: wwudToolInput,
                    projectPath: projectPath ?? "unknown"
                )

                switch wwudResult {
                case .autoAllow(let confidence, let pattern):
                    let decisionId = UUID().uuidString
                    return .wwudAllow(confidence: confidence, pattern: pattern, decisionId: decisionId)

                case .autoDeny(let confidence, let pattern):
                    let decisionId = UUID().uuidString
                    return .wwudDeny(confidence: confidence, pattern: pattern, decisionId: decisionId)

                case .uncertain:
                    break // fall through to settings rules / iOS forwarding
                }
            }

        default:
            break // fall through to settings rules / iOS forwarding
        }

        // 5. Check settings.json allow/deny rules (if enabled)
        if settingsRulesEnabled {
            let settingsToolInput = extractToolInputForSettings(
                toolName: toolName,
                toolInput: toolInput
            )
            let parser = ClaudeSettingsParser(projectPath: projectPath)
            let settingsDecision = parser.decision(for: toolName, toolInput: settingsToolInput)

            switch settingsDecision {
            case .allow:
                return .allow(reason: "Allowed by settings.json rule")
            case .deny:
                return .deny(reason: "Denied by settings.json rule")
            case .ask:
                break // fall through to iOS forwarding
            }
        }

        // 6. No local decision — forward to iOS
        return .askRemote
    }

    // MARK: - Settings Rule Input Extraction

    /// Extract the most relevant tool input string for settings.json rule matching.
    static func extractToolInputForSettings(
        toolName: String,
        toolInput: [String: String]
    ) -> String? {
        switch toolName {
        case "Bash":
            return toolInput["command"]
        case "Write", "Edit", "NotebookEdit", "MultiEdit":
            return toolInput["file_path"] ?? toolInput["notebook_path"]
        case "WebFetch", "WebSearch":
            return toolInput["url"] ?? toolInput["query"]
        default:
            let values = toolInput.values.filter { !$0.isEmpty }
            return values.isEmpty ? nil : values.joined(separator: " ")
        }
    }
}
