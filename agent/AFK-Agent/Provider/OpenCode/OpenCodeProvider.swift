//
//  OpenCodeProvider.swift
//  AFK-Agent
//

import Foundation
import OSLog
import SQLite3

/// Provider for OpenCode sessions.
/// Watches the centralized SQLite database at ~/.local/share/opencode/opencode.db.
actor OpenCodeProvider: CodingToolProvider {
    nonisolated let identifier = "opencode"
    nonisolated let displayName = "OpenCode"

    nonisolated let capabilities: ProviderCapabilities = [.resumeSession, .newChat]

    nonisolated let toolDisplayProvider: ToolProvider = OpenCodeToolProvider()

    private let config: AgentConfig
    private var watcher: OpenCodeSQLiteWatcher?
    private var apiClient: OpenCodeAPIClient?
    private var serveProcess: Process?
    private var normalizer: OpenCodeNormalizer

    struct PendingRequest: Sendable {
        let requestId: String
        let directory: String
    }

    /// Maps AFK nonce -> OpenCode request ID + directory for permission/question round-trips.
    private var pendingPermissions: [String: PendingRequest] = [:]
    private var pendingQuestions: [String: PendingRequest] = [:]

    /// Callback for forwarding permission/question events to the Agent.
    var onPermissionEvent: (@Sendable (OpenCodeAPIClient.PermissionEvent) async -> Void)?
    var onQuestionEvent: (@Sendable (OpenCodeAPIClient.QuestionEvent) async -> Void)?

    private let serverPort: Int

    init(config: AgentConfig) {
        self.config = config
        self.normalizer = OpenCodeNormalizer(toolProvider: OpenCodeToolProvider())
        self.serverPort = config.openCodeServerPort > 0 ? config.openCodeServerPort : 4096
    }

    /// Whether the SSE API client is connected to opencode serve.
    var isAPIConnected: Bool {
        get async { await apiClient?.isConnected ?? false }
    }

    func setPermissionCallback(_ callback: @escaping @Sendable (OpenCodeAPIClient.PermissionEvent) async -> Void) {
        self.onPermissionEvent = callback
    }

    func setQuestionCallback(_ callback: @escaping @Sendable (OpenCodeAPIClient.QuestionEvent) async -> Void) {
        self.onQuestionEvent = callback
    }

    // MARK: - Watching

    func startWatching(
        onChange: @escaping @Sendable (ProviderSessionBatch) async -> Void
    ) async {
        // SQLite watcher for content events (transcript sync, tool cards)
        let watcher = OpenCodeSQLiteWatcher(
            pollInterval: config.openCodePollInterval
        ) { [weak self] parts in
            guard let self else { return }
            await self.handleNewParts(parts: parts, onChange: onChange)
        }
        self.watcher = watcher

        // HTTP API client for permission/question events.
        // Connects to OpenCode's HTTP server when available.
        // User runs: opencode --port 4096 (TUI starts its own server)
        // or: opencode serve --port 4096 (headless server)
        let homeDir = NSHomeDirectory()
        let client = OpenCodeAPIClient(port: serverPort, directory: homeDir)

        await client.setCallbacks(
            onPermission: { [weak self] event in
                guard let self else { return }
                await self.onPermissionEvent?(event)
            },
            onQuestion: { [weak self] event in
                guard let self else { return }
                await self.onQuestionEvent?(event)
            }
        )

        self.apiClient = client
        AppLogger.agent.info("OpenCode: API client configured on port \(self.serverPort, privacy: .public)")
    }

    func beginWatching() async {
        await watcher?.start()
        await apiClient?.connect()
    }

    func stopWatching() async {
        await watcher?.stop()
        watcher = nil
        await apiClient?.disconnect()
        apiClient = nil
    }

    // MARK: - Serve Process Management

    /// Launch `opencode serve` as a sidecar process for the HTTP API.
    private func launchServeProcess() async {
        // Check if server is already running (from a previous launch or user-started)
        if await OpenCodeAPIClient.detectPort() != nil {
            AppLogger.agent.info("OpenCode: server already running on port \(self.serverPort, privacy: .public)")
            return
        }

        do {
            let binaryPath = try resolveBinaryPath()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.arguments = ["serve", "--port", "\(serverPort)", "--hostname", "127.0.0.1"]
            // Use a known project directory so serve picks up project-level opencode.json
            // (permission config). Falls back to home if no sessions found.
            let projectDir = await discoverFirstProjectDirectory() ?? NSHomeDirectory()
            process.currentDirectoryURL = URL(fileURLWithPath: projectDir)
            AppLogger.agent.info("OpenCode: serve cwd = \(projectDir, privacy: .public)")
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            try process.run()
            self.serveProcess = process
            AppLogger.agent.info("OpenCode: launched serve process (pid \(process.processIdentifier, privacy: .public)) on port \(self.serverPort, privacy: .public)")

            // Wait for server to be ready
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                if await OpenCodeAPIClient.detectPort() != nil {
                    AppLogger.agent.info("OpenCode: serve process ready")
                    return
                }
            }
            AppLogger.agent.warning("OpenCode: serve process started but health check not responding after 10s")
        } catch {
            AppLogger.agent.error("OpenCode: failed to launch serve process: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Find the first project directory from the OpenCode SQLite DB.
    private func discoverFirstProjectDirectory() async -> String? {
        guard let watcher else { return nil }
        let sessions = await watcher.discoverExistingSessions()
        return sessions.first?.projectPath
    }

    private func stopServeProcess() {
        guard let process = serveProcess, process.isRunning else { return }
        process.terminate()
        AppLogger.agent.info("OpenCode: terminated serve process")
        serveProcess = nil
    }

    // MARK: - Permission/Question Response Handling

    /// Track a permission nonce -> OpenCode request ID + directory mapping.
    func trackPermission(nonce: String, requestId: String, directory: String) {
        pendingPermissions[nonce] = PendingRequest(requestId: requestId, directory: directory)
    }

    /// Track a question nonce -> OpenCode request ID + directory mapping.
    func trackQuestion(nonce: String, requestId: String, directory: String) {
        pendingQuestions[nonce] = PendingRequest(requestId: requestId, directory: directory)
    }

    func handlePermissionResponse(nonce: String, action: String, message: String?) async {
        guard let apiClient else { return }

        // Check permissions first
        if let pending = pendingPermissions.removeValue(forKey: nonce) {
            let reply: String
            switch action {
            case "allow": reply = "once"
            case "deny": reply = "reject"
            default: reply = "reject"
            }
            do {
                try await apiClient.replyPermission(requestId: pending.requestId, reply: reply, message: message, directory: pending.directory)
            } catch {
                AppLogger.agent.error("OpenCode: permission reply failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        // Check questions
        if let pending = pendingQuestions.removeValue(forKey: nonce) {
            do {
                if action.hasPrefix("answer:") {
                    // User selected an option from the QuestionOverlay
                    let selectedLabel = String(action.dropFirst("answer:".count))
                    AppLogger.agent.info("OpenCode: question answered with '\(selectedLabel, privacy: .public)'")
                    try await apiClient.replyQuestion(requestId: pending.requestId, answers: [[selectedLabel]], directory: pending.directory)
                } else if action == "deny" {
                    try await apiClient.rejectQuestion(requestId: pending.requestId, directory: pending.directory)
                } else {
                    // Fallback: reject
                    try await apiClient.rejectQuestion(requestId: pending.requestId, directory: pending.directory)
                }
            } catch {
                AppLogger.agent.error("OpenCode: question reply failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Session Discovery

    func discoverExistingSessions() async -> [DiscoveredSession] {
        guard let watcher else { return [] }
        let dbPath = await watcher.databasePath
        return await watcher.discoverExistingSessions().map { (sessionId, projectPath) in
            DiscoveredSession(
                sessionId: sessionId,
                projectPath: projectPath,
                dataPath: dbPath,
                provider: identifier
            )
        }
    }

    /// Mark sessions as already known to avoid duplicate session_started events.
    func markSessionsSeen(_ sessionIds: [String]) {
        normalizer.markSessionsSeen(sessionIds)
    }

    func fastForward(session: DiscoveredSession) async {
        await watcher?.fastForward()
    }

    func resume(session: DiscoveredSession, offset: UInt64) async {
        // OpenCode uses a single global DB — only advance the offset, never go backwards.
        // Multiple sessions may resume with different saved offsets; we want the max.
        let current = await watcher?.currentOffset() ?? 0
        let newOffset = Int64(offset)
        if newOffset > current {
            await watcher?.setOffset(newOffset)
        }
    }

    func currentOffset(for sessionPath: String) async -> UInt64 {
        UInt64(await watcher?.currentOffset() ?? 0)
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
        let knownPaths = [
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
            NSHomeDirectory() + "/.local/bin/opencode",
            NSHomeDirectory() + "/go/bin/opencode",
        ]
        for path in knownPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fallback: which
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["opencode"]
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" +
                    NSHomeDirectory() + "/go/bin:" +
                    NSHomeDirectory() + "/.local/bin:" +
                    (ProcessInfo.processInfo.environment["PATH"] ?? "")
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw OpenCodeError.binaryNotFound
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { throw OpenCodeError.binaryNotFound }

        // Validate the resolved path against allowed prefixes
        try validateArgs([path])
        return path
    }

    func buildContinueArgs(binaryPath: String, sessionId: String, prompt: String) throws -> [String] {
        // opencode run -s <sessionId> --format json <message>
        let args = [binaryPath, "run", "-s", sessionId, "--format", "json", prompt]
        try validateArgs(args)
        return args
    }

    func buildNewChatArgs(binaryPath: String, prompt: String, options: NewChatOptions) throws -> [String] {
        // opencode run --format json [--agent <agent>] <message>
        var args = [binaryPath, "run", "--format", "json"]
        if let mode = options.permissionMode, !mode.isEmpty, mode != "default" {
            args.append(contentsOf: ["--agent", mode])
        }
        args.append(prompt)
        try validateArgs(args)
        return args
    }

    func validateArgs(_ args: [String]) throws {
        guard !args.isEmpty else { throw OpenCodeError.invalidArgs }
        let binary = args[0]
        let home = NSHomeDirectory()
        let allowedPrefixes = ["/usr/local/", "/opt/homebrew/", "/usr/bin/", home + "/go/", home + "/.local/"]
        guard allowedPrefixes.contains(where: { binary.hasPrefix($0) }) else {
            throw OpenCodeError.invalidBinary(binary)
        }
    }

    func parseCommandOutput(_ data: Data) -> CommandOutput? {
        struct OpenCodeResult: Codable {
            let session_id: String?
            let cost: Double?
            let duration_ms: Int?
            let result: String?
            let is_error: Bool?
        }
        guard let result = try? JSONDecoder().decode(OpenCodeResult.self, from: data) else {
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                return CommandOutput(sessionId: nil, durationMs: nil, costUsd: nil, resultText: text, isError: false)
            }
            return nil
        }
        return CommandOutput(
            sessionId: result.session_id,
            durationMs: result.duration_ms,
            costUsd: result.cost,
            resultText: result.result,
            isError: result.is_error ?? false
        )
    }

    func findSessionFile(sessionId: String) async -> String? {
        guard let watcher else { return nil }
        let exists = await watcher.sessionExists(sessionId: sessionId)
        return exists ? await watcher.databasePath : nil
    }

    // MARK: - Internal

    private func handleNewParts(
        parts: [OpenCodePart],
        onChange: @escaping @Sendable (ProviderSessionBatch) async -> Void
    ) async {
        // Group parts by session
        var bySession: [String: [OpenCodePart]] = [:]
        for part in parts {
            bySession[part.sessionId, default: []].append(part)
        }

        for (sessionId, sessionParts) in bySession {
            let projectPath = sessionParts.first?.projectPath ?? ""
            let privacyMode = config.privacyMode(for: projectPath)
            let dbPath = await watcher?.databasePath ?? ""

            var allEvents: [ProviderEvent] = []
            var rawUserPrompt: String?

            for part in sessionParts {
                let events = normalizer.normalize(part: part, privacyMode: privacyMode)

                // Extract user prompt
                if part.role == "user", case .text(let text) = part.content, !text.isEmpty {
                    rawUserPrompt = text
                }

                for event in events {
                    allEvents.append(ProviderEvent(
                        event: event,
                        cwd: projectPath,
                        gitBranch: "",
                        privacyMode: privacyMode
                    ))
                }
            }

            if !allEvents.isEmpty {
                let batch = ProviderSessionBatch(
                    sessionId: sessionId,
                    projectPath: projectPath,
                    provider: identifier,
                    dataPath: dbPath,
                    events: allEvents,
                    rawUserPrompt: rawUserPrompt
                )
                await onChange(batch)
            }
        }
    }

    // MARK: - Errors

    enum OpenCodeError: Error, CustomStringConvertible {
        case binaryNotFound
        case resumeNotSupported
        case invalidArgs
        case invalidBinary(String)

        var description: String {
            switch self {
            case .binaryNotFound: return "opencode binary not found"
            case .resumeNotSupported: return "OpenCode does not support resuming sessions"
            case .invalidArgs: return "Invalid arguments"
            case .invalidBinary(let b): return "Invalid binary: \(b)"
            }
        }
    }
}
