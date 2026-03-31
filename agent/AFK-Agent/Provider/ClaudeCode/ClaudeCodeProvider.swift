//
//  ClaudeCodeProvider.swift
//  AFK-Agent
//

import Foundation
import OSLog

/// Provider for Claude Code sessions.
/// Watches ~/.claude/projects/ for JSONL files and normalizes events.
actor ClaudeCodeProvider: CodingToolProvider {
    nonisolated let identifier = "claude_code"
    nonisolated let displayName = "Claude Code"

    nonisolated let capabilities: ProviderCapabilities = [
        .resumeSession, .newChat, .streamingOutput, .permissionHook,
        .usageTracking, .worktreeSupport
    ]

    nonisolated let toolDisplayProvider: ToolProvider = ClaudeCodeToolProvider()

    private let config: AgentConfig
    private let parser = JSONLParser()
    private var normalizer: EventNormalizer
    private var watcher: SessionWatcher?
    private var sessionPaths: [String: String] = [:]  // sessionId -> projectPath

    init(config: AgentConfig) {
        self.config = config
        self.normalizer = EventNormalizer(toolProvider: ClaudeCodeToolProvider())
    }

    // MARK: - Watching

    func startWatching(
        onChange: @escaping @Sendable (ProviderSessionBatch) async -> Void
    ) async {
        let projectsPath = config.claudeProjectsPath

        let watcher = SessionWatcher(projectsPath: projectsPath) { [weak self] filePath in
            guard let self else { return }
            await self.handleFileChange(filePath, onChange: onChange)
        }
        self.watcher = watcher
    }

    /// Called after startWatching to actually begin FSEvents monitoring.
    /// Must be called separately because seedExistingSessions and state reconciliation
    /// happen between startWatching and starting the watcher.
    func beginWatching() async {
        await watcher?.start()
    }

    func stopWatching() async {
        await watcher?.stop()
        watcher = nil
    }

    // MARK: - Session Discovery

    func discoverExistingSessions() async -> [DiscoveredSession] {
        guard let watcher else { return [] }
        let files = await watcher.seedExistingFiles()
        return files.map { filePath in
            let (sessionId, projectPath) = resolveSessionInfo(filePath: filePath)
            return DiscoveredSession(
                sessionId: sessionId,
                projectPath: projectPath,
                dataPath: filePath,
                provider: identifier
            )
        }
    }

    func fastForward(session: DiscoveredSession) async {
        await parser.fastForwardToEnd(session.dataPath)
    }

    func resume(session: DiscoveredSession, offset: UInt64) async {
        await parser.setOffset(for: session.dataPath, to: offset)
    }

    func currentOffset(for sessionPath: String) async -> UInt64 {
        await parser.currentOffset(for: sessionPath)
    }

    // MARK: - Permission Stalls

    func checkPermissionStalls(stallTimeout: TimeInterval, activeSessions: Set<String>) -> [NormalizedEvent] {
        normalizer.checkPermissionStalls(stallTimeout: stallTimeout, activeSessions: activeSessions)
    }

    // MARK: - E2EE

    func setContentEncryptor(_ encryptor: (@Sendable ([String: String], String) -> [String: String]?)?) {
        normalizer.contentEncryptor = encryptor
    }

    // MARK: - Commands

    func resolveBinaryPath() throws -> String {
        try CommandValidator.resolveClaudePath()
    }

    func buildContinueArgs(binaryPath: String, sessionId: String, prompt: String) throws -> [String] {
        let args = [binaryPath, "--resume", sessionId, "-p", prompt, "--output-format", "json"]
        try CommandValidator.validate(args: args)
        return args
    }

    func buildNewChatArgs(binaryPath: String, prompt: String, options: NewChatOptions) throws -> [String] {
        var args = [binaryPath, "-p", prompt, "--output-format", "json"]
        if let mode = options.permissionMode, !mode.isEmpty, mode != "default" {
            args.append(contentsOf: ["--permission-mode", mode])
        }
        if options.useWorktree {
            if let name = options.worktreeName, !name.isEmpty {
                args.append(contentsOf: ["-w", name])
            } else {
                args.append("--worktree")
            }
        }
        try CommandValidator.validate(args: args)
        return args
    }

    func validateArgs(_ args: [String]) throws {
        try CommandValidator.validate(args: args)
    }

    func parseCommandOutput(_ data: Data) -> CommandOutput? {
        struct ClaudeJSONResult: Codable {
            let session_id: String?
            let cost_usd: Double?
            let duration_ms: Int?
            let result: String?
            let is_error: Bool?
        }
        guard let result = try? JSONDecoder().decode(ClaudeJSONResult.self, from: data) else {
            return nil
        }
        return CommandOutput(
            sessionId: result.session_id,
            durationMs: result.duration_ms,
            costUsd: result.cost_usd,
            resultText: result.result,
            isError: result.is_error ?? false
        )
    }

    func findSessionFile(sessionId: String) async -> String? {
        Agent.findJSONLFile(sessionId: sessionId, under: config.claudeProjectsPath)
    }

    // MARK: - Internal

    private func handleFileChange(
        _ filePath: String,
        onChange: @escaping @Sendable (ProviderSessionBatch) async -> Void
    ) async {
        guard filePath.hasSuffix(".jsonl") else { return }

        let (sessionId, projectPath) = resolveSessionInfo(filePath: filePath)

        do {
            let entries = try await parser.parseNewEntries(at: filePath)
            guard !entries.isEmpty else { return }

            var allEvents: [ProviderEvent] = []
            var rawUserPrompt: String?

            for entry in entries {
                if entry.isSidechain == true { continue }

                let entryCwd = entry.cwd ?? ""
                let entryBranch = entry.gitBranch ?? ""
                let privacyMode = config.privacyMode(for: projectPath)

                // Extract raw user prompt BEFORE normalization (which may encrypt)
                if entry.type == "user" && entry.userType == "external",
                   let msgContent = entry.message?.content {
                    let prompt = msgContent.textContent
                    if !prompt.isEmpty {
                        rawUserPrompt = prompt
                    }
                }

                let events = normalizer.normalize(
                    entry: entry,
                    sessionId: sessionId,
                    projectPath: projectPath,
                    privacyMode: privacyMode
                )

                for event in events {
                    allEvents.append(ProviderEvent(
                        event: event,
                        cwd: entryCwd,
                        gitBranch: entryBranch,
                        privacyMode: privacyMode
                    ))
                }
            }

            if !allEvents.isEmpty {
                let batch = ProviderSessionBatch(
                    sessionId: sessionId,
                    projectPath: projectPath,
                    provider: identifier,
                    dataPath: filePath,
                    events: allEvents,
                    rawUserPrompt: rawUserPrompt
                )
                await onChange(batch)
            }
        } catch {
            AppLogger.agent.error("Error parsing \(filePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Decode session ID and project path from a JSONL file path.
    private func resolveSessionInfo(filePath: String) -> (sessionId: String, projectPath: String) {
        let url = URL(fileURLWithPath: filePath)
        let sessionId = url.deletingPathExtension().lastPathComponent
        let encodedDir = url.deletingLastPathComponent().lastPathComponent
        let projectPath = SessionIndex.decodeProjectPath(encodedDir)

        sessionPaths[sessionId] = projectPath

        return (sessionId, projectPath)
    }
}
