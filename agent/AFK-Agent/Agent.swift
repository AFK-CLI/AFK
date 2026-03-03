//
//  Agent.swift
//  AFK-Agent
//

import Foundation
import CryptoKit

/// Thread-safe cache of per-session E2EE symmetric keys for multiple peers.
private final class SessionKeyCache: @unchecked Sendable {
    /// sessionId -> [deviceId -> SymmetricKey]
    private var keys: [String: [String: SymmetricKey]] = [:]
    private var ephemeralKeys: [String: Curve25519.KeyAgreement.PrivateKey] = [:]
    private let lock = NSLock()
    private let e2ee: E2EEncryption
    /// All peer device public keys: deviceId -> base64 public key
    private let peerKeys: [String: String]
    /// Sender's key version for the versioned wire format
    let myKeyVersion: Int
    /// Sender's device ID for the versioned wire format
    let myDeviceId: String
    /// Peer capabilities: deviceId -> [capability strings]
    private let peerCapabilities: [String: [String]]
    /// Peer key versions: deviceId -> key version
    private let peerKeyVersions: [String: Int]

    init(e2ee: E2EEncryption, peerKeys: [String: String], myKeyVersion: Int, myDeviceId: String,
         peerCapabilities: [String: [String]] = [:], peerKeyVersions: [String: Int] = [:]) {
        self.e2ee = e2ee
        self.peerKeys = peerKeys
        self.myKeyVersion = myKeyVersion
        self.myDeviceId = myDeviceId
        self.peerCapabilities = peerCapabilities
        self.peerKeyVersions = peerKeyVersions
    }

    func setEphemeralKey(sessionId: String, key: Curve25519.KeyAgreement.PrivateKey) {
        lock.lock(); defer { lock.unlock() }
        ephemeralKeys[sessionId] = key
        keys.removeValue(forKey: sessionId)  // invalidate cached v1 key
    }

    func usesV2(sessionId: String, peerDeviceId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ephemeralKeys[sessionId] != nil
            && (peerCapabilities[peerDeviceId] ?? []).contains("e2ee_v2")
    }

    func peerKeyVersion(_ deviceId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return peerKeyVersions[deviceId] ?? 1
    }

    /// Derive session keys for all peers for the given session.
    /// Uses v2 (forward-secret) derivation when ephemeral key exists and peer supports it,
    /// falls back to v1 (long-term only) otherwise.
    func getOrDeriveKeys(sessionId: String) -> [String: SymmetricKey] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = keys[sessionId] { return cached }
        var sessionKeys: [String: SymmetricKey] = [:]
        for (deviceId, pubKey) in peerKeys {
            if let ephKey = ephemeralKeys[sessionId],
               (peerCapabilities[deviceId] ?? []).contains("e2ee_v2") {
                // V2: forward-secret key
                if let key = try? e2ee.deriveSessionKeyV2(
                    peerPublicKeyBase64: pubKey,
                    ephemeralKey: ephKey,
                    sessionId: sessionId
                ) {
                    sessionKeys[deviceId] = key
                }
            } else {
                // V1: long-term only
                if let key = try? e2ee.sessionKey(peerPublicKeyBase64: pubKey, sessionId: sessionId) {
                    sessionKeys[deviceId] = key
                }
            }
        }
        keys[sessionId] = sessionKeys
        return sessionKeys
    }
}

actor Agent {
    private var config: AgentConfig
    private let sessionIndex = SessionIndex()
    private let parser = JSONLParser()
    private let stateManager = SessionStateManager()
    private var normalizer = EventNormalizer()
    private var wsClient: WebSocketClient?
    private var permissionSocket: PermissionSocket?
    private var commandExecutor: CommandExecutor?
    private var commandVerifier: CommandVerifier?
    private var commandNonceStore = NonceStore()
    private var enrolledDeviceId: String?
    private var ephemeralKeys: [String: Curve25519.KeyAgreement.PrivateKey] = [:]
    private var sessionKeyCache: SessionKeyCache?
    private var agentState = AgentState()
    private var diskQueue: DiskQueue?
    private var todoWatcher: TodoWatcher?
    private var signInController: SignInWindowController?
    nonisolated(unsafe) var onAccountChanged: ((String?) -> Void)?
    private let statusBarController: StatusBarController?

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

    private struct EnrollResult {
        let token: String
        let deviceId: String
    }

    /// Show the sign-in window and enroll the device after successful authentication.
    private func showSignInWindow(existingDeviceId: String? = nil) async -> EnrollResult? {
        let serverURL = config.serverURL
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let controller = SignInWindowController()
                controller.showSignInWindow(serverURL: serverURL) { token, refreshToken, userId, email in
                    Task {
                        let result = await self.emailEnroll(
                            token: token,
                            refreshToken: refreshToken,
                            email: email,
                            existingDeviceId: existingDeviceId
                        )
                        continuation.resume(returning: result)
                    }
                }
                // Store the controller reference to keep it alive
                Task {
                    await self.setSignInController(controller)
                }
            }
        }
    }

    /// Store the sign-in controller reference (actor-isolated helper).
    private func setSignInController(_ controller: SignInWindowController?) {
        self.signInController = controller
    }

    /// Manually trigger sign-in from the menu bar.
    func signIn() async {
        if let result = await showSignInWindow() {
            let keychain = KeychainStore()
            let connected = await setupWebSocket(token: result.token, deviceId: result.deviceId, keychain: keychain)
            self.enrolledDeviceId = result.deviceId
            if connected {
                print("[Agent] Connected after manual sign-in")
            }
        }
    }

    /// Sign out: clear credentials, disconnect, update UI.
    func signOut() async {
        let keychain = KeychainStore()
        try? keychain.deleteToken(forKey: "auth-token")
        try? keychain.deleteToken(forKey: "refresh-token")
        try? keychain.deleteToken(forKey: "device-id")
        try? keychain.deleteToken(forKey: "user-email")
        if let existingClient = wsClient {
            await existingClient.disconnect()
            self.wsClient = nil
        }
        self.enrolledDeviceId = nil
        self.sessionKeyCache = nil
        diskQueue?.purge()
        onAccountChanged?(nil)
        print("[Agent] Signed out — credentials cleared")
    }

    /// Enroll a device after email/password authentication (already have tokens).
    private func emailEnroll(token: String, refreshToken: String, email: String, existingDeviceId: String? = nil) async -> EnrollResult? {
        let httpBase = config.httpBaseURL
        do {
            // 1. Load existing KA key pair, or generate if none exists
            let keychain = KeychainStore()
            let kaIdentity: KeyAgreementIdentity
            if let existing = try? KeyAgreementIdentity.load(from: keychain) {
                kaIdentity = existing
                print("[Agent] Reusing existing KeyAgreement key pair")
            } else {
                kaIdentity = KeyAgreementIdentity.generate()
                try kaIdentity.save(to: keychain)
                print("[Agent] KeyAgreement key pair generated")
            }

            // 2. Enroll this device
            let deviceName = config.deviceName
            let systemInfo = "\(ProcessInfo.processInfo.operatingSystemVersionString)"
            let api = APIClient(baseURL: httpBase, token: token)
            let device = try await api.enrollDevice(
                name: deviceName,
                publicKey: "email-\(deviceName)",
                systemInfo: systemInfo,
                keyAgreementPublicKey: kaIdentity.publicKeyBase64,
                deviceId: existingDeviceId
            )
            print("[Agent] Device enrolled: \(device.name) (id: \(device.id))")

            // Track registered KA fingerprint
            let enrolledFingerprint = Self.keyFingerprint(kaIdentity.publicKeyBase64)
            try? keychain.saveToken(enrolledFingerprint, forKey: "last-registered-ka-fingerprint")

            // 3. If re-enrolled with existing device, re-register KA key if changed
            if existingDeviceId != nil {
                let currentFingerprint = Self.keyFingerprint(kaIdentity.publicKeyBase64)
                let lastRegistered = try? keychain.loadToken(forKey: "last-registered-ka-fingerprint")
                if lastRegistered != currentFingerprint {
                    try? await api.registerKeyAgreement(deviceId: device.id, publicKey: kaIdentity.publicKeyBase64)
                    try? keychain.saveToken(currentFingerprint, forKey: "last-registered-ka-fingerprint")
                    print("[Agent] Re-registered KA key for existing device")
                }
            }

            // 4. Persist tokens + device ID + email to keychain
            try keychain.saveToken(token, forKey: "auth-token")
            try keychain.saveToken(refreshToken, forKey: "refresh-token")
            try keychain.saveToken(device.id, forKey: "device-id")
            try keychain.saveToken(email, forKey: "user-email")
            print("[Agent] Credentials saved to keychain")

            onAccountChanged?(email)

            // Clear the sign-in controller reference
            self.signInController = nil

            return EnrollResult(token: token, deviceId: device.id)
        } catch {
            print("[Agent] Email enrollment failed: \(error)")
            self.signInController = nil
            return nil
        }
    }

    /// Attempt to refresh an expired access token using the stored refresh token.
    /// Returns a new access token on success, or nil if refresh fails.
    private func tryRefreshToken(keychain: KeychainStore) async -> String? {
        guard let refreshToken = try? keychain.loadToken(forKey: "refresh-token") else {
            print("[Agent] No refresh token in keychain")
            return nil
        }
        do {
            let resp = try await APIClient.refreshToken(baseURL: config.httpBaseURL, refreshToken: refreshToken)
            try keychain.saveToken(resp.accessToken, forKey: "auth-token")
            try keychain.saveToken(resp.refreshToken, forKey: "refresh-token")
            print("[Agent] Token refreshed successfully")
            return resp.accessToken
        } catch {
            print("[Agent] Token refresh failed: \(error)")
            return nil
        }
    }

    /// Create WS client, fetch ticket, connect, and return whether connection succeeded.
    /// Disconnects any existing client first to prevent stale reconnect loops.
    private func setupWebSocket(token: String, deviceId: String, keychain: KeychainStore) async -> Bool {
        // Disconnect existing client to stop its reconnect loop
        if let existingClient = wsClient {
            await existingClient.disconnect()
            self.wsClient = nil
        }
        let baseURL = config.serverURL
        let wsURLString: String
        if baseURL.hasPrefix("ws") {
            wsURLString = "\(baseURL)/v1/ws/agent"
        } else {
            wsURLString = "ws://\(baseURL)/v1/ws/agent"
        }

        guard let wsURL = URL(string: wsURLString) else { return false }

        let client = WebSocketClient(url: wsURL, token: token, deviceId: deviceId, diskQueue: diskQueue!)
        self.wsClient = client
        await client.startNetworkMonitor()

        let httpBaseURL = config.httpBaseURL

        await client.setTicketProvider { [weak self, deviceId] in
            guard let self else { return nil }

            // Read current token from keychain (may have been refreshed)
            guard let currentToken = try? keychain.loadToken(forKey: "auth-token") else {
                print("[Agent] No auth token in keychain for ticket fetch")
                return nil
            }

            let api = APIClient(baseURL: httpBaseURL, token: currentToken)
            do {
                let ticket = try await api.getWSTicket(deviceId: deviceId)
                print("[Agent] Obtained WS ticket")
                return ticket
            } catch {
                let code = (error as NSError).code
                if code == 401 {
                    print("[Agent] WS ticket auth expired, refreshing token...")
                    if let newToken = await self.tryRefreshToken(keychain: keychain) {
                        await self.wsClient?.updateToken(newToken)
                        let freshApi = APIClient(baseURL: httpBaseURL, token: newToken)
                        if let ticket = try? await freshApi.getWSTicket(deviceId: deviceId) {
                            print("[Agent] Obtained WS ticket after token refresh")
                            return ticket
                        }
                    }
                }
                print("[Agent] WS ticket fetch failed: \(error.localizedDescription)")
                return nil
            }
        }

        let api = APIClient(baseURL: httpBaseURL, token: token)

        await client.onMessage { [weak self] msg in
            guard let self else { return }
            await self.handleWSMessage(msg)
        }

        // Fetch initial ticket, then connect
        var initialTicket: String?
        do {
            initialTicket = try await api.getWSTicket(deviceId: deviceId)
            print("[Agent] Obtained initial WS ticket")
        } catch {
            print("[Agent] Initial WS ticket fetch failed: \(error.localizedDescription)")
        }

        print("[Agent] Connecting to \(wsURLString)...")
        Task { await client.connect(ticket: initialTicket) }
        return await client.waitForConnection()
    }

    private func heartbeatLoop(deviceId: String) async {
        while true {
            try? await Task.sleep(for: .seconds(config.heartbeatInterval))
            guard let client = wsClient else { continue }
            let sessions = await stateManager.allSessions()
            let activeIds = sessions.filter { $0.value.status == .running || $0.value.status == .idle }.map(\.key)
            if let msg = try? MessageEncoder.heartbeat(deviceID: deviceId, activeSessions: activeIds) {
                try? await client.send(msg)
            }
        }
    }

    private func timeoutLoop() async {
        while true {
            try? await Task.sleep(for: .seconds(10))

            // Check for sessions with pending restart intents that have gone idle/completed
            if let socket = permissionSocket, await socket.hasPendingRestarts() {
                for sid in await socket.pendingRestartSessionIds() {
                    let status = (await stateManager.getInfo(sid))?.status
                    if status == .idle || status == .completed {
                        if let intent = await socket.consumeRestartIntent(sessionId: sid) {
                            print("[Agent] Session \(sid.prefix(8)) stopped — executing plan restart")
                            await spawnPlanRestart(sessionId: sid, planContent: intent.planContent)
                        }
                    }
                }
                // Stale fallback: force-execute after 5 minutes
                for (sid, intent) in await socket.consumeStaleRestartIntents(olderThan: 300) {
                    print("[Agent] Stale restart intent for \(sid.prefix(8)) — force-spawning")
                    await spawnPlanRestart(sessionId: sid, planContent: intent.planContent)
                }
            }

            let timeoutEvents = await stateManager.checkTimeouts(
                idleTimeout: config.idleTimeout,
                completedTimeout: config.completedTimeout
            )
            for event in timeoutEvents {
                _ = await stateManager.processEvent(event)
                if let client = wsClient {
                    if event.eventType == .sessionCompleted {
                        if let msg = try? MessageEncoder.sessionCompleted(sessionId: event.sessionId) {
                            try? await client.send(msg)
                        }
                        // Remove completed session from persistent state
                        cleanupCompletedSession(event.sessionId)
                    }
                }
                print("[\(event.sessionId.prefix(8))] \(event.eventType.rawValue) (timeout)")
            }
        }
    }

    private func permissionStallLoop() async {
        while true {
            try? await Task.sleep(for: .seconds(5))
            let allSessions = await stateManager.allSessions()
            let activeSessions = Set(allSessions.filter { $0.value.status == .running }.map(\.key))
            let stallEvents = normalizer.checkPermissionStalls(stallTimeout: config.permissionStallTimeout, activeSessions: activeSessions)
            for event in stallEvents {
                _ = await stateManager.processEvent(event)
                if let client = wsClient {
                    do {
                        let msg = try MessageEncoder.sessionEvent(sessionId: event.sessionId, event: event)
                        try await client.send(msg)
                    } catch {
                        print("[WS] Failed to send permission stall: \(error.localizedDescription)")
                    }
                }
                print("[\(event.sessionId.prefix(8))] \(event.eventType.rawValue) (permission stall)")
            }
        }
    }

    // MARK: - Plan Restart

    private func spawnPlanRestart(sessionId: String, planContent: String) async {
        let projectPath = await sessionIndex.projectPath(for: sessionId) ?? ""
        guard !projectPath.isEmpty else {
            print("[Agent] Cannot restart \(sessionId.prefix(8)) — no project path")
            return
        }
        let planPath = BuildEnvironment.configDirectoryPath + "/plans/\(sessionId).md"
        let prompt = "Read and implement the plan at \(planPath). Begin immediately."
        do {
            let claudePath = try CommandValidator.resolveClaudePath()
            let args = ["-p", prompt, "--output-format", "json"]
            try CommandValidator.validate(args: [claudePath] + args)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: claudePath)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if FileManager.default.fileExists(atPath: projectPath) {
                process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
            }
            try process.run()
            print("[Agent] Spawned plan restart for \(sessionId.prefix(8)) in \(projectPath)")
        } catch {
            print("[Agent] Failed to spawn plan restart: \(error)")
        }
    }

    // MARK: - E2EE Content Encryption

    private func setupE2EEEncryptor(deviceId: String) async {
        let keychain = KeychainStore()
        guard let kaIdentity = try? KeyAgreementIdentity.load(from: keychain) else {
            print("[Agent] No KA identity — E2EE content encryption disabled")
            return
        }
        let token = config.authToken ?? (try? keychain.loadToken(forKey: "auth-token"))
        guard let token else { return }

        let api = APIClient(baseURL: config.httpBaseURL, token: token)
        let e2ee = E2EEncryption(identity: kaIdentity)

        // Log own KA key fingerprint
        let ownFingerprint = E2EEncryption.fingerprint(of: kaIdentity.publicKeyBase64)
        print("[Agent] Own KA key fingerprint: \(ownFingerprint)")

        // Collect ALL peer devices with KA public keys for multi-peer encryption
        var peerKeys: [String: String] = [:]
        var myKeyVersion = 1
        var peerCapabilities: [String: [String]] = [:]
        var peerKeyVersions: [String: Int] = [:]
        do {
            let devices = try await api.listDevices()
            let peerDevices = devices.filter { $0.id != deviceId }
            let peersWithoutKA = peerDevices.filter { $0.keyAgreementPublicKey == nil || $0.keyAgreementPublicKey?.isEmpty == true }
            if !peersWithoutKA.isEmpty {
                print("[Agent] \(peersWithoutKA.count) peer(s) missing KA key: \(peersWithoutKA.map { $0.id.prefix(8) }.joined(separator: ", "))")
            }
            for device in devices {
                if device.id == deviceId {
                    myKeyVersion = device.keyVersion ?? 1
                    continue
                }
                guard let peerKey = device.keyAgreementPublicKey, !peerKey.isEmpty else { continue }
                peerKeys[device.id] = peerKey
                if let caps = device.capabilities {
                    peerCapabilities[device.id] = caps
                }
                if let ver = device.keyVersion {
                    peerKeyVersions[device.id] = ver
                }
                let peerFingerprint = E2EEncryption.fingerprint(of: peerKey)
                let capsStr = (device.capabilities ?? []).joined(separator: ",")
                print("[Agent] Peer \(device.id.prefix(8)) KA fingerprint: \(peerFingerprint) (v\(device.keyVersion ?? 1)) caps=[\(capsStr)]")
            }
        } catch {
            print("[Agent] Failed to list devices for E2EE: \(error)")
        }

        guard !peerKeys.isEmpty else {
            print("[Agent] No peers with KA keys found — E2EE encryption disabled")
            return
        }

        let keyCache = SessionKeyCache(
            e2ee: e2ee, peerKeys: peerKeys, myKeyVersion: myKeyVersion, myDeviceId: deviceId,
            peerCapabilities: peerCapabilities, peerKeyVersions: peerKeyVersions
        )
        self.sessionKeyCache = keyCache

        // Seed the key cache with any ephemeral keys generated before E2EE was set up
        for (sessionId, ephKey) in ephemeralKeys {
            keyCache.setEphemeralKey(sessionId: sessionId, key: ephKey)
        }

        normalizer.contentEncryptor = { content, sessionId in
            let peerKeyMap = keyCache.getOrDeriveKeys(sessionId: sessionId)
            guard !peerKeyMap.isEmpty else { return nil }
            var encrypted: [String: String] = [:]
            for (peerDeviceId, key) in peerKeyMap {
                for (field, value) in content {
                    let prefixedKey = "\(peerDeviceId):\(field)"
                    if keyCache.usesV2(sessionId: sessionId, peerDeviceId: peerDeviceId) {
                        let receiverVer = keyCache.peerKeyVersion(peerDeviceId)
                        encrypted[prefixedKey] = try? E2EEncryption.encryptVersionedV2(
                            value, key: key, keyVersion: keyCache.myKeyVersion,
                            senderDeviceId: keyCache.myDeviceId, receiverKeyVersion: receiverVer
                        )
                    } else {
                        encrypted[prefixedKey] = try? E2EEncryption.encryptVersioned(
                            value, key: key, keyVersion: keyCache.myKeyVersion,
                            senderDeviceId: keyCache.myDeviceId
                        )
                    }
                }
            }
            return encrypted.isEmpty ? nil : encrypted
        }
        print("[Agent] E2EE content encryptor wired for \(peerKeys.count) peer(s) (own key v\(myKeyVersion)) — privacy mode: \(config.defaultPrivacyMode)")
    }

    // MARK: - Remote Permission Approval

    private func setupPermissionSocket(deviceId: String, client: WebSocketClient) async {
        let socket = PermissionSocket(
            timeout: config.remoteApprovalTimeout,
            deviceId: deviceId,
            acceptLegacyFallback: config.acceptLegacyPermissionFallback
        )
        self.permissionSocket = socket

        // When hook script sends a permission request, forward it via WS
        await socket.setOnPermissionRequest { [weak self] event in
            guard let self else { return }
            await self.forwardPermissionRequest(event)
        }

        // Derive permission signing keys from E2EE key agreement with iOS peers.
        await setupPermissionSigningKeys(socket: socket, deviceId: deviceId)

        do {
            // Install hook first (idempotent, handles missing socket gracefully with retry)
            let installer = HookInstaller(
                hookInstallDir: config.hookInstallPath,
                timeoutSeconds: config.remoteApprovalTimeout
            )
            try installer.install()

            // Start socket (creates /tmp/afk-agent.sock)
            try await socket.start()
        } catch {
            print("[Agent] Failed to start permission socket: \(error)")
        }
    }

    private func setupPermissionSigningKeys(socket: PermissionSocket, deviceId: String) async {
        let keychain = KeychainStore()
        guard let kaIdentity = try? KeyAgreementIdentity.load(from: keychain) else {
            print("[Agent] No KA identity — permission HMAC verification disabled")
            return
        }
        let token = config.authToken ?? (try? keychain.loadToken(forKey: "auth-token"))
        guard let token else { return }

        let api = APIClient(baseURL: config.httpBaseURL, token: token)
        let e2ee = E2EEncryption(identity: kaIdentity)

        do {
            let devices = try await api.listDevices()
            for device in devices where device.id != deviceId {
                // Skip devices without KA keys (not yet enrolled for E2EE)
                guard let peerKey = device.keyAgreementPublicKey, !peerKey.isEmpty else { continue }
                do {
                    let key = try e2ee.derivePermissionKey(
                        peerPublicKeyBase64: peerKey,
                        deviceId: deviceId
                    )
                    await socket.addPermissionSigningKey(key, for: device.id)
                } catch {
                    print("[Agent] Failed to derive permission key for peer \(device.id.prefix(8)): \(error)")
                }
            }
        } catch {
            print("[Agent] Failed to list devices for permission keys: \(error)")
        }
    }

    private func forwardPermissionRequest(_ event: PermissionSocket.PermissionRequestEvent) async {
        guard let client = wsClient else { return }
        do {
            let msg = try MessageEncoder.permissionRequest(event: event)
            try await client.send(msg)
            print("[Agent] Forwarded permission request for \(event.toolName) (nonce: \(event.nonce.prefix(8)))")
        } catch {
            print("[Agent] Failed to forward permission request: \(error)")
        }
    }

    func broadcastControlState() async {
        guard let client = wsClient, let deviceId = enrolledDeviceId else { return }
        let remoteApproval = !StatusBarController.isHookBypassed
        let autoPlanExit = StatusBarController.isPlanAutoExitEnabled
        if let msg = try? MessageEncoder.controlState(deviceID: deviceId, remoteApproval: remoteApproval, autoPlanExit: autoPlanExit) {
            try? await client.send(msg)
            print("[Agent] Broadcast control state: remoteApproval=\(remoteApproval) autoPlanExit=\(autoPlanExit)")
        }
    }

    private func handleWSMessage(_ msg: WSMessage) async {
        switch msg.type {
        case "permission.response":
            guard let socket = permissionSocket else { return }
            let decoder = JSONDecoder()
            guard let response = try? decoder.decode(
                PermissionSocket.PermissionResponsePayload.self,
                from: msg.payloadJSON
            ) else {
                print("[Agent] Failed to parse permission response")
                return
            }
            await socket.handleResponse(response)
        case "permission_mode":
            struct ModePayload: Codable { let mode: String }
            let decoder = JSONDecoder()
            guard let socket = permissionSocket,
                  let payload = try? decoder.decode(ModePayload.self, from: msg.payloadJSON),
                  let mode = PermissionSocket.PermissionMode(rawValue: payload.mode) else {
                print("[Agent] Failed to parse permission mode")
                return
            }
            await socket.setMode(mode)
            print("[Agent] Permission mode changed to: \(payload.mode)")
        case "server.privacy_mode":
            struct PrivacyModePayload: Codable { let mode: String }
            let decoder = JSONDecoder()
            if let payload = try? decoder.decode(PrivacyModePayload.self, from: msg.payloadJSON) {
                config.defaultPrivacyMode = payload.mode
                print("[Agent] Privacy mode updated to: \(payload.mode)")
            } else {
                print("[Agent] Failed to parse privacy mode update")
            }
        case "server.command.continue":
            await handleCommandContinue(msg)
        case "server.command.new":
            await handleCommandNew(msg)
        case "server.command.cancel":
            await handleCommandCancel(msg)
        case "server.plan.restart":
            await handlePlanRestart(msg)
        case "device.key_rotated":
            await handleDeviceKeyRotated(msg)
        case "server.todo.append":
            await handleTodoAppend(msg)
        case "server.todo.toggle":
            await handleTodoToggle(msg)
        case "agent_control":
            struct ControlPayload: Codable {
                let remoteApproval: Bool?
                let autoPlanExit: Bool?
            }
            let decoder = JSONDecoder()
            guard let payload = try? decoder.decode(ControlPayload.self, from: msg.payloadJSON) else {
                print("[Agent] Failed to parse agent control")
                return
            }
            if let sbc = statusBarController {
                DispatchQueue.main.async {
                    if let ra = payload.remoteApproval { sbc.setRemoteApproval(ra) }
                    if let ape = payload.autoPlanExit { sbc.setAutoPlanExit(ape) }
                }
            }
            // Small delay to let main-thread UI updates complete before reading state
            try? await Task.sleep(for: .milliseconds(50))
            await broadcastControlState()
        default:
            break
        }
    }

    private func handleCommandContinue(_ msg: WSMessage) async {
        guard let executor = commandExecutor, let client = wsClient else {
            print("[Agent] Command executor not configured")
            return
        }

        let decoder = JSONDecoder()
        guard let request = try? decoder.decode(
            CommandExecutor.CommandRequest.self,
            from: msg.payloadJSON
        ) else {
            print("[Agent] Failed to parse command request")
            return
        }

        // Look up project path from session index
        let projectPath = await sessionIndex.projectPath(for: request.sessionId) ?? ""

        Task {
            await executor.execute(
                request: request,
                verifier: commandVerifier,
                nonceStore: commandNonceStore,
                projectPath: projectPath,
                wsClient: client
            )
        }
    }

    private func handleCommandNew(_ msg: WSMessage) async {
        guard let executor = commandExecutor, let client = wsClient else {
            print("[Agent] Command executor not configured")
            return
        }

        let decoder = JSONDecoder()
        guard let request = try? decoder.decode(
            CommandExecutor.NewChatRequest.self,
            from: msg.payloadJSON
        ) else {
            print("[Agent] Failed to parse new chat request")
            return
        }

        let projectsPath = config.claudeProjectsPath
        let requestProjectPath = request.projectPath
        let sbc = statusBarController
        Task { [sessionIndex] in
            let newSessionId = await executor.executeNewChat(
                request: request,
                verifier: commandVerifier,
                nonceStore: commandNonceStore,
                wsClient: client
            )

            // Register the new session in SessionIndex so continue commands can find its project path.
            if let newSessionId {
                if let jsonlPath = Self.findJSONLFile(sessionId: newSessionId, under: projectsPath) {
                    let (_, projectPath) = await sessionIndex.register(filePath: jsonlPath)
                    print("[Agent] Registered new chat session \(newSessionId.prefix(8)) → \(projectPath)")
                } else {
                    print("[Agent] WARNING: Could not find JSONL for new session \(newSessionId.prefix(8))")
                }

                // Register in menu bar for easy resume
                if let sbc {
                    DispatchQueue.main.async {
                        sbc.addRemoteSession(sessionId: newSessionId, projectPath: requestProjectPath)
                    }
                }
            }
        }
    }

    /// Search for a JSONL file matching the given session ID under the claude projects directory.
    private static func findJSONLFile(sessionId: String, under projectsPath: String) -> String? {
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

    // MARK: - Todo Append

    private func handleTodoAppend(_ msg: WSMessage) async {
        struct TodoAppendPayload: Codable {
            let projectPath: String
            let text: String
        }
        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(TodoAppendPayload.self, from: msg.payloadJSON) else {
            print("[Agent] Failed to parse todo append payload")
            return
        }
        appendToTodoFile(projectPath: payload.projectPath, text: payload.text)
    }

    private nonisolated func appendToTodoFile(projectPath: String, text: String) {
        let todoPath = (projectPath as NSString).appendingPathComponent("todo.md")
        let fm = FileManager.default
        let line = "\n- [ ] \(text)\n"

        if fm.fileExists(atPath: todoPath) {
            guard let handle = FileHandle(forWritingAtPath: todoPath) else {
                print("[TodoWatcher] Failed to open \(todoPath) for writing")
                return
            }
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        } else {
            let content = "- [ ] \(text)\n"
            fm.createFile(atPath: todoPath, contents: content.data(using: .utf8))
        }
        print("[TodoWatcher] Appended item to \(todoPath): \(text)")
    }

    private func handleTodoToggle(_ msg: WSMessage) async {
        struct TodoTogglePayload: Codable {
            let projectPath: String
            let line: Int
            let checked: Bool
        }
        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(TodoTogglePayload.self, from: msg.payloadJSON) else {
            print("[Agent] Failed to parse todo toggle payload")
            return
        }
        toggleTodoLine(projectPath: payload.projectPath, line: payload.line, checked: payload.checked)
    }

    private nonisolated func toggleTodoLine(projectPath: String, line: Int, checked: Bool) {
        let todoPath = (projectPath as NSString).appendingPathComponent("todo.md")
        let fm = FileManager.default

        guard fm.fileExists(atPath: todoPath),
              let data = fm.contents(atPath: todoPath),
              let content = String(data: data, encoding: .utf8) else {
            print("[TodoWatcher] Cannot read \(todoPath) for toggle")
            return
        }

        var lines = content.components(separatedBy: "\n")
        let idx = line - 1 // line is 1-based
        guard idx >= 0, idx < lines.count else {
            print("[TodoWatcher] Line \(line) out of range in \(todoPath)")
            return
        }

        let currentLine = lines[idx]
        let newLine: String
        if checked {
            // Mark as checked: replace "- [ ]" with "- [x]"
            newLine = currentLine.replacingOccurrences(of: "- [ ] ", with: "- [x] ")
        } else {
            // Mark as unchecked: replace "- [x]" or "- [X]" with "- [ ]"
            newLine = currentLine
                .replacingOccurrences(of: "- [x] ", with: "- [ ] ")
                .replacingOccurrences(of: "- [X] ", with: "- [ ] ")
        }

        lines[idx] = newLine
        let updated = lines.joined(separator: "\n")
        try? updated.write(toFile: todoPath, atomically: true, encoding: .utf8)
        print("[TodoWatcher] Toggled line \(line) in \(todoPath): checked=\(checked)")
    }

    // MARK: - Key Fingerprint

    /// Compute a short hex fingerprint of a base64 public key for comparison and logging.
    private static func keyFingerprint(_ publicKeyBase64: String) -> String {
        guard let data = Data(base64Encoded: publicKeyBase64) else { return "invalid" }
        let hash = SHA256.hash(data: data)
        return Array(hash).prefix(4).map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    private func handlePlanRestart(_ msg: WSMessage) async {
        guard let executor = commandExecutor, let client = wsClient else {
            print("[Agent] Command executor not configured for plan restart")
            return
        }

        struct PlanRestartPayload: Codable {
            let sessionId: String
            let permissionMode: String
            let feedback: String?
        }

        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(PlanRestartPayload.self, from: msg.payloadJSON) else {
            print("[Agent] Failed to parse plan restart payload")
            return
        }

        let sessionId = payload.sessionId
        let mode = payload.permissionMode.isEmpty ? "acceptEdits" : payload.permissionMode

        // Read the saved plan file
        let planPath = BuildEnvironment.configDirectoryPath + "/plans/\(sessionId).md"

        guard FileManager.default.fileExists(atPath: planPath) else {
            print("[Agent] No plan file found at \(planPath)")
            if let failMsg = try? MessageEncoder.commandFailed(
                commandId: "plan-restart-\(sessionId)",
                sessionId: sessionId,
                error: "No saved plan found for session"
            ) {
                try? await client.send(failMsg)
            }
            return
        }

        // Look up project path from SessionIndex
        let projectPath = await sessionIndex.projectPath(for: sessionId) ?? ""
        guard !projectPath.isEmpty else {
            print("[Agent] No project path found for session \(sessionId)")
            if let failMsg = try? MessageEncoder.commandFailed(
                commandId: "plan-restart-\(sessionId)",
                sessionId: sessionId,
                error: "No project path found for session"
            ) {
                try? await client.send(failMsg)
            }
            return
        }

        // Build the prompt
        var prompt = "Read and implement the plan at \(planPath)"
        if let feedback = payload.feedback, !feedback.isEmpty {
            prompt += "\n\nUser feedback: \(feedback)"
        }

        // Build a synthetic NewChatRequest to leverage existing executor
        let nonce = UUID().uuidString
        let expiresAt = Int64(Date().timeIntervalSince1970) + 300
        let promptHash = prompt.data(using: .utf8).map {
            SHA256.hash(data: $0).compactMap { String(format: "%02x", $0) }.joined()
        } ?? ""

        let request = CommandExecutor.NewChatRequest(
            commandId: "plan-restart-\(sessionId)",
            projectPath: projectPath,
            prompt: prompt,
            promptHash: promptHash,
            useWorktree: false,
            worktreeName: nil,
            permissionMode: mode,
            nonce: nonce,
            expiresAt: expiresAt,
            signature: ""  // No verifier needed for plan restart
        )

        print("[Agent] Plan restart for session \(sessionId.prefix(8)) with mode=\(mode)")

        let projectsPath = config.claudeProjectsPath
        let sbc = statusBarController
        Task { [sessionIndex] in
            let newSessionId = await executor.executeNewChat(
                request: request,
                verifier: nil,  // Skip verification for plan restart
                nonceStore: commandNonceStore,
                wsClient: client
            )

            if let newSessionId {
                if let jsonlPath = Self.findJSONLFile(sessionId: newSessionId, under: projectsPath) {
                    let (_, projPath) = await sessionIndex.register(filePath: jsonlPath)
                    print("[Agent] Plan restart session \(newSessionId.prefix(8)) → \(projPath)")
                }

                // Register in menu bar for easy resume
                if let sbc {
                    DispatchQueue.main.async {
                        sbc.addRemoteSession(sessionId: newSessionId, projectPath: projectPath)
                    }
                }
            }
        }
    }

    private func handleCommandCancel(_ msg: WSMessage) async {
        struct CancelPayload: Codable {
            let commandId: String
        }
        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(CancelPayload.self, from: msg.payloadJSON),
              let executor = commandExecutor else { return }
        await executor.cancel(commandId: payload.commandId)
    }

    private func handleDeviceKeyRotated(_ msg: WSMessage) async {
        struct KeyRotatedPayload: Codable {
            let deviceId: String
            let keyVersion: Int
            let publicKey: String
        }
        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(KeyRotatedPayload.self, from: msg.payloadJSON) else {
            print("[Agent] Failed to parse device.key_rotated payload")
            return
        }
        let fingerprint = E2EEncryption.fingerprint(of: payload.publicKey)
        print("[Agent] Peer \(payload.deviceId.prefix(8)) rotated KA key to v\(payload.keyVersion) (fingerprint: \(fingerprint))")

        guard let deviceId = enrolledDeviceId else { return }

        // If our own key was rotated, archive the previous version before rebuilding
        if payload.deviceId == deviceId {
            let keychain = KeychainStore()
            let previousVersion = payload.keyVersion - 1
            if previousVersion >= 1 {
                KeyAgreementIdentity.archiveCurrentKey(version: previousVersion, keychain: keychain)
                KeyAgreementIdentity.pruneArchivedKeys(currentVersion: payload.keyVersion, keychain: keychain)
                print("[Agent] Archived own key v\(previousVersion) before rotation to v\(payload.keyVersion)")
            }
        }

        // Rebuild E2EE encryptor with fresh peer keys
        await setupE2EEEncryptor(deviceId: deviceId)

        // Refresh permission signing keys so HMAC verification uses the rotated key
        if let socket = permissionSocket {
            await setupPermissionSigningKeys(socket: socket, deviceId: deviceId)
        }
    }

    /// Send session.completed for all active sessions before exiting.
    private func gracefulShutdown() async {
        // Save state before shutdown so next run can resume
        agentState.save()
        print("[State] Saved state on shutdown")

        guard let client = wsClient else {
            print("[Agent] No WS client — skipping session cleanup")
            return
        }
        let sessions = await stateManager.allSessions()
        let active = sessions.filter { $0.value.status == .running || $0.value.status == .idle }
        for (sessionId, _) in active {
            if let msg = try? MessageEncoder.sessionCompleted(sessionId: sessionId) {
                try? await client.send(msg)
                print("[Agent] Sent session.completed for \(sessionId.prefix(8))")
            }
        }
        // Stop permission socket
        if let socket = permissionSocket {
            await socket.stop()
        }
        // Close disk queue
        diskQueue?.close()
        // Brief delay to let WS messages flush
        try? await Task.sleep(for: .milliseconds(500))
        print("[Agent] Graceful shutdown complete")
    }

    /// Save current state to disk (called periodically and on shutdown).
    private func saveState() {
        agentState.save()
    }

    // MARK: - State Cleanup

    /// Remove completed sessions from persistent state (called from timeoutLoop).
    private func cleanupCompletedSession(_ sessionId: String) {
        agentState.removeSession(sessionId)
    }
}
