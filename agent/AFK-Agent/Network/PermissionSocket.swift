//
//  PermissionSocket.swift
//  AFK-Agent
//
//  TODO: Split this file — extract WWUD handling into PermissionSocket+WWUD.swift,
//  hook response/parsing into PermissionSocket+HookIO.swift, and E2EE verification
//  into PermissionSocket+Verification.swift.
//
//  Unix domain socket server for receiving Claude Code PermissionRequest hooks.
//  The hook script connects, sends the permission JSON, and blocks until we
//  respond (or timeout). We forward the request to the iOS app via the backend
//  and resolve the continuation when the response arrives.
//
//  IMPORTANT: The accept loop and connection I/O run on a dedicated DispatchQueue
//  (not the actor) to avoid blocking the actor with POSIX blocking calls. Only
//  actor-isolated state (pending dict, callbacks) is accessed via the actor.
//

import Foundation
import CryptoKit
import OSLog

actor PermissionSocket {
    static var socketPath: String {
        BuildEnvironment.configDirectoryPath + "/run/agent.sock"
    }
    private let timeout: TimeInterval
    private let deviceId: String
    private let acceptLegacyFallback: Bool

    /// WWUD (What Would User Do?) engine for smart permission learning.
    private var wwudEngine: WWUDEngine?

    /// Callback to send WWUD auto-decision events to iOS for transparency.
    private var onWWUDAutoDecision: (@Sendable (WWUDAutoDecisionEvent) async -> Void)?

    func setWWUDEngine(_ engine: WWUDEngine) {
        self.wwudEngine = engine
    }

    func setOnWWUDAutoDecision(_ handler: @escaping @Sendable (WWUDAutoDecisionEvent) async -> Void) {
        self.onWWUDAutoDecision = handler
    }

    /// When true, check Claude settings.json allow/deny rules before forwarding to iOS.
    private var settingsRulesEnabled: Bool = false

    /// Resolves a session ID to its project path (bridges to SessionIndex).
    private var projectPathResolver: (@Sendable (String) async -> String?)?

    /// HMAC signing keys derived from E2EE key agreement, for verifying permission responses.
    /// Keyed by peer device ID (typically iOS devices).
    private var permissionSigningKeys: [String: SymmetricKey] = [:]

    private var fileDescriptor: Int32 = -1
    private var isRunning = false

    // MARK: - Permission Mode

    enum PermissionMode: String, Codable, Sendable {
        case ask
        case acceptEdits
        case plan
        case autoApprove
        case wwud
    }

    private var currentMode: PermissionMode = .ask

    // Track the last plan file path written per session (for ExitPlanMode injection)
    private var lastPlanFilePath: [String: String] = [:]

    // MARK: - Restart Intent (clear context + restart)

    struct RestartIntent: Sendable {
        let planContent: String
        let permissionMode: PermissionMode
        let recordedAt: Date
    }
    private var pendingRestarts: [String: RestartIntent] = [:]

    func recordRestartIntent(sessionId: String, planContent: String, permissionMode: PermissionMode = .acceptEdits) {
        let plansDir = BuildEnvironment.configDirectoryPath + "/plans"
        try? FileManager.default.createDirectory(atPath: plansDir, withIntermediateDirectories: true)
        let planPath = "\(plansDir)/\(sessionId).md"
        try? planContent.write(toFile: planPath, atomically: true, encoding: .utf8)
        pendingRestarts[sessionId] = RestartIntent(planContent: planContent, permissionMode: permissionMode, recordedAt: Date())
    }

    func consumeRestartIntent(sessionId: String) -> RestartIntent? {
        pendingRestarts.removeValue(forKey: sessionId)
    }

    func hasPendingRestarts() -> Bool { !pendingRestarts.isEmpty }
    func pendingRestartSessionIds() -> Set<String> { Set(pendingRestarts.keys) }

    func consumeStaleRestartIntents(olderThan age: TimeInterval) -> [(sessionId: String, intent: RestartIntent)] {
        let now = Date()
        let stale = pendingRestarts.filter { now.timeIntervalSince($0.value.recordedAt) > age }
        for key in stale.keys { pendingRestarts.removeValue(forKey: key) }
        return stale.map { ($0.key, $0.value) }
    }

    func setMode(_ mode: PermissionMode) {
        currentMode = mode
        AppLogger.permission.info("Mode changed to: \(mode.rawValue, privacy: .public)")
    }

    func getMode() -> PermissionMode { currentMode }

    func setPlanFilePath(sessionId: String, path: String) {
        lastPlanFilePath[sessionId] = path
    }

    func getPlanFilePath(sessionId: String) -> String? {
        lastPlanFilePath.removeValue(forKey: sessionId)
    }

    // Dedicated queue for blocking socket I/O (accept, read, write).
    private let ioQueue = DispatchQueue(label: "afk.permissionSocket.io")

    // Pending permission requests keyed by nonce — the continuation
    // is resumed when an iOS response arrives or the timeout fires.
    private var pending: [String: PendingRequest] = [:]

    struct PendingRequest {
        let nonce: String
        let expiresAt: Date
        let expiresAtUnix: Int64
        let challenge: String?
        let continuation: CheckedContinuation<PermissionDecision, Never>
        // WWUD context: stored so we can record the user's decision
        let toolName: String?
        let toolInput: [String: String]?
        let projectPath: String?
    }

    struct PermissionDecision: Sendable {
        let action: String   // "allow" or "deny"
    }

    // The payload we parse from the hook script's stdin (Claude Code PermissionRequest)
    struct HookInput: Codable {
        let tool_name: String?
        let tool_input: [String: AnyCodable]?
        let tool_use_id: String?
        let session_id: String?
        let permission_mode: String?
    }

    // Minimal type-erased Codable wrapper for tool_input values
    struct AnyCodable: Codable, Sendable {
        let value: Any

        init(_ value: Any) { self.value = value }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let s = try? container.decode(String.self) { value = s }
            else if let i = try? container.decode(Int.self) { value = i }
            else if let b = try? container.decode(Bool.self) { value = b }
            else if let d = try? container.decode(Double.self) { value = d }
            else if let arr = try? container.decode([AnyCodable].self) { value = arr.map(\.value) }
            else if let dict = try? container.decode([String: AnyCodable].self) { value = dict.mapValues(\.value) }
            else { value = "" }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            if let s = value as? String { try container.encode(s) }
            else if let i = value as? Int { try container.encode(i) }
            else if let b = value as? Bool { try container.encode(b) }
            else if let d = value as? Double { try container.encode(d) }
            else { try container.encode(stringValue) }
        }

        var stringValue: String {
            if let s = value as? String { return s }
            // Serialize complex values (arrays, dicts) to compact JSON
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
            return String(describing: value)
        }
    }

    // Event sent to backend/iOS
    struct PermissionRequestEvent: Codable, Sendable {
        let sessionId: String
        let toolName: String
        let toolInput: [String: String]
        let toolUseId: String
        let nonce: String
        let expiresAt: Int64
        let deviceId: String
        let challenge: String?
    }

    // Called by Agent when iOS responds via backend WS
    struct PermissionResponsePayload: Codable, Sendable {
        let nonce: String
        let action: String
        let signature: String
        let fallbackSignature: String?
    }

    // Callback to send permission request events over WS
    private var onPermissionRequest: (@Sendable (PermissionRequestEvent) async -> Void)?

    func setOnPermissionRequest(_ handler: @escaping @Sendable (PermissionRequestEvent) async -> Void) {
        self.onPermissionRequest = handler
    }

    // MARK: - Hook Envelope Events (Notification, Stop)

    /// Envelope wrapper for async hook messages (notification, stop).
    /// Async hooks wrap their payload in {"type":"...", "payload":{...}}.
    struct HookEnvelope: Codable {
        let type: String
        let payload: [String: AnyCodable]?
    }

    struct NotificationEvent: Sendable {
        let sessionId: String
        let notificationType: String
        let message: String?
    }

    struct StopEvent: Sendable {
        let sessionId: String
        let lastAssistantMessage: String?
    }

    private var onNotification: (@Sendable (NotificationEvent) async -> Void)?
    private var onStop: (@Sendable (StopEvent) async -> Void)?

    func setOnNotification(_ handler: @escaping @Sendable (NotificationEvent) async -> Void) {
        self.onNotification = handler
    }

    func setOnStop(_ handler: @escaping @Sendable (StopEvent) async -> Void) {
        self.onStop = handler
    }

    func setSettingsRulesEnabled(_ enabled: Bool) {
        self.settingsRulesEnabled = enabled
    }

    func setProjectPathResolver(_ resolver: @escaping @Sendable (String) async -> String?) {
        self.projectPathResolver = resolver
    }

    func getSettingsRulesEnabled() -> Bool { settingsRulesEnabled }

    func resolveProjectPath(sessionId: String) async -> String? {
        await projectPathResolver?(sessionId)
    }

    init(timeout: TimeInterval, deviceId: String, acceptLegacyFallback: Bool = true) {
        self.timeout = timeout
        self.deviceId = deviceId
        self.acceptLegacyFallback = acceptLegacyFallback
    }

    /// Add an HMAC signing key for a specific peer device.
    func addPermissionSigningKey(_ key: SymmetricKey, for peerDeviceId: String) {
        self.permissionSigningKeys[peerDeviceId] = key
        AppLogger.permission.debug("Cached permission signing key for peer \(peerDeviceId.prefix(8), privacy: .public)")
    }

    func start() throws {
        guard !isRunning else { return }

        // Remove stale socket file
        unlink(PermissionSocket.socketPath)

        fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw NSError(domain: "PermissionSocket", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create socket"])
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = PermissionSocket.socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(104)) { dest in
                for (i, byte) in pathBytes.enumerated() where i < 104 {
                    dest[i] = byte
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fileDescriptor, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fileDescriptor)
            throw NSError(domain: "PermissionSocket", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to bind: \(String(cString: strerror(errno)))"])
        }

        guard listen(fileDescriptor, 5) == 0 else {
            Darwin.close(fileDescriptor)
            throw NSError(domain: "PermissionSocket", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to listen"])
        }

        // Set socket permissions so only current user can connect
        chmod(PermissionSocket.socketPath, 0o600)

        isRunning = true
        AppLogger.permission.info("Listening on \(PermissionSocket.socketPath, privacy: .public)")

        // Run blocking accept loop on a dedicated GCD queue — NOT on the actor.
        let serverFD = fileDescriptor
        ioQueue.async { [weak self] in
            self?.acceptLoopSync(serverFD: serverFD)
        }
    }

    func stop() {
        isRunning = false
        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
        unlink(PermissionSocket.socketPath)
        // Cancel all pending requests
        for (_, req) in pending {
            req.continuation.resume(returning: PermissionDecision(action: "deny"))
        }
        pending.removeAll()
        AppLogger.permission.info("Stopped")
    }

    /// Called when iOS sends a permission response through the backend.
    /// Uses three-tier verification: E2EE HMAC > Challenge-Response > Legacy (transition only).
    func handleResponse(_ response: PermissionResponsePayload) {
        guard let req = pending[response.nonce] else {
            AppLogger.permission.warning("No pending request for nonce \(response.nonce.prefix(8), privacy: .public)")
            auditLog(nonce: response.nonce, action: response.action, note: "rejected:unknown_nonce")
            return
        }
        // Check expiry
        if Date() > req.expiresAt {
            AppLogger.permission.warning("Response for nonce \(response.nonce.prefix(8), privacy: .public) expired")
            pending.removeValue(forKey: response.nonce)
            req.continuation.resume(returning: PermissionDecision(action: "deny"))
            auditLog(nonce: response.nonce, action: "expired", note: "response_after_expiry")
            return
        }

        let message = "\(response.nonce)|\(response.action)|\(req.expiresAtUnix)"
        let messageData = Data(message.utf8)

        AppLogger.permission.debug("Verifying nonce \(response.nonce.prefix(8), privacy: .public): action=\(response.action, privacy: .public), sig=\(response.signature.prefix(16), privacy: .public)..., fallbackSig=\(response.fallbackSignature?.prefix(16) ?? "nil", privacy: .public), keys=\(self.permissionSigningKeys.count, privacy: .public), hasChallenge=\(req.challenge != nil, privacy: .public)")

        // Tier 1: E2EE HMAC — verify using E2EE-derived permission signing keys
        if !permissionSigningKeys.isEmpty {
            let e2eeVerified = permissionSigningKeys.values.contains { key in
                let mac = HMAC<SHA256>.authenticationCode(for: messageData, using: key)
                let hex = Data(mac).map { String(format: "%02x", $0) }.joined()
                return hex == response.signature
            }
            if e2eeVerified {
                pending.removeValue(forKey: response.nonce)
                req.continuation.resume(returning: PermissionDecision(action: response.action))
                recordWWUDFromResponse(req: req, action: response.action)
                auditLog(nonce: response.nonce, action: response.action, note: "accepted:e2ee_hmac")
                return
            }
            AppLogger.permission.warning("Tier 1 failed: E2EE signature mismatch (\(self.permissionSigningKeys.count, privacy: .public) keys checked)")
        } else {
            AppLogger.permission.debug("Tier 1 skipped: no E2EE signing keys cached")
        }

        // Tier 2: Challenge-Response — verify using ephemeral challenge-derived key
        if let challenge = req.challenge, let fallbackSig = response.fallbackSignature, !fallbackSig.isEmpty {
            let challengeKey = Self.deriveChallengeKey(challenge: challenge, deviceId: deviceId)
            let mac = HMAC<SHA256>.authenticationCode(for: messageData, using: challengeKey)
            let hex = Data(mac).map { String(format: "%02x", $0) }.joined()
            if hex == fallbackSig {
                pending.removeValue(forKey: response.nonce)
                req.continuation.resume(returning: PermissionDecision(action: response.action))
                recordWWUDFromResponse(req: req, action: response.action)
                auditLog(nonce: response.nonce, action: response.action, note: "accepted:challenge_response")
                return
            }
            AppLogger.permission.warning("Tier 2 failed: challenge-response signature mismatch")
        } else {
            AppLogger.permission.debug("Tier 2 skipped: challenge=\(req.challenge != nil, privacy: .public), fallbackSig=\(response.fallbackSignature != nil, privacy: .public)")
        }

        // Tier 3: Legacy deterministic fallback (transition period only)
        if self.acceptLegacyFallback {
            let fallbackData = "afk-permission-\(deviceId)".data(using: .utf8)!
            let legacyKey = SymmetricKey(data: SHA256.hash(data: fallbackData))
            let mac = HMAC<SHA256>.authenticationCode(for: messageData, using: legacyKey)
            let hex = Data(mac).map { String(format: "%02x", $0) }.joined()
            if hex == response.signature {
                AppLogger.permission.warning("Legacy fallback key accepted for nonce \(response.nonce.prefix(8), privacy: .public) — DEPRECATED")
                pending.removeValue(forKey: response.nonce)
                req.continuation.resume(returning: PermissionDecision(action: response.action))
                recordWWUDFromResponse(req: req, action: response.action)
                auditLog(nonce: response.nonce, action: response.action, note: "accepted:legacy_fallback_DEPRECATED")
                return
            }
        }

        // All tiers failed — deny
        AppLogger.permission.error("All HMAC verification tiers failed for nonce \(response.nonce.prefix(8), privacy: .public)")
        pending.removeValue(forKey: response.nonce)
        req.continuation.resume(returning: PermissionDecision(action: "deny"))
        auditLog(nonce: response.nonce, action: "deny", note: "rejected:all_hmac_failed")
    }

    /// Derive a symmetric key from a challenge and device ID for Tier 2 fallback verification.
    /// HKDF(SHA256(challenge), deviceId, "afk-permission-fallback-v2")
    nonisolated static func deriveChallengeKey(challenge: String, deviceId: String) -> SymmetricKey {
        let challengeData = Data(challenge.utf8)
        let inputKey = SHA256.hash(data: challengeData)
        let salt = deviceId.data(using: .utf8)!
        let info = "afk-permission-fallback-v2".data(using: .utf8)!
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: inputKey),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    // MARK: - Blocking I/O (runs on ioQueue, NOT actor)

    /// Synchronous accept loop that runs on a GCD queue.
    /// Blocking `accept()` calls are fine here — they don't block the actor.
    private nonisolated func acceptLoopSync(serverFD: Int32) {
        AppLogger.permission.info("Accept loop started on I/O queue")
        while true {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(serverFD, sockPtr, &clientLen)
                }
            }
            guard clientFD >= 0 else {
                // accept failed — socket was closed (stop() called) or error
                AppLogger.permission.info("Accept returned \(clientFD, privacy: .public), errno=\(errno, privacy: .public) — exiting accept loop")
                break
            }

            // Prevent SIGPIPE when writing to a closed socket
            var yes: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

            AppLogger.permission.debug("Accepted connection (fd=\(clientFD, privacy: .public))")

            // Handle each connection on a separate GCD thread to avoid blocking
            // the accept loop while waiting for iOS response.
            DispatchQueue.global().async { [weak self] in
                guard let self else {
                    Darwin.close(clientFD)
                    return
                }
                self.handleConnectionSync(clientFD)
            }
        }
        AppLogger.permission.info("Accept loop ended")
    }

    /// Handle a single hook connection synchronously.
    /// Reads the request, forwards to iOS via actor, waits for response, writes back.
    private nonisolated func handleConnectionSync(_ fd: Int32) {
        defer { Darwin.close(fd) }

        // Read all data from the hook script
        var data = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        while true {
            let bytesRead = read(fd, buf, bufSize)
            if bytesRead <= 0 { break }
            data.append(buf, count: bytesRead)
            if bytesRead < bufSize { break }
        }

        guard !data.isEmpty else {
            AppLogger.permission.warning("Empty data from hook")
            return
        }

        AppLogger.permission.debug("Read \(data.count, privacy: .public) bytes from hook")

        // Check for envelope messages from async hooks (notification, stop).
        // These wrap the Claude Code payload in {"type":"...", "payload":{...}}.
        // Only treat as envelope if it has a "payload" key — prevents misinterpreting
        // PreToolUse messages that happen to have a "type" field.
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(HookEnvelope.self, from: data),
           envelope.payload != nil {
            switch envelope.type {
            case "notification":
                let sessionId = envelope.payload?["session_id"]?.stringValue ?? "unknown"
                let notifType = envelope.payload?["notification_type"]?.stringValue ?? "unknown"
                let message = envelope.payload?["message"]?.stringValue
                AppLogger.permission.info("Notification hook: \(notifType, privacy: .public) (session: \(sessionId.prefix(8), privacy: .public))")
                let event = NotificationEvent(sessionId: sessionId, notificationType: notifType, message: message)
                Task { await self.onNotification?(event) }
                return  // fire-and-forget, no response needed

            case "stop":
                let sessionId = envelope.payload?["session_id"]?.stringValue ?? "unknown"
                let lastMsg = envelope.payload?["last_assistant_message"]?.stringValue
                let stopActive = envelope.payload?["stop_hook_active"]?.stringValue
                if stopActive == "true" || stopActive == "1" {
                    AppLogger.permission.debug("Stop hook: stop_hook_active=true, ignoring")
                    return
                }
                AppLogger.permission.info("Stop hook: session \(sessionId.prefix(8), privacy: .public) stopped")
                let event = StopEvent(sessionId: sessionId, lastAssistantMessage: lastMsg)
                Task { await self.onStop?(event) }
                return  // fire-and-forget, no response needed

            case "tool_used":
                Task { await self.handleToolUsed(envelope.payload) }
                return  // fire-and-forget, no response needed

            default:
                AppLogger.permission.warning("Unknown envelope type: \(envelope.type, privacy: .public)")
                return
            }
        }

        // Parse the hook input (standard PreToolUse format)
        guard let input = try? decoder.decode(HookInput.self, from: data) else {
            AppLogger.permission.error("Failed to parse hook input: \(String(data: data, encoding: .utf8) ?? "<binary>", privacy: .public)")
            return
        }

        let toolName = input.tool_name ?? "unknown"
        let toolUseId = input.tool_use_id ?? UUID().uuidString
        let sessionId = input.session_id ?? "unknown"

        // Build simplified tool input for evaluator
        var toolInputDisplay: [String: String] = [:]
        if let ti = input.tool_input {
            for (k, v) in ti {
                toolInputDisplay[k] = v.stringValue
            }
        }

        // Gather evaluator inputs via actor hop
        let semEval = DispatchSemaphore(value: 0)
        var mode: PermissionMode = .ask
        var settingsEnabled = false
        var resolvedProjectPath: String?
        var wwudEngineRef: WWUDEngine?
        Task {
            mode = await self.getMode()
            settingsEnabled = await self.getSettingsRulesEnabled()
            resolvedProjectPath = await self.resolveProjectPath(sessionId: sessionId)
            wwudEngineRef = await self.wwudEngine
            semEval.signal()
        }
        semEval.wait()

        // Delegate the decision to PermissionEvaluator (pure function, no I/O)
        let semDecision = DispatchSemaphore(value: 0)
        var evalDecision: PermissionEvaluator.Decision = .askRemote
        Task {
            evalDecision = await PermissionEvaluator.evaluate(
                toolName: toolName,
                toolInput: toolInputDisplay,
                sessionId: sessionId,
                claudePermissionMode: input.permission_mode,
                agentMode: mode,
                remoteApprovalBypassed: StatusBarController.isHookBypassed,
                settingsRulesEnabled: settingsEnabled,
                projectPath: resolvedProjectPath,
                wwudEngine: wwudEngineRef,
                filePath: input.tool_input?["file_path"]?.stringValue
            )
            semDecision.signal()
        }
        semDecision.wait()

        // Act on the evaluator's decision
        switch evalDecision {
        case .allow(let reason):
            AppLogger.permission.info("Evaluator allow (\(toolName, privacy: .public)): \(reason, privacy: .public)")
            writeHookResponse(fd: fd, decision: "allow", reason: reason)
            return

        case .deny(let reason):
            AppLogger.permission.info("Evaluator deny (\(toolName, privacy: .public)): \(reason, privacy: .public)")
            writeHookResponse(fd: fd, decision: "deny", reason: reason)
            return

        case .planAllowFile(let path):
            // Track plan file path for later ExitPlanMode injection
            let semPlan = DispatchSemaphore(value: 0)
            Task { await self.setPlanFilePath(sessionId: sessionId, path: path); semPlan.signal() }
            semPlan.wait()
            AppLogger.permission.info("Auto-approve plan file write: \(toolName, privacy: .public) -> \(path, privacy: .public)")
            return  // empty response → normal flow

        case .wwudAllow(let confidence, let pattern, let decisionId),
             .wwudDeny(let confidence, let pattern, let decisionId):
            let action = if case .wwudAllow = evalDecision { "allow" } else { "deny" }
            let verb = action == "allow" ? "auto-approved" : "auto-denied"
            let pct = Int(confidence * 100)
            AppLogger.permission.info("WWUD auto-\(action, privacy: .public) (\(toolName, privacy: .public)) — confidence: \(pct, privacy: .public)% pattern: \(pattern.description, privacy: .public)")
            writeHookResponse(fd: fd, decision: action, reason: "Smart Mode \(verb) (confidence: \(pct)%, pattern: \(pattern.description))")
            Task {
                await self.wwudEngine?.recordDecision(
                    toolName: toolName, toolInput: toolInputDisplay,
                    projectPath: resolvedProjectPath ?? "unknown",
                    action: action, source: "auto"
                )
                let event = WWUDAutoDecisionEvent(
                    sessionId: sessionId, toolName: toolName,
                    toolInputPreview: String(toolInputDisplay.values.joined(separator: " ").prefix(200)),
                    action: action, confidence: confidence,
                    patternDescription: pattern.description,
                    timestamp: Int64(Date().timeIntervalSince1970),
                    decisionId: decisionId
                )
                await self.onWWUDAutoDecision?(event)
            }
            auditLog(nonce: "wwud", sessionId: sessionId, toolName: toolName, toolInput: toolInputDisplay.description, action: action, note: "wwud:auto:\(pct)%")
            return

        case .askRemote:
            break // fall through to iOS forwarding
        }

        // Inject plan content into ExitPlanMode requests
        if toolName == "ExitPlanMode" {
            let semPlan = DispatchSemaphore(value: 0)
            var planPath: String?
            Task { planPath = await self.getPlanFilePath(sessionId: sessionId); semPlan.signal() }
            semPlan.wait()

            if let path = planPath,
               let data = FileManager.default.contents(atPath: path),
               let text = String(data: data, encoding: .utf8), !text.isEmpty {
                toolInputDisplay["plan"] = text
                AppLogger.permission.debug("Injected plan content (\(text.count, privacy: .public) chars) into ExitPlanMode")
            }
        }

        // Generate nonce and expiry
        let nonce = UUID().uuidString

        AppLogger.permission.info("Permission request: \(toolName, privacy: .public) (nonce: \(nonce.prefix(8), privacy: .public), session: \(sessionId.prefix(8), privacy: .public))")

        // Use a semaphore to bridge sync GCD context → async actor world.
        // The semaphore blocks THIS GCD thread (not the actor) until iOS responds.
        let semaphore = DispatchSemaphore(value: 0)
        var decision = PermissionDecision(action: "deny")

        // Hop to the actor to register the pending request and forward to iOS.
        Task {
            decision = await self.processPermissionRequest(
                nonce: nonce,
                toolName: toolName,
                toolInput: toolInputDisplay,
                toolUseId: toolUseId,
                sessionId: sessionId,
                wwudProjectPath: resolvedProjectPath
            )
            semaphore.signal()
        }

        // Block this GCD thread until the actor resolves (iOS responds or timeout).
        semaphore.wait()

        AppLogger.permission.info("Decision for \(nonce.prefix(8), privacy: .public): \(decision.action, privacy: .public)")

        // Handle AskUserQuestion answers from iOS — deny the tool with the answer
        // so Claude receives the user's selection without needing terminal input
        if decision.action.hasPrefix("answer:") {
            let answer = String(decision.action.dropFirst("answer:".count))
            AppLogger.permission.info("AskUserQuestion answered from iOS: \(answer, privacy: .public)")
            writeHookResponse(fd: fd, decision: "deny", reason: "User answered from AFK mobile: \(answer)")
            return
        }

        // Handle ExitPlanMode plan actions from iOS.
        // All accept actions use deny+restart: the session stops, agent saves the plan
        // to disk, and spawns a fresh `claude -p` session to implement it. This avoids
        // Claude Code's interactive "Ready to code?" TUI menu which can't be controlled
        // programmatically from a remote iOS app.
        // For reject/feedback: DENY so Claude stays in plan mode and reads the reason.
        if toolName == "ExitPlanMode", decision.action.hasPrefix("plan:") {
            let planAction = decision.action

            switch planAction {
            case "plan:accept-auto":
                let planText = toolInputDisplay["plan"] ?? ""
                let sem = DispatchSemaphore(value: 0)
                Task {
                    await self.recordRestartIntent(sessionId: sessionId, planContent: planText, permissionMode: .acceptEdits)
                    await self.setMode(.acceptEdits)
                    sem.signal()
                }
                sem.wait()
                writeHookResponse(fd: fd, decision: "deny", reason: "Plan approved via AFK mobile. Session restarting with clean context and auto-accept edits.", shouldContinue: false)
                AppLogger.permission.info("ExitPlanMode: accept + auto-accept (restart + acceptEdits)")

            case "plan:accept-manual":
                let planText = toolInputDisplay["plan"] ?? ""
                let sem = DispatchSemaphore(value: 0)
                Task {
                    await self.recordRestartIntent(sessionId: sessionId, planContent: planText, permissionMode: .ask)
                    await self.setMode(.ask)
                    sem.signal()
                }
                sem.wait()
                writeHookResponse(fd: fd, decision: "deny", reason: "Plan approved via AFK mobile. Session restarting with clean context.", shouldContinue: false)
                AppLogger.permission.info("ExitPlanMode: accept + manual (restart + ask)")

            case "plan:accept-clear-auto":
                let planText = toolInputDisplay["plan"] ?? ""
                let sem = DispatchSemaphore(value: 0)
                Task {
                    await self.recordRestartIntent(sessionId: sessionId, planContent: planText, permissionMode: .acceptEdits)
                    sem.signal()
                }
                sem.wait()
                writeHookResponse(fd: fd, decision: "deny", reason: "Plan approved by user from AFK mobile. Session will restart with clean context to implement the plan.", shouldContinue: false)
                AppLogger.permission.info("ExitPlanMode: accept + clear context (continue=false)")

            case "plan:reject":
                writeHookResponse(fd: fd, decision: "deny", reason: "Plan rejected by user from AFK mobile. Please revise the plan.")
                AppLogger.permission.info("ExitPlanMode: rejected")

            default:
                if planAction.hasPrefix("plan:feedback:") {
                    let feedback = String(planAction.dropFirst("plan:feedback:".count))
                    writeHookResponse(fd: fd, decision: "deny", reason: "User feedback from AFK mobile on the plan: \(feedback)")
                    AppLogger.permission.info("ExitPlanMode: feedback — \(feedback.prefix(80), privacy: .public)")
                } else {
                    writeHookResponse(fd: fd, decision: "deny", reason: "Unknown plan action from AFK mobile: \(planAction)")
                    AppLogger.permission.warning("ExitPlanMode: unknown — \(planAction, privacy: .public)")
                }
            }
            return
        }

        // Write Claude Code hook response JSON to the socket.
        let permissionDecision = decision.action == "allow" ? "allow" : "deny"
        let reason = decision.action == "allow" ? "Approved via AFK mobile" : "Denied via AFK mobile"
        writeHookResponse(fd: fd, decision: permissionDecision, reason: reason)
    }

    // MARK: - Actor-isolated request processing

    /// Register a pending request, forward to iOS, and wait for the response.
    /// This runs on the actor and properly manages the pending dictionary.
    private func processPermissionRequest(
        nonce: String,
        toolName: String,
        toolInput: [String: String],
        toolUseId: String,
        sessionId: String,
        wwudProjectPath: String? = nil
    ) async -> PermissionDecision {
        let expiresAt = Date().addingTimeInterval(timeout)
        let expiresAtUnix = Int64(expiresAt.timeIntervalSince1970)

        // Generate a random 32-byte challenge for Tier 2 fallback verification
        let challengeBytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let challenge = Data(challengeBytes).base64EncodedString()

        let event = PermissionRequestEvent(
            sessionId: sessionId,
            toolName: toolName,
            toolInput: toolInput,
            toolUseId: toolUseId,
            nonce: nonce,
            expiresAt: expiresAtUnix,
            deviceId: deviceId,
            challenge: challenge
        )

        // Send to backend/iOS
        await onPermissionRequest?(event)

        // Wait until iOS responds or timeout
        let decision = await withCheckedContinuation { (continuation: CheckedContinuation<PermissionDecision, Never>) in
            pending[nonce] = PendingRequest(
                nonce: nonce,
                expiresAt: expiresAt,
                expiresAtUnix: expiresAtUnix,
                challenge: challenge,
                continuation: continuation,
                toolName: toolName,
                toolInput: toolInput,
                projectPath: wwudProjectPath
            )

            // Schedule timeout
            Task { [weak self, nonce] in
                try? await Task.sleep(for: .seconds(self?.timeout ?? 120))
                guard let self else { return }
                await self.expireRequest(nonce: nonce)
            }
        }

        auditLog(
            nonce: nonce,
            sessionId: sessionId,
            toolName: toolName,
            toolInput: toolInput.description,
            action: decision.action,
            latency: Date().timeIntervalSince(expiresAt.addingTimeInterval(-timeout))
        )

        return decision
    }

    /// Handle a WWUD override from iOS (user correcting an auto-decision).
    func handleWWUDOverride(decisionId: String, correctedAction: String) {
        guard correctedAction == "allow" || correctedAction == "deny" else {
            AppLogger.wwud.warning("Invalid WWUD override action: \(correctedAction, privacy: .public)")
            return
        }
        guard let engine = wwudEngine else {
            AppLogger.wwud.warning("WWUD override received but no engine configured")
            return
        }
        Task {
            await engine.recordOverride(decisionId: decisionId, correctedAction: correctedAction)
        }
    }

    /// Record a user's permission decision in the WWUD engine (if active).
    private func recordWWUDFromResponse(req: PendingRequest, action: String) {
        guard currentMode == .wwud,
              let engine = wwudEngine,
              let toolName = req.toolName,
              let toolInput = req.toolInput else { return }
        // Only record allow/deny, not plan actions or answers
        guard action == "allow" || action == "deny" else { return }
        let projectPath = req.projectPath ?? "unknown"
        Task {
            await engine.recordDecision(
                toolName: toolName,
                toolInput: toolInput,
                projectPath: projectPath,
                action: action,
                source: "user"
            )
        }
    }

    /// Record a tool execution from the PostToolUse hook in the WWUD engine.
    /// This lets WWUD learn from terminal permission decisions (tools the user allowed locally).
    private func handleToolUsed(_ payload: [String: AnyCodable]?) {
        guard let engine = wwudEngine,
              let payload else { return }

        let toolName = payload["tool_name"]?.stringValue ?? "unknown"
        let sessionId = payload["session_id"]?.stringValue ?? "unknown"

        // Skip read-only tools — they're always auto-allowed and not meaningful for learning
        let readOnlyTools: Set<String> = ["Read", "Glob", "Grep", "LS", "LSP"]
        guard !readOnlyTools.contains(toolName) else { return }

        // Extract tool input as [String: String]
        var toolInput: [String: String] = [:]
        if let inputDict = payload["tool_input"]?.value as? [String: Any] {
            for (k, v) in inputDict {
                toolInput[k] = "\(v)"
            }
        }

        Task {
            let projectPath = await self.resolveProjectPath(sessionId: sessionId)
            await engine.recordDecision(
                toolName: toolName,
                toolInput: toolInput,
                projectPath: projectPath ?? "unknown",
                action: "allow",
                source: "terminal"
            )
            AppLogger.wwud.debug("Recorded terminal tool use: \(toolName, privacy: .public)")
        }
    }

    private func expireRequest(nonce: String) {
        guard let req = pending[nonce] else { return }
        pending.removeValue(forKey: nonce)
        req.continuation.resume(returning: PermissionDecision(action: "deny"))
        AppLogger.permission.warning("Request \(nonce.prefix(8), privacy: .public) expired")
    }

    // MARK: - Hook Response Helper

    /// Write a Claude Code hook response to the socket file descriptor.
    /// Appends a newline so the reader can detect a complete response.
    private nonisolated func writeHookResponse(fd: Int32, decision: String, reason: String, shouldContinue: Bool? = nil) {
        var response: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": decision,
                "permissionDecisionReason": reason
            ]
        ]
        if let shouldContinue {
            response["continue"] = shouldContinue
        }
        guard var data = try? JSONSerialization.data(withJSONObject: response) else {
            AppLogger.permission.error("Failed to serialize hook response JSON")
            return
        }
        // Append newline delimiter so the hook script can detect response completion
        data.append(contentsOf: [0x0A]) // '\n'

        let written = data.withUnsafeBytes { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return write(fd, base, data.count)
        }
        if written < 0 {
            let err = errno
            AppLogger.permission.error("write() failed — errno=\(err, privacy: .public) (\(String(cString: strerror(err)), privacy: .public)). Hook script likely disconnected before response was ready.")
        } else if written < data.count {
            AppLogger.permission.warning("Partial write — \(written, privacy: .public)/\(data.count, privacy: .public) bytes. Hook script may not receive full response.")
        } else {
            AppLogger.permission.debug("Wrote \(written, privacy: .public) byte \(decision, privacy: .public) response")
        }
    }

    // MARK: - Audit Log

    private nonisolated func auditLog(
        nonce: String,
        sessionId: String = "",
        toolName: String = "",
        toolInput: String = "",
        action: String,
        latency: TimeInterval = 0,
        note: String = ""
    ) {
        let logDir = BuildEnvironment.configDirectoryPath
        let logPath = "\(logDir)/permission-audit.log"

        // Ensure directory exists
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let inputPreview = String(toolInput.prefix(100))
        let entry = "\(timestamp) | session=\(sessionId.prefix(8)) | tool=\(toolName) | input=\(inputPreview) | nonce=\(nonce.prefix(8)) | action=\(action) | latency=\(String(format: "%.1fs", latency))\(note.isEmpty ? "" : " | note=\(note)")\n"

        if let data = entry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
    }
}
