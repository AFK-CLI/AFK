//
//  Agent.swift
//  AFK-Agent
//

import Foundation
import CryptoKit

actor Agent {
    var config: AgentConfig
    let sessionIndex = SessionIndex()
    let parser = JSONLParser()
    let stateManager = SessionStateManager()
    var normalizer = EventNormalizer()
    var wsClient: WebSocketClient?
    var permissionSocket: PermissionSocket?
    var commandExecutor: CommandExecutor?
    var commandVerifier: CommandVerifier?
    var commandNonceStore = NonceStore()
    var enrolledDeviceId: String?
    var ephemeralKeys: [String: Curve25519.KeyAgreement.PrivateKey] = [:]
    var sessionKeyCache: SessionKeyCache?
    var agentState = AgentState()
    var diskQueue: DiskQueue?
    var todoWatcher: TodoWatcher?
    var signInController: SignInWindowController?
    nonisolated(unsafe) var onAccountChanged: ((String?) -> Void)?
    let statusBarController: StatusBarController?

    init(config: AgentConfig, statusBarController: StatusBarController? = nil) {
        self.config = config
        self.statusBarController = statusBarController
    }

    func run() async {
        print("[Agent] Starting AFK Agent...")
        print("[Agent] Watching: \(config.claudeProjectsPath)")

        // Initialize disk-backed offline queue
        let queueDir = URL(fileURLWithPath: BuildEnvironment.configDirectoryPath)
            .appendingPathComponent("offline-queue")
        let queue = DiskQueue(directory: queueDir)
        self.diskQueue = queue
        if queue.count > 0 {
            print("[Agent] Disk queue recovered \(queue.count) pending messages")
        }

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
            print("[Agent] No token found. Showing sign-in window...")
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
                    print("[Agent] Retrying connection with refreshed token...")
                    token = newToken
                    connected = await setupWebSocket(token: token, deviceId: deviceId, keychain: keychain)
                }

                // Step 2: If refresh didn't work, re-enroll
                if !connected {
                    let savedDeviceId = deviceId
                    try? keychain.deleteToken(forKey: "auth-token")
                    try? keychain.deleteToken(forKey: "refresh-token")
                    print("[Agent] Refresh failed — showing sign-in window...")
                    if let result = await showSignInWindow(existingDeviceId: savedDeviceId) {
                        token = result.token
                        deviceId = result.deviceId
                        connected = await setupWebSocket(token: token, deviceId: deviceId, keychain: keychain)
                    }
                }
            }

            if connected {
                print("[Agent] WebSocket ready — starting file watcher")
            } else {
                print("[Agent] WebSocket failed — events will be local only until reconnect")
            }

            self.enrolledDeviceId = deviceId

            if let client = wsClient {
                // Broadcast initial control state to iOS
                await broadcastControlState()

                // Start heartbeat loop
                Task { [weak self] in
                    guard let self else { return }
                    await self.heartbeatLoop(deviceId: deviceId)
                }

                // Start permission socket if remote approval is enabled
                if config.remoteApprovalEnabled {
                    await setupPermissionSocket(deviceId: deviceId, client: client)
                }

                // Wire E2EE content encryption into the normalizer
                await setupE2EEEncryptor(deviceId: deviceId)

                // Refresh peer keys on every WS reconnect to pick up rotated keys
                await client.onReconnect { [weak self] in
                    guard let self else { return }
                    print("[Agent] WS reconnected — refreshing E2EE peer keys")
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
                    let wireItems = items.map { (text: $0.text, checked: $0.checked, line: $0.line) }
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
            print("[Agent] No auth token or device ID found. Running in local-only mode.")
            print("[Agent] Configure \(BuildEnvironment.configDirectoryPath)/config.json or sign in to connect.")
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
            print("[State] Loaded \(restoredCount) session(s) from previous run")
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
                    print("[State] Marked dead session \(sessionId.prefix(8)) as completed")
                }
            }
            agentState.removeSession(sessionId)
        }

        if !resumedSessions.isEmpty {
            print("[State] Resumed \(resumedSessions.count) session(s): \(resumedSessions.map { String($0.prefix(8)) }.joined(separator: ", "))")
        }

        // Fast-forward files that are NOT being resumed from state
        let resumedPaths = Set(resumedSessions.compactMap { agentState.activeSessions[$0]?.jsonlPath })
        for file in existingFiles {
            _ = await sessionIndex.register(filePath: file)
            if !resumedPaths.contains(file) {
                await parser.fastForwardToEnd(file)
            }
        }
        print("[Agent] Registered \(existingFiles.count) existing JSONL files (\(resumedSessions.count) resumed, \(existingFiles.count - resumedSessions.count) fast-forwarded)")

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
        print("[Agent] Agent is running. Press Ctrl+C to stop.")
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
            print("\n[Agent] Graceful shutdown — notifying backend of active sessions...")
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
                    print("[\(sessionId.prefix(8))] \(event.eventType.rawValue) seq=\(seq)")
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
                        print("[Agent] Session \(sessionId.prefix(8)) idle — executing plan restart")
                        await spawnPlanRestart(sessionId: sessionId, planContent: intent.planContent)
                    }
                }
            }
        } catch {
            print("[Agent] Error parsing \(filePath): \(error)")
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
                    ephemeralPublicKey: ephPubKey
                )
                try await client.send(updateMsg)
            } catch {
                print("[WS] Failed to send update: \(error.localizedDescription)")
            }
        }

        // Then send the event with seq for dedup
        do {
            let eventMsg = try MessageEncoder.sessionEvent(sessionId: sessionId, event: event, seq: seq)
            try await client.send(eventMsg)
        } catch {
            print("[WS] Failed to send event: \(error.localizedDescription)")
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

    // MARK: - Key Fingerprint

    /// Compute a short hex fingerprint of a base64 public key for comparison and logging.
    static func keyFingerprint(_ publicKeyBase64: String) -> String {
        guard let data = Data(base64Encoded: publicKeyBase64) else { return "invalid" }
        let hash = SHA256.hash(data: data)
        return Array(hash).prefix(4).map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}
