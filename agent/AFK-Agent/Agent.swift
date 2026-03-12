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
    let parser = JSONLParser()
    let stateManager = SessionStateManager()
    var normalizer = EventNormalizer()
    var wsClient: WebSocketClient?
    var permissionSocket: PermissionSocket?
    var otlpReceiver: OTLPReceiver?
    var commandExecutor: CommandExecutor?
    var commandVerifier: CommandVerifier?
    var commandNonceStore = NonceStore()
    var enrolledDeviceId: String?
    var ephemeralKeys: [String: Curve25519.KeyAgreement.PrivateKey] = [:]
    var sessionKeyCache: SessionKeyCache?
    var agentState = AgentState()
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
        AppLogger.agent.info("Watching: \(self.config.claudeProjectsPath, privacy: .public)")

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

        // Start watching for JSONL files
        let watcher = SessionWatcher(projectsPath: config.claudeProjectsPath) { [weak self] filePath in
            guard let self else { return }
            await self.handleFileChange(filePath)
        }
        let existingFiles = await watcher.seedExistingFiles()

        // Reconcile restored state with actual files on disk
        let existingFileSet = Set(existingFiles)
        var resumedSessions: [String] = []
        var deadSessions: [String] = []

        for (sessionId, snapshot) in agentState.activeSessions {
            if existingFileSet.contains(snapshot.jsonlPath) {
                // JSONL file still exists — check if stale (state > 1 hour old + file not modified recently)
                let fm = FileManager.default
                let fileModDate = (try? fm.attributesOfItem(atPath: snapshot.jsonlPath))?[.modificationDate] as? Date
                let staleThreshold = Date().addingTimeInterval(-3600)
                let isStale = agentState.lastSavedAt < staleThreshold
                    && (fileModDate ?? .distantPast) < staleThreshold

                if isStale {
                    deadSessions.append(sessionId)
                } else {
                    // Resume: restore byte offset so parser picks up where we left off
                    await parser.setOffset(for: snapshot.jsonlPath, to: snapshot.lastByteOffset)
                    _ = await sessionIndex.register(filePath: snapshot.jsonlPath)
                    resumedSessions.append(sessionId)
                }
            } else {
                // JSONL file gone — session is dead
                deadSessions.append(sessionId)
            }
        }

        // Mark dead sessions as completed on backend
        for sessionId in deadSessions {
            if let client = wsClient {
                if let msg = try? MessageEncoder.sessionCompleted(sessionId: sessionId) {
                    try? await client.send(msg)
                    AppLogger.state.info("Marked dead session \(sessionId.prefix(8), privacy: .public) as completed")
                }
            }
            agentState.removeSession(sessionId)
        }

        if !resumedSessions.isEmpty {
            AppLogger.state.info("Resumed \(resumedSessions.count, privacy: .public) session(s): \(resumedSessions.map { String($0.prefix(8)) }.joined(separator: ", "), privacy: .public)")
        }

        // Fast-forward files that are NOT being resumed from state
        let resumedPaths = Set(resumedSessions.compactMap { agentState.activeSessions[$0]?.jsonlPath })
        for file in existingFiles {
            _ = await sessionIndex.register(filePath: file)
            if !resumedPaths.contains(file) {
                await parser.fastForwardToEnd(file)
            }
        }
        AppLogger.agent.info("Registered \(existingFiles.count, privacy: .public) existing JSONL files (\(resumedSessions.count, privacy: .public) resumed, \(existingFiles.count - resumedSessions.count, privacy: .public) fast-forwarded)")

        // Save reconciled state
        agentState.save()
        await watcher.start()

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

    private func handleFileChange(_ filePath: String) async {
        guard filePath.hasSuffix(".jsonl") else { return }

        let (sessionId, projectPath) = await sessionIndex.register(filePath: filePath)

        // Track session in persistent state
        agentState.trackSession(sessionId: sessionId, jsonlPath: filePath, projectPath: projectPath)

        // Detect new sessions and generate ephemeral key pair for forward secrecy
        // Only for truly new sessions (not resumed from state)
        let existingInfo = await stateManager.getInfo(sessionId)
        if existingInfo == nil && ephemeralKeys[sessionId] == nil {
            let ephKey = Curve25519.KeyAgreement.PrivateKey()
            ephemeralKeys[sessionId] = ephKey
            sessionKeyCache?.setEphemeralKey(sessionId: sessionId, key: ephKey)
        }

        do {
            let entries = try await parser.parseNewEntries(at: filePath)
            if !entries.isEmpty {
                // Clear attention icon — Claude is active again
                Task { @MainActor [weak self] in
                    self?.statusBarController?.setAttention(false)
                }
            }
            for entry in entries {
                // Skip sidechain entries
                if entry.isSidechain == true { continue }

                let entryCwd = entry.cwd ?? ""
                let entryBranch = entry.gitBranch ?? ""
                let privacyMode = config.privacyMode(for: projectPath)

                // Extract raw user prompt BEFORE normalization (which may encrypt content)
                if entry.type == "user" && entry.userType == "external",
                   let msgContent = entry.message?.content {
                    let rawPrompt = msgContent.textContent
                    if !rawPrompt.isEmpty {
                        await stateManager.setUserPrompt(sessionId: sessionId, prompt: rawPrompt)
                    }
                }

                let events = normalizer.normalize(entry: entry, sessionId: sessionId, projectPath: projectPath, privacyMode: privacyMode)
                for event in events {
                    let result = await stateManager.processEvent(event, projectPath: projectPath, cwd: entryCwd, gitBranch: entryBranch, privacyMode: privacyMode)

                    // Assign monotonic seq number
                    let seq = agentState.nextSeq(for: sessionId)

                    // Send over WebSocket
                    if let client = wsClient {
                        await sendEvent(client: client, sessionId: sessionId, event: event, seq: seq, shouldSendUpdate: result.shouldSendUpdate)
                    }

                    // Log locally
                    AppLogger.session.debug("\(sessionId.prefix(8), privacy: .public) \(event.eventType.rawValue, privacy: .public) seq=\(seq, privacy: .public)")
                }
            }

            // Update byte offset in state after processing batch
            let currentOffset = await parser.currentOffset(for: filePath)
            agentState.updateOffset(sessionId: sessionId, byteOffset: currentOffset)

            // Fast path: check if this session has a pending restart intent
            if let socket = permissionSocket, await socket.hasPendingRestarts() {
                let status = (await stateManager.getInfo(sessionId))?.status
                if status == .idle || status == .completed {
                    if let intent = await socket.consumeRestartIntent(sessionId: sessionId) {
                        AppLogger.agent.info("Session \(sessionId.prefix(8), privacy: .public) idle — executing plan restart")
                        await spawnPlanRestart(sessionId: sessionId, planContent: intent.planContent)
                    }
                }
            }
        } catch {
            AppLogger.agent.error("Error parsing \(filePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func sendEvent(client: WebSocketClient, sessionId: String, event: NormalizedEvent, seq: Int = 0, shouldSendUpdate: Bool) async {
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
                    lastInputTokens: info.lastInputTokens
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
