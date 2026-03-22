//
//  WWUDEngine.swift
//  AFK-Agent
//
//  Core actor for the WWUD (What Would User Do?) smart permission mode.
//  Manages decision history, pattern-based confidence evaluation, and
//  auto-decision logic. Runs entirely on-device for privacy.
//

import Foundation
import OSLog

actor WWUDEngine {

    /// Minimum number of weighted decisions before auto-deciding.
    let minDecisions: Double

    /// Minimum ratio of dominant action to auto-decide (0.0 to 1.0).
    let confidenceThreshold: Double

    /// Number of recent unanimous decisions required.
    let recentUnanimousCount: Int

    /// In-memory cache of decisions per project path.
    private var cache: [String: [WWUDDecision]] = [:]

    /// Tracking counters for stats.
    private var statsAutoApproved: Int = 0
    private var statsAutoDenied: Int = 0
    private var statsForwarded: Int = 0

    init(
        minDecisions: Double = 5.0,
        confidenceThreshold: Double = 0.8,
        recentUnanimousCount: Int = 3
    ) {
        self.minDecisions = minDecisions
        self.confidenceThreshold = confidenceThreshold
        self.recentUnanimousCount = recentUnanimousCount
    }

    // MARK: - Evaluate

    /// Evaluate a permission request against learned patterns.
    /// Returns .autoAllow, .autoDeny, or .uncertain.
    func evaluate(
        toolName: String,
        toolInput: [String: String],
        projectPath: String
    ) -> WWUDResult {
        let decisions = loadDecisions(for: projectPath)
        let patterns = WWUDPatternMatcher.extractPatterns(
            toolName: toolName,
            toolInput: toolInput,
            projectPath: projectPath
        )

        // Try patterns from most specific (level 1) to least specific.
        // Level 4 (tool-only, no project) is informational only — skip it.
        let decidablePatterns = patterns.dropLast()

        for pattern in decidablePatterns {
            let matching = decisions.filter { WWUDPatternMatcher.matches(decision: $0, pattern: pattern) }
            guard !matching.isEmpty else { continue }

            let result = calculateConfidence(matching: matching, pattern: pattern)
            switch result {
            case .autoAllow, .autoDeny:
                return result
            case .uncertain:
                continue // try less specific pattern
            }
        }

        statsForwarded += 1
        return .uncertain
    }

    // MARK: - Record

    /// Record a permission decision (from user via iOS or from auto-decision).
    func recordDecision(
        toolName: String,
        toolInput: [String: String],
        projectPath: String,
        action: String,
        source: String
    ) {
        let decision = WWUDPatternMatcher.createDecision(
            toolName: toolName,
            toolInput: toolInput,
            projectPath: projectPath,
            action: action,
            source: source,
            weight: source == "override" ? 3.0 : 1.0
        )

        // Update in-memory cache
        var decisions = cache[projectPath] ?? []
        decisions.append(decision)
        cache[projectPath] = decisions

        // Persist to disk off the actor's executor
        let snapshot = decisions
        Task.detached(priority: .utility) {
            WWUDStore.save(decisions: snapshot, projectPath: projectPath)
        }

        AppLogger.wwud.info("Recorded \(source, privacy: .public) decision: \(action, privacy: .public) for \(toolName, privacy: .public) in \(projectPath.suffix(30), privacy: .public)")
    }

    /// Record an override correction for a previous auto-decision.
    /// The override is recorded with 3x weight for rapid retraining.
    func recordOverride(
        decisionId: String,
        correctedAction: String,
        projectPath: String? = nil
    ) {
        guard correctedAction == "allow" || correctedAction == "deny" else {
            AppLogger.wwud.warning("Invalid override action: \(correctedAction, privacy: .public)")
            return
        }
        // Find the original decision in cache first
        for (project, decisions) in cache {
            if let projectPath, project != projectPath { continue }
            if let original = decisions.first(where: { $0.id == decisionId }) {
                applyOverride(original: original, correctedAction: correctedAction)
                return
            }
        }

        // Fall back to disk search (engine may have restarted since the auto-decision)
        if let found = WWUDStore.findDecision(id: decisionId) {
            // Load into cache so future lookups are fast
            _ = loadDecisions(for: found.projectPath)
            applyOverride(original: found.decision, correctedAction: correctedAction)
            return
        }

        AppLogger.wwud.warning("Override failed: decision \(decisionId.prefix(8), privacy: .public) not found in cache or on disk")
    }

    private func applyOverride(original: WWUDDecision, correctedAction: String) {
        recordDecision(
            toolName: original.toolName,
            toolInput: buildToolInput(from: original),
            projectPath: original.projectPath,
            action: correctedAction,
            source: "override"
        )
        AppLogger.wwud.info("Override: \(original.action, privacy: .public) → \(correctedAction, privacy: .public) for \(original.toolName, privacy: .public) (3x weight)")
    }

    // MARK: - Stats

    /// Get current WWUD stats.
    func getStats() -> WWUDStats {
        var allDecisions: [WWUDDecision] = []
        for (_, decisions) in cache {
            allDecisions.append(contentsOf: decisions)
        }

        // Build top patterns
        var patternCounts: [String: (action: String, confidence: Double, count: Int)] = [:]
        let allProjects = Set(allDecisions.map(\.projectPath))

        for project in allProjects {
            let projectDecisions = allDecisions.filter { $0.projectPath == project }
            let tools = Set(projectDecisions.map(\.toolName))

            for tool in tools {
                let toolDecisions = projectDecisions.filter { $0.toolName == tool }
                let pattern = WWUDPattern(
                    toolName: tool,
                    projectPath: project,
                    commandPrefix: nil,
                    fileDirectory: nil,
                    fileExtension: nil,
                    targetDomain: nil
                )
                let now = Date()
                let totalWeight = toolDecisions.reduce(0.0) { $0 + $1.effectiveWeight(relativeTo: now) }
                let allowWeight = toolDecisions.filter { $0.action == "allow" }
                    .reduce(0.0) { $0 + $1.effectiveWeight(relativeTo: now) }
                let dominant = max(allowWeight, totalWeight - allowWeight)
                let ratio = totalWeight > 0 ? dominant / totalWeight : 0
                let dominantAction = allowWeight >= totalWeight - allowWeight ? "allow" : "deny"

                patternCounts[pattern.description] = (
                    action: dominantAction,
                    confidence: ratio,
                    count: toolDecisions.count
                )
            }
        }

        let topPatterns = patternCounts
            .sorted { $0.value.count > $1.value.count }
            .prefix(10)
            .map { WWUDPatternStat(pattern: $0.key, action: $0.value.action, confidence: $0.value.confidence, count: $0.value.count) }

        return WWUDStats(
            totalDecisions: allDecisions.count,
            autoApproved: statsAutoApproved,
            autoDenied: statsAutoDenied,
            forwarded: statsForwarded,
            topPatterns: topPatterns
        )
    }

    /// Prune all expired decisions on startup.
    func pruneExpired() {
        WWUDStore.pruneAll()
    }

    // MARK: - Private

    /// Load decisions for a project, using cache if available.
    private func loadDecisions(for projectPath: String) -> [WWUDDecision] {
        if let cached = cache[projectPath] {
            return cached
        }
        let decisions = WWUDStore.load(projectPath: projectPath)
        cache[projectPath] = decisions
        return decisions
    }

    /// Calculate confidence for a set of matching decisions.
    private func calculateConfidence(matching: [WWUDDecision], pattern: WWUDPattern) -> WWUDResult {
        let now = Date()

        // Calculate weighted totals
        let totalWeight = matching.reduce(0.0) { $0 + $1.effectiveWeight(relativeTo: now) }
        guard totalWeight >= minDecisions else { return .uncertain }

        let allowWeight = matching.filter { $0.action == "allow" }
            .reduce(0.0) { $0 + $1.effectiveWeight(relativeTo: now) }
        let denyWeight = totalWeight - allowWeight

        let dominant = max(allowWeight, denyWeight)
        let ratio = dominant / totalWeight
        guard ratio >= confidenceThreshold else { return .uncertain }

        // Check that last N user decisions are unanimous
        let recentUserDecisions = matching
            .filter { $0.source == "user" || $0.source == "override" }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(recentUnanimousCount)

        guard recentUserDecisions.count >= recentUnanimousCount else { return .uncertain }

        let unanimousAction = recentUserDecisions.first!.action
        guard recentUserDecisions.allSatisfy({ $0.action == unanimousAction }) else {
            return .uncertain
        }

        // Ensure the unanimous action matches the dominant action
        let dominantAction = allowWeight >= denyWeight ? "allow" : "deny"
        guard unanimousAction == dominantAction else { return .uncertain }

        if dominantAction == "allow" {
            statsAutoApproved += 1
            return .autoAllow(confidence: ratio, pattern: pattern)
        } else {
            statsAutoDenied += 1
            return .autoDeny(confidence: ratio, pattern: pattern)
        }
    }

    /// Reconstruct a minimal toolInput dictionary from a stored decision.
    private func buildToolInput(from decision: WWUDDecision) -> [String: String] {
        var input: [String: String] = [:]
        if let cp = decision.commandPrefix {
            input["command"] = cp
        }
        if let fp = decision.filePath {
            input["file_path"] = fp
        }
        return input
    }
}
