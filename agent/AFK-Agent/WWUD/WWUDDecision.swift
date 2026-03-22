//
//  WWUDDecision.swift
//  AFK-Agent
//
//  Data model for WWUD (What Would User Do?) permission decisions.
//  Each decision records the context of a permission request and the
//  user's (or auto) response, enabling pattern-based learning.
//

import Foundation

/// A single recorded permission decision with rich context for pattern matching.
struct WWUDDecision: Codable, Sendable, Identifiable {
    let id: String
    let timestamp: Date
    let toolName: String
    let projectPath: String

    // Tool-specific context for pattern matching
    let commandPrefix: String?   // Bash: first 2 tokens ("npm test", "git push")
    let filePath: String?        // Write/Edit: path relative to project root
    let fileExtension: String?   // .swift, .ts, etc.
    let fileDirectory: String?   // parent dir relative to project root
    let targetDomain: String?    // WebFetch/WebSearch: hostname

    let inputSummary: String     // truncated raw tool input (max 500 chars)
    let action: String           // "allow" or "deny"
    let source: String           // "user" (from iOS), "override" (corrected), "auto" (WWUD decided)
    let weight: Double           // 1.0 normal, 3.0 for overrides

    /// Age-adjusted weight: half weight after 30 days, zero after 90 days.
    func effectiveWeight(relativeTo now: Date = Date()) -> Double {
        let age = now.timeIntervalSince(timestamp)
        let thirtyDays: TimeInterval = 30 * 24 * 3600
        let ninetyDays: TimeInterval = 90 * 24 * 3600
        if age > ninetyDays { return 0 }
        if age > thirtyDays { return weight * 0.5 }
        return weight
    }

    /// Whether this decision has expired (older than 90 days).
    func isExpired(relativeTo now: Date = Date()) -> Bool {
        now.timeIntervalSince(timestamp) > 90 * 24 * 3600
    }
}

/// A pattern used to match against incoming permission requests.
/// Patterns are compared at multiple specificity levels.
struct WWUDPattern: Codable, Sendable, Hashable {
    let toolName: String
    let projectPath: String?
    let commandPrefix: String?
    let fileDirectory: String?
    let fileExtension: String?
    let targetDomain: String?

    /// Human-readable description of what this pattern matches.
    var description: String {
        var parts = [toolName]
        if let cp = commandPrefix { parts.append("'\(cp) *'") }
        if let fd = fileDirectory, let fe = fileExtension {
            parts.append("'\(fd)/**/*\(fe)'")
        } else if let fe = fileExtension {
            parts.append("'**/*\(fe)'")
        }
        if let td = targetDomain { parts.append("@\(td)") }
        if let pp = projectPath {
            let name = (pp as NSString).lastPathComponent
            parts.append("in \(name)")
        }
        return parts.joined(separator: " ")
    }
}

/// The result of evaluating a permission request against learned patterns.
enum WWUDResult: Sendable {
    case autoAllow(confidence: Double, pattern: WWUDPattern)
    case autoDeny(confidence: Double, pattern: WWUDPattern)
    case uncertain
}

/// Auto-decision event sent to iOS for the transparency feed.
struct WWUDAutoDecisionEvent: Codable, Sendable {
    let sessionId: String
    let toolName: String
    let toolInputPreview: String
    let action: String
    let confidence: Double
    let patternDescription: String
    let timestamp: Int64
    let decisionId: String
}

/// Aggregate stats for the WWUD engine, sent to iOS.
struct WWUDStats: Codable, Sendable {
    let totalDecisions: Int
    let autoApproved: Int
    let autoDenied: Int
    let forwarded: Int
    let topPatterns: [WWUDPatternStat]
}

/// A single pattern stat entry for the stats payload.
struct WWUDPatternStat: Codable, Sendable {
    let pattern: String
    let action: String
    let confidence: Double
    let count: Int
}
