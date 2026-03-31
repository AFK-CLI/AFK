//
//  Agent.swift
//  AFK-Agent
//

import Foundation
import CryptoKit
import OSLog
import UserNotifications

actor Agent {
    var config: AgentConfig
    let sessionIndex = SessionIndex()
    let stateManager = SessionStateManager()
    var providerRegistry: ProviderRegistry?
    var sessionProviders: [String: String] = [:]  // sessionId -> provider identifier
    var wsClient: WebSocketClient?
    var permissionSocket: PermissionSocket?
    var wwudEngine: WWUDEngine?
    var otlpReceiver: OTLPReceiver?
    var commandExecutor: CommandExecutor?
    var commandVerifier: CommandVerifier?
    var commandNonceStore = NonceStore()
    var enrolledDeviceId: String?
    var ephemeralKeys: [String: Curve25519.KeyAgreement.PrivateKey] = [:]
    var sessionKeyCache: SessionKeyCache?
    var agentState = AgentState()
    /// Maps AFK nonce -> (provider identifier, OpenCode request ID) for permission round-trips
    var pendingProviderPermissions: [String: (provider: String, requestId: String)] = [:]
    var diskQueue: DiskQueue?
    var todoWatcher: TodoWatcher?
    var usageService: ClaudeUsageService?
    var inventoryScanner: InventoryScanner?
    var sharedSkillInstaller: SharedSkillInstaller?
    var signInController: SignInWindowController?
    nonisolated(unsafe) var onAccountChanged: ((String?) -> Void)?
    let statusBarController: StatusBarController?
    let logCollector = LogCollector()

    init(config: AgentConfig, statusBarController: StatusBarController? = nil) {
        self.config = config
        self.statusBarController = statusBarController
    }

    func updateConfig(_ newConfig: AgentConfig) {
        self.config = newConfig
    }

    func run() async {
        AppLogger.agent.info("Starting AFK Agent...")
        AppLogger.agent.info("Providers: \(self.config.enabledProviders.joined(separator: ", "), privacy: .public)")

        // Initialize provider registry
        let registry = ProviderRegistry(config: config)
        self.providerRegistry = registry

        // Initialize disk-backed offline queue
        let queueDir = URL(fileURLWithPath: BuildEnvironment.configDirectoryPath)
            .appendingPathComponent("offline-queue")
        let queue = DiskQueue(directory: queueDir)
        self.diskQueue = queue
        if queue.count > 0 {
            AppLogger.agent.info("Disk queue recovered \(queue.count, privacy: .public) pending messages")
        }

        // Register for sleep/wake notifications (reconnect resilience)
        registerSleepWakeObservers()

        // Register for app termination (graceful shutdown on logout/restart)
        registerTerminationObserver()

        let keychain = KeychainStore()

        // Resolve auth token + device ID
        var token = config.authToken ?? (try? keychain.loadToken(forKey: "auth-token"))
        var deviceId = config.deviceID ?? (try? keychain.loadToken(forKey: "device-id"))

        // Restore account display from keychain
        if token != nil, let savedEmail = try? keychain.loadToken(forKey: "user-email") {
            onAccountChanged?(savedEmail)
        }

        // Show sign-in window if no token
        if token == nil {
            AppLogger.agent.info("No token found. Showing sign-in window...")
            let result = await showSignInWindow()
            if let result {
                token = result.token
                deviceId = result.deviceId
            }
        }

        // Setup WebSocket if we have auth + device ID
        if var token = token, var deviceId = deviceId {
            var connected = await setupWebSocket(token: token, deviceId: deviceId, keychain: keychain)

            // If connection failed, try refreshing the token first, then re-enroll as last resort.
            if !connected {
                // Step 1: Try refreshing the access token
                if let newToken = await tryRefreshToken(keychain: keychain) {
                    AppLogger.agent.info("Retrying connection with refreshed token...")
                    token = newToken
                    connected = await setupWebSocket(token: token, deviceId: deviceId, keychain: keychain)
                }

                // Step 2: If refresh didn't work, re-enroll
                if !connected {
                    let savedDeviceId = deviceId
                    try? keychain.deleteToken(forKey: "auth-token")
                    try? keychain.deleteToken(forKey: "refresh-token")
                    AppLogger.agent.warning("Refresh failed — showing sign-in window...")
                    if let result = await showSignInWindow(existingDeviceId: savedDeviceId) {
                        token = result.token
                        deviceId = result.deviceId
                        connected = await setupWebSocket(token: token, deviceId: deviceId, keychain: keychain)
                    }
                }
            }

            if connected {
                AppLogger.agent.info("WebSocket ready — starting file watcher")
            } else {
                AppLogger.agent.warning("WebSocket failed — events will be local only until reconnect")
            }

            self.enrolledDeviceId = deviceId

            // Configure log collector for remote log upload
            let logApiClient = APIClient(baseURL: config.httpBaseURL, token: token)
            await logCollector.configure(apiClient: logApiClient, deviceId: deviceId)

            if let client = wsClient {
                // Broadcast initial control state to iOS
                await broadcastControlState()

                // Start inventory scanner and shared skill installer
                let scanner = InventoryScanner()
                self.inventoryScanner = scanner
                let installer = SharedSkillInstaller()
                self.sharedSkillInstaller = installer

                // Shared files persist across restarts — no cleanup on startup

                // Perform initial inventory scan
                await performInventoryScan(deviceId: deviceId)

                // Start heartbeat loop
                Task { [weak self] in
                    guard let self else { return }
                    await self.heartbeatLoop(deviceId: deviceId)
                }

                // Start usage polling loop
                let usageSvc = ClaudeUsageService()
                self.usageService = usageSvc
                Task { [weak self] in
                    guard let self else { return }
                    await self.usagePollingLoop(deviceId: deviceId, service: usageSvc)
                }

                // Start permission socket if remote approval is enabled
                if config.remoteApprovalEnabled {
                    await setupPermissionSocket(deviceId: deviceId, client: client)
                }

                // Wire E2EE content encryption into the normalizer
                await setupE2EEEncryptor(deviceId: deviceId)

                // Start OTLP telemetry receiver for cost/token tracking
                await setupOTLPReceiver()

                // Refresh peer keys on every WS reconnect to pick up rotated keys
                await client.onReconnect { [weak self] in
                    guard let self else { return }
                    AppLogger.agent.info("WS reconnected — refreshing E2EE peer keys")
                    await self.setupE2EEEncryptor(deviceId: deviceId)
                    // Also refresh permission signing keys for HMAC verification
                    if let socket = await self.permissionSocket {
                        await self.setupPermissionSigningKeys(socket: socket, deviceId: deviceId)
                    }
                }

                // Always set up command executor so remote continue works.
                self.commandExecutor = CommandExecutor()

                // Start TodoWatcher to sync todo.md changes.
                // Must be stored as a property so it isn't deallocated.
                self.todoWatcher = TodoWatcher(sessionIndex: sessionIndex) { [weak self] projectPath, hash, rawContent, items in
                    guard let self, let client = await self.wsClient else { return }
                    let wireItems = items.map { (text: $0.text, checked: $0.checked, inProgress: $0.inProgress, line: $0.line) }
                    if let msg = try? MessageEncoder.todoSync(
                        projectPath: projectPath,
                        contentHash: hash,
                        rawContent: rawContent,
                        items: wireItems
                    ) {
                        try? await client.send(msg)
                    }
                }
                if let watcher = self.todoWatcher {
                    Task { await watcher.start() }
                }
            }
        } else {
            AppLogger.agent.warning("No auth token or device ID found. Running in local-only mode.")
            AppLogger.agent.info("Configure \(BuildEnvironment.configDirectoryPath, privacy: .public)/config.json or sign in to connect.")
        }

        // Start timeout checker
        Task { [weak self] in
            guard let self else { return }
            await self.timeoutLoop()
        }

        // Start permission stall checker
        Task { [weak self] in
            guard let self else { return }
            await self.permissionStallLoop()
        }

        // Load persisted state for restart recovery
        agentState = AgentState.load()
        let restoredCount = agentState.activeSessions.count
        if restoredCount > 0 {
            AppLogger.state.info("Loaded \(restoredCount, privacy: .public) session(s) from previous run")
        }

        // Start watching for sessions across all providers
        var totalExisting = 0
        var totalResumed = 0

        for provider in await registry.enabledProviders {
            // Set up provider watching with callback to handleProviderBatch
            await provider.startWatching { [weak self] batch in
                guard let self else { return }
                await self.handleProviderBatch(batch)
            }

            // Wire up OpenCode API events for permission/question handling
            if let ocProvider = provider as? OpenCodeProvider {
                await ocProvider.setPermissionCallback { [weak self] event in
                    guard let self else { return }
                    await self.handleOpenCodePermission(event)
                }
                await ocProvider.setQuestionCallback { [weak self] event in
                    guard let self else { return }
                    await self.handleOpenCodeQuestion(event)
                }
            }

            // Discover existing sessions
            let existingSessions = await provider.discoverExistingSessions()
            let existingPathSet = Set(existingSessions.map(\.dataPath))

            var resumedSessions: [String] = []
            var deadSessions: [String] = []

            for (sessionId, snapshot) in agentState.activeSessions {
                // Only reconcile sessions belonging to this provider
                guard snapshot.provider == provider.identifier || snapshot.provider == nil else { continue }

                if existingPathSet.contains(snapshot.jsonlPath) {
                    let fm = FileManager.default
                    let fileModDate = (try? fm.attributesOfItem(atPath: snapshot.jsonlPath))?[.modificationDate] as? Date
                    let staleThreshold = Date().addingTimeInterval(-3600)
                    let isStale = agentState.lastSavedAt < staleThreshold
                        && (fileModDate ?? .distantPast) < staleThreshold

                    if isStale {
                        deadSessions.append(sessionId)
                    } else {
                        let session = DiscoveredSession(
                            sessionId: sessionId, projectPath: snapshot.projectPath ?? "",
                            dataPath: snapshot.jsonlPath, provider: provider.identifier
                        )
                        await provider.resume(session: session, offset: snapshot.lastByteOffset)
                        await sessionIndex.registerDirect(sessionId: sessionId, projectPath: snapshot.projectPath ?? "")
                        sessionProviders[sessionId] = provider.identifier
                        resumedSessions.append(sessionId)
                    }
                } else {
                    deadSessions.append(sessionId)
                }
            }

            // Mark dead sessions as completed
            for sessionId in deadSessions {
                if let client = wsClient {
                    if let msg = try? MessageEncoder.sessionCompleted(sessionId: sessionId) {
                        try? await client.send(msg)
                        AppLogger.state.info("Marked dead session \(sessionId.prefix(8), privacy: .public) as completed")
                    }
                }
                agentState.removeSession(sessionId)
            }

            // Mark all known sessions as seen to prevent duplicate session_started events
            let allKnownSessionIds = existingSessions.map(\.sessionId) + resumedSessions
            if let openCodeProvider = provider as? OpenCodeProvider {
                await openCodeProvider.markSessionsSeen(allKnownSessionIds)
            }

            // Fast-forward existing sessions not being resumed
            let resumedPaths = Set(resumedSessions.compactMap { agentState.activeSessions[$0]?.jsonlPath })
            for session in existingSessions {
                await sessionIndex.registerDirect(sessionId: session.sessionId, projectPath: session.projectPath)
                sessionProviders[session.sessionId] = provider.identifier
                if !resumedPaths.contains(session.dataPath) {
                    await provider.fastForward(session: session)
                }
            }

            totalExisting += existingSessions.count
            totalResumed += resumedSessions.count

            // Start the watcher
            await provider.beginWatching()
        }

        AppLogger.agent.info("Registered \(totalExisting, privacy: .public) existing sessions (\(totalResumed, privacy: .public) resumed)")

        // Save reconciled state
        agentState.save()

        // Periodic state save (every 30s)
        Task { [weak self] in
            while let self {
                try? await Task.sleep(for: .seconds(30))
                await self.saveState()
            }
        }

        // Keep running — graceful shutdown on SIGINT/SIGTERM
        AppLogger.agent.info("Agent is running. Press Ctrl+C to stop.")
        let shutdownSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let shutdownSource2 = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let shutdownStream = AsyncStream<Void> { continuation in
            shutdownSource.setEventHandler { continuation.yield() }
            shutdownSource2.setEventHandler { continuation.yield() }
            shutdownSource.resume()
            shutdownSource2.resume()
        }

        for await _ in shutdownStream {
            AppLogger.agent.info("\nGraceful shutdown — notifying backend of active sessions...")
            await gracefulShutdown()
            exit(0)
        }
    }

    func handleProviderBatch(_ batch: ProviderSessionBatch) async {
        let sessionId = batch.sessionId
        let projectPath = batch.projectPath

        // Track session and its provider
        sessionProviders[sessionId] = batch.provider
        await sessionIndex.registerDirect(sessionId: sessionId, projectPath: projectPath)

        // Track session in persistent state
        agentState.trackSession(sessionId: sessionId, jsonlPath: batch.dataPath, projectPath: projectPath, provider: batch.provider)

        // Detect new sessions and generate ephemeral key pair for forward secrecy
        let existingInfo = await stateManager.getInfo(sessionId)
        if existingInfo == nil && ephemeralKeys[sessionId] == nil {
            let ephKey = Curve25519.KeyAgreement.PrivateKey()
            ephemeralKeys[sessionId] = ephKey
            sessionKeyCache?.setEphemeralKey(sessionId: sessionId, key: ephKey)
        }

        if !batch.events.isEmpty {
            // Clear attention icon — session is active
            Task { @MainActor [weak self] in
                self?.statusBarController?.setAttention(false)
            }
        }

        // Set user prompt for description generation
        if let prompt = batch.rawUserPrompt, !prompt.isEmpty {
            await stateManager.setUserPrompt(sessionId: sessionId, prompt: prompt)
        }

        for providerEvent in batch.events {
            let event = providerEvent.event
            let result = await stateManager.processEvent(
                event,
                projectPath: projectPath,
                cwd: providerEvent.cwd,
                gitBranch: providerEvent.gitBranch,
                privacyMode: providerEvent.privacyMode
            )

            let seq = agentState.nextSeq(for: sessionId)

            if let client = wsClient {
                await sendEvent(
                    client: client,
                    sessionId: sessionId,
                    event: event,
                    seq: seq,
                    shouldSendUpdate: result.shouldSendUpdate,
                    provider: batch.provider
                )
            }

            AppLogger.session.debug("\(sessionId.prefix(8), privacy: .public) \(event.eventType.rawValue, privacy: .public) seq=\(seq, privacy: .public)")

            // Forward permission-needed events from non-CC providers as permission requests.
            // Skip when SSE API client is connected (SSE handles it with proper round-trip).
            if event.eventType == .permissionNeeded, batch.provider != "claude_code",
               await isOpenCodeAPIDisconnected() {
                let toolName = event.data["toolName"] ?? "unknown"
                let toolUseId = event.data["toolUseId"] ?? UUID().uuidString
                let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).uppercased()
                let expiresAt = Int64(Date().timeIntervalSince1970) + 300

                // Build tool input from event content if available
                var toolInput: [String: String] = [:]
                if let fields = event.content?["toolInputFields"],
                   let data = fields.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode([ToolInputField].self, from: data) {
                    for field in parsed {
                        toolInput[field.label] = field.value
                    }
                }
                if toolInput.isEmpty, let summary = event.content?["toolInputSummary"] {
                    toolInput["details"] = summary
                }

                let permEvent = PermissionSocket.PermissionRequestEvent(
                    sessionId: sessionId,
                    toolName: toolName,
                    toolInput: toolInput,
                    toolUseId: toolUseId,
                    nonce: String(nonce),
                    expiresAt: expiresAt,
                    deviceId: enrolledDeviceId ?? "",
                    challenge: nil
                )
                await forwardPermissionRequest(permEvent)
            }
        }

        // Update byte offset in state after processing batch
        if !batch.dataPath.isEmpty,
           let registry = providerRegistry,
           let provider = await registry.provider(for: batch.provider) {
            let currentOffset = await provider.currentOffset(for: batch.dataPath)
            agentState.updateOffset(sessionId: sessionId, byteOffset: currentOffset)
        }

        // Check for pending plan restart
        if let socket = permissionSocket, await socket.hasPendingRestarts() {
            let status = (await stateManager.getInfo(sessionId))?.status
            if status == .idle || status == .completed {
                if let intent = await socket.consumeRestartIntent(sessionId: sessionId) {
                    AppLogger.agent.info("Session \(sessionId.prefix(8), privacy: .public) idle — executing plan restart")
                    await spawnPlanRestart(sessionId: sessionId, planContent: intent.planContent)
                }
            }
        }
    }

    /// Check if the OpenCode API client is disconnected (fallback to SQLite-based permissions).
    private func isOpenCodeAPIDisconnected() async -> Bool {
        guard let registry = providerRegistry,
              let provider = await registry.provider(for: "opencode") as? OpenCodeProvider else {
            return true
        }
        return await !provider.isAPIConnected
    }

    // MARK: - OpenCode API Event Handlers

    func handleOpenCodePermission(_ event: OpenCodeAPIClient.PermissionEvent) async {
        guard let client = wsClient else { return }

        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).uppercased()

        // Track nonce -> OpenCode request ID for the round-trip response
        pendingProviderPermissions[String(nonce)] = (provider: "opencode", requestId: event.id)

        // Also track in the provider for direct response handling
        if let registry = providerRegistry,
           let provider = await registry.provider(for: "opencode") as? OpenCodeProvider {
            await provider.trackPermission(nonce: String(nonce), requestId: event.id, directory: event.directory)
        }

        let toolInput: [String: String] = [
            "permission": event.permission,
            "patterns": event.patterns.joined(separator: ", ")
        ]

        let permEvent = PermissionSocket.PermissionRequestEvent(
            sessionId: event.sessionId,
            toolName: event.permission,
            toolInput: toolInput,
            toolUseId: event.toolCallId,
            nonce: String(nonce),
            expiresAt: Int64(Date().timeIntervalSince1970) + 300,
            deviceId: enrolledDeviceId ?? "",
            challenge: nil
        )
        await forwardPermissionRequest(permEvent)
    }

    func handleOpenCodeQuestion(_ event: OpenCodeAPIClient.QuestionEvent) async {
        guard let client = wsClient else { return }

        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).uppercased()

        // Track nonce -> OpenCode request ID
        pendingProviderPermissions[String(nonce)] = (provider: "opencode", requestId: event.id)

        if let registry = providerRegistry,
           let provider = await registry.provider(for: "opencode") as? OpenCodeProvider {
            await provider.trackQuestion(nonce: String(nonce), requestId: event.id, directory: event.directory)
        }

        // Format questions as AskQuestion JSON for the iOS QuestionOverlay
        struct AskOption: Codable { let label: String; let description: String }
        struct AskQuestion: Codable { let question: String; let header: String; let options: [AskOption]; let multiSelect: Bool }

        let askQuestions = event.questions.map { q in
            AskQuestion(
                question: q.question,
                header: q.header.isEmpty ? "Question" : q.header,
                options: q.options.map { AskOption(label: $0.label, description: $0.description) },
                multiSelect: false
            )
        }

        var toolInput: [String: String] = [:]
        if let json = try? JSONEncoder().encode(askQuestions),
           let str = String(data: json, encoding: .utf8) {
            toolInput["questions"] = str
        }

        let permEvent = PermissionSocket.PermissionRequestEvent(
            sessionId: event.sessionId,
            toolName: "AskUserQuestion",
            toolInput: toolInput,
            toolUseId: event.id,
            nonce: String(nonce),
            expiresAt: Int64(Date().timeIntervalSince1970) + 300,
            deviceId: enrolledDeviceId ?? "",
            challenge: nil
        )
        await forwardPermissionRequest(permEvent)
    }

    private func sendEvent(client: WebSocketClient, sessionId: String, event: NormalizedEvent, seq: Int = 0, shouldSendUpdate: Bool, provider: String? = nil) async {
        // Send session update FIRST so the session row exists before events reference it
        if shouldSendUpdate, let info = await stateManager.getInfo(sessionId) {
            let ephPubKey = ephemeralKeys[sessionId]?.publicKey.rawRepresentation.base64EncodedString()
            do {
                let updateMsg = try MessageEncoder.sessionUpdate(
                    sessionId: sessionId,
                    projectPath: info.projectPath,
                    gitBranch: info.gitBranch,
                    cwd: info.cwd,
                    status: info.status.rawValue,
                    tokensIn: info.tokensIn,
                    tokensOut: info.tokensOut,
                    turnCount: info.turnCount,
                    description: info.description,
                    ephemeralPublicKey: ephPubKey,
                    lastInputTokens: info.lastInputTokens,
                    provider: provider ?? sessionProviders[sessionId]
                )
                try await client.send(updateMsg)
            } catch {
                AppLogger.ws.error("Failed to send update: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Then send the event with seq for dedup
        do {
            let eventMsg = try MessageEncoder.sessionEvent(sessionId: sessionId, event: event, seq: seq)
            try await client.send(eventMsg)
        } catch {
            AppLogger.ws.error("Failed to send event: \(error.localizedDescription, privacy: .public)")
        }
    }

    func shareLogs() async {
        let count = await logCollector.shareAll()
        if count > 0 {
            AppLogger.agent.info("Shared \(count, privacy: .public) log entries")
            showNotification(title: "Logs Shared", message: "Uploaded \(count) log entries to the server.")
        } else {
            AppLogger.agent.info("No buffered logs to share")
            showNotification(title: "Share Logs", message: "No buffered logs to share.")
        }
    }

    func showNotification(title: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func submitFeedback(category: String, message: String) async {
        let keychain = KeychainStore()
        guard let token = config.authToken ?? (try? keychain.loadToken(forKey: "auth-token")),
              let deviceId = enrolledDeviceId else {
            AppLogger.agent.warning("Cannot submit feedback: not authenticated")
            return
        }
        let apiClient = APIClient(baseURL: config.httpBaseURL, token: token)
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        do {
            try await apiClient.submitFeedback(deviceId: deviceId, category: category, message: message, appVersion: appVersion)
            AppLogger.agent.info("Feedback submitted successfully")
        } catch {
            AppLogger.agent.error("Failed to submit feedback: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setSessionProvider(sessionId: String, provider: String) {
        sessionProviders[sessionId] = provider
    }

    /// Search for a JSONL file matching the given session ID under the claude projects directory.
    static func findJSONLFile(sessionId: String, under projectsPath: String) -> String? {
        let fm = FileManager.default
        let filename = "\(sessionId).jsonl"
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: projectsPath),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == filename {
            return fileURL.path
        }
        return nil
    }

    // MARK: - Inventory Scan

    func performInventoryScan(deviceId: String, force: Bool = false) async {
        guard let scanner = inventoryScanner, let client = wsClient else { return }

        // Collect known project paths from session index
        let projectPaths = await sessionIndex.allProjectPaths()

        guard let report = await scanner.scan(projectPaths: Set(projectPaths), force: force) else {
            AppLogger.agent.debug("Inventory unchanged, skipping sync")
            return
        }

        // Always send the FULL report. The backend decides what to store
        // based on device privacy mode (redact for telemetry_only, skip DB
        // for relay_only). iOS always gets the unredacted version via WS.
        let privacyMode = config.defaultPrivacyMode

        do {
            let msg: WSMessage
            if privacyMode == "encrypted", let keyCache = sessionKeyCache {
                // Encrypt the entire inventory JSON using a device-level E2EE key.
                // Backend stores opaque blob; iOS decrypts client-side.
                let inventoryData = try JSONEncoder().encode(report)
                guard let inventoryStr = String(data: inventoryData, encoding: .utf8) else {
                    AppLogger.agent.error("Failed to encode inventory to string")
                    return
                }
                let peerKeyMap = keyCache.getOrDeriveKeys(sessionId: deviceId)
                guard let (_, key) = peerKeyMap.first else {
                    AppLogger.agent.warning("No E2EE peer keys for inventory encryption")
                    return
                }
                let encrypted = try E2EEncryption.encryptVersioned(
                    inventoryStr, key: key,
                    keyVersion: keyCache.myKeyVersion,
                    senderDeviceId: keyCache.myDeviceId
                )
                msg = try MessageEncoder.inventorySync(
                    deviceID: deviceId, inventory: report,
                    encrypted: true, encryptedPayload: encrypted
                )
                AppLogger.agent.info("Inventory encrypted and synced")
            } else {
                // Send full inventory. Backend handles redaction for DB storage.
                msg = try MessageEncoder.inventorySync(deviceID: deviceId, inventory: report)
                AppLogger.agent.info("Inventory synced: \(report.globalCommands.count, privacy: .public) commands, \(report.globalSkills.count, privacy: .public) skills, \(report.mcpServers.count, privacy: .public) MCP servers, \(report.hooks.count, privacy: .public) hooks, \(report.plans.count, privacy: .public) plans, \(report.teams.count, privacy: .public) teams")
            }
            try await client.send(msg)
        } catch {
            AppLogger.agent.error("Failed to sync inventory: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Key Fingerprint

    /// Compute a short hex fingerprint of a base64 public key for comparison and logging.
    static func keyFingerprint(_ publicKeyBase64: String) -> String {
        guard let data = Data(base64Encoded: publicKeyBase64) else { return "invalid" }
        let hash = SHA256.hash(data: data)
        return Array(hash).prefix(4).map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}
