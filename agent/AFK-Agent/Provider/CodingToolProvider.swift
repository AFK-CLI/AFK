//
//  CodingToolProvider.swift
//  AFK-Agent
//

import Foundation

// MARK: - Provider Protocol

/// A coding tool provider handles session discovery, event normalization,
/// and command execution for a specific AI coding tool (e.g., Claude Code, OpenCode).
protocol CodingToolProvider: Actor {
    /// Unique identifier: "claude_code", "opencode", "codex"
    nonisolated var identifier: String { get }

    /// Human-readable name for UI display
    nonisolated var displayName: String { get }

    /// What this provider supports
    nonisolated var capabilities: ProviderCapabilities { get }

    /// Tool display hint provider for rendering tool calls
    nonisolated var toolDisplayProvider: ToolProvider { get }

    /// Start watching for session changes.
    /// The callback receives a batch of normalized events for a single session.
    func startWatching(
        onChange: @escaping @Sendable (ProviderSessionBatch) async -> Void
    ) async

    /// Begin actively watching after setup is complete.
    /// Called after startWatching + discoverExistingSessions + state reconciliation.
    func beginWatching() async

    /// Stop watching for changes.
    func stopWatching() async

    /// Discover existing sessions on startup.
    /// Returns session metadata for state reconciliation.
    func discoverExistingSessions() async -> [DiscoveredSession]

    /// Fast-forward past existing data so we don't replay history.
    func fastForward(session: DiscoveredSession) async

    /// Resume from a saved byte offset (restart recovery).
    func resume(session: DiscoveredSession, offset: UInt64) async

    /// Get current read offset for state persistence (JSONL byte offset, SQLite rowid, etc.)
    func currentOffset(for sessionPath: String) async -> UInt64

    /// Check for tool permission stalls across active sessions.
    func checkPermissionStalls(stallTimeout: TimeInterval, activeSessions: Set<String>) -> [NormalizedEvent]

    /// Set content encryptor for E2EE mode.
    func setContentEncryptor(_ encryptor: (@Sendable ([String: String], String) -> [String: String]?)?)

    /// Resolve the CLI binary path for this coding tool.
    func resolveBinaryPath() throws -> String

    /// Build arguments for continuing/resuming an existing session.
    func buildContinueArgs(binaryPath: String, sessionId: String, prompt: String) throws -> [String]

    /// Build arguments for starting a new chat session.
    func buildNewChatArgs(binaryPath: String, prompt: String, options: NewChatOptions) throws -> [String]

    /// Validate command arguments before execution.
    func validateArgs(_ args: [String]) throws

    /// Parse CLI JSON output into a structured result.
    func parseCommandOutput(_ data: Data) -> CommandOutput?

    /// Find the data file (JSONL, SQLite DB) for a given session ID.
    func findSessionFile(sessionId: String) async -> String?

    /// Handle a permission/question response from iOS.
    /// OpenCode uses this to POST the reply to its HTTP API.
    /// Default: no-op (Claude Code uses the hook socket instead).
    func handlePermissionResponse(nonce: String, action: String, message: String?) async
}

extension CodingToolProvider {
    func handlePermissionResponse(nonce: String, action: String, message: String?) async {
        // Default no-op. Claude Code uses the hook socket for permission responses.
    }
}

// MARK: - Supporting Types

struct ProviderCapabilities: OptionSet, Sendable {
    let rawValue: Int

    static let resumeSession   = ProviderCapabilities(rawValue: 1 << 0)
    static let newChat         = ProviderCapabilities(rawValue: 1 << 1)
    static let streamingOutput = ProviderCapabilities(rawValue: 1 << 2)
    static let permissionHook  = ProviderCapabilities(rawValue: 1 << 3)
    static let usageTracking   = ProviderCapabilities(rawValue: 1 << 4)
    static let worktreeSupport = ProviderCapabilities(rawValue: 1 << 5)
}

/// A batch of normalized events from a single session change.
struct ProviderSessionBatch: Sendable {
    let sessionId: String
    let projectPath: String
    let provider: String
    let dataPath: String        // JSONL file path, SQLite DB path, etc.
    let events: [ProviderEvent]
    let rawUserPrompt: String?
}

/// A normalized event with per-entry metadata.
struct ProviderEvent: Sendable {
    let event: NormalizedEvent
    let cwd: String
    let gitBranch: String
    let privacyMode: String
}

/// A session discovered during startup scanning.
struct DiscoveredSession: Sendable {
    let sessionId: String
    let projectPath: String
    let dataPath: String   // JSONL file path, SQLite DB path, etc.
    let provider: String
}

/// Options for starting a new chat.
struct NewChatOptions: Sendable {
    let useWorktree: Bool
    let worktreeName: String?
    let permissionMode: String?
}

/// Parsed output from a CLI process.
struct CommandOutput: Sendable {
    let sessionId: String?
    let durationMs: Int?
    let costUsd: Double?
    let resultText: String?
    let isError: Bool
}
