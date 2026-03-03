//
//  PermissionSocket.swift
//  AFK-Agent
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
    }

    private var currentMode: PermissionMode = .ask

    // Track the last plan file path written per session (for ExitPlanMode injection)
    private var lastPlanFilePath: [String: String] = [:]

    // MARK: - Restart Intent (clear context + restart)

    struct RestartIntent: Sendable {
        let planContent: String
        let recordedAt: Date
    }
    private var pendingRestarts: [String: RestartIntent] = [:]

    func recordRestartIntent(sessionId: String, planContent: String) {
        let plansDir = BuildEnvironment.configDirectoryPath + "/plans"
        try? FileManager.default.createDirectory(atPath: plansDir, withIntermediateDirectories: true)
        let planPath = "\(plansDir)/\(sessionId).md"
        try? planContent.write(toFile: planPath, atomically: true, encoding: .utf8)
        pendingRestarts[sessionId] = RestartIntent(planContent: planContent, recordedAt: Date())
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

        // Remove stale plan-approved flag files from previous runs
        Self.cleanStalePlanFlags()

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
        // Clean stale plan-approved flag files
        Self.cleanStalePlanFlags()
        AppLogger.permission.info("Stopped")
    }

    /// Remove leftover plan-approved-* flag files from the run directory.
    nonisolated static func cleanStalePlanFlags() {
        let runDir = BuildEnvironment.configDirectoryPath + "/run"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: runDir) {
            for f in files where f.hasPrefix("plan-approved-") {
                try? FileManager.default.removeItem(atPath: "\(runDir)/\(f)")
            }
        }
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

        // Parse the hook input
        let decoder = JSONDecoder()
        guard let input = try? decoder.decode(HookInput.self, from: data) else {
            AppLogger.permission.error("Failed to parse hook input: \(String(data: data, encoding: .utf8) ?? "<binary>", privacy: .public)")
            return
        }

        let toolName = input.tool_name ?? "unknown"
        let toolUseId = input.tool_use_id ?? UUID().uuidString
        let sessionId = input.session_id ?? "unknown"

        // Local bypass — hook disabled from menu bar, let Claude Code handle permissions normally
        if StatusBarController.isHookBypassed {
            AppLogger.permission.debug("Hook bypassed — \(toolName, privacy: .public)")
            return  // empty response → Claude Code uses normal permission flow
        }

        // Fast path: safe/read-only tools don't need mobile approval.
        // Return empty (no output) so Claude Code proceeds with its normal flow.
        let safeTools: Set<String> = [
            "Read", "Glob", "Grep", "WebFetch", "WebSearch",
            "Task", "TodoRead", "TodoWrite",
            "TaskCreate", "TaskUpdate", "TaskList", "TaskGet",
            "EnterPlanMode", "NotebookRead"
        ]
        if safeTools.contains(toolName) {
            AppLogger.permission.debug("Auto-pass safe tool: \(toolName, privacy: .public)")
            return  // empty response → Claude Code uses normal permission flow
        }

        // Check permission mode — auto-handle based on current mode
        let semaphoreMode = DispatchSemaphore(value: 0)
        var mode: PermissionMode = .ask
        Task { mode = await self.getMode(); semaphoreMode.signal() }
        semaphoreMode.wait()

        let editTools: Set<String> = ["Write", "Edit", "NotebookEdit", "MultiEdit"]
        let unsafeTools: Set<String> = ["Write", "Edit", "NotebookEdit", "MultiEdit", "Bash"]

        switch mode {
        case .autoApprove:
            AppLogger.permission.info("Auto-approve (\(toolName, privacy: .public)) — mode: autoApprove")
            writeHookResponse(fd: fd, decision: "allow", reason: "Auto-approved via AFK permission mode")
            return
        case .acceptEdits where editTools.contains(toolName):
            AppLogger.permission.info("Auto-approve edit (\(toolName, privacy: .public)) — mode: acceptEdits")
            writeHookResponse(fd: fd, decision: "allow", reason: "Edit auto-approved via AFK Accept Edits mode")
            return
        case .plan where unsafeTools.contains(toolName):
            // Allow writes to plan files so Claude can save the plan
            if let filePath = input.tool_input?["file_path"]?.stringValue,
               filePath.contains("/.claude/plans/") {
                // Track plan file path for later ExitPlanMode injection
                let semPlan = DispatchSemaphore(value: 0)
                Task { await self.setPlanFilePath(sessionId: sessionId, path: filePath); semPlan.signal() }
                semPlan.wait()
                AppLogger.permission.info("Auto-approve plan file write: \(toolName, privacy: .public) -> \(filePath, privacy: .public)")
                return  // empty response → normal flow
            }
            AppLogger.permission.info("Auto-deny unsafe (\(toolName, privacy: .public)) — mode: plan")
            writeHookResponse(fd: fd, decision: "deny", reason: "Denied via AFK Plan Mode (read-only)")
            return
        default:
            break // fall through to existing iOS forwarding logic
        }

        // Build simplified tool input for display
        var toolInputDisplay: [String: String] = [:]
        if let ti = input.tool_input {
            for (k, v) in ti {
                toolInputDisplay[k] = v.stringValue
            }
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
                sessionId: sessionId
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
        // For accept actions: ALLOW ExitPlanMode so the tool succeeds, then PostToolUse
        // hook injects Shift+Tab to complete the UI toggle. Drop a flag file for PostToolUse.
        // For reject/feedback: DENY so Claude stays in plan mode and reads the reason.
        // For clear-context: DENY with continue=false, record restart intent for Agent.
        if toolName == "ExitPlanMode", decision.action.hasPrefix("plan:") {
            let planAction = decision.action

            switch planAction {
            case "plan:accept-auto":
                // Allow ExitPlanMode → PostToolUse will inject Shift+Tab
                writeHookResponse(fd: fd, decision: "allow", reason: "Plan approved by user from AFK mobile. Auto-accept edits. Proceed with implementation.")
                createPlanApprovedFlag(sessionId: sessionId)
                let sem = DispatchSemaphore(value: 0)
                Task { await self.setMode(.acceptEdits); sem.signal() }
                sem.wait()
                AppLogger.permission.info("ExitPlanMode: accept + auto-accept (mode → acceptEdits)")

            case "plan:accept-manual":
                // Allow ExitPlanMode → PostToolUse will inject Shift+Tab
                writeHookResponse(fd: fd, decision: "allow", reason: "Plan approved by user from AFK mobile. Manually approve each edit.")
                createPlanApprovedFlag(sessionId: sessionId)
                let sem = DispatchSemaphore(value: 0)
                Task { await self.setMode(.ask); sem.signal() }
                sem.wait()
                AppLogger.permission.info("ExitPlanMode: accept + manual (mode → ask)")

            case "plan:accept-clear-auto":
                // Deny — session will stop, Agent spawns fresh session with the plan
                let planText = toolInputDisplay["plan"] ?? ""
                let sem = DispatchSemaphore(value: 0)
                Task { await self.recordRestartIntent(sessionId: sessionId, planContent: planText); sem.signal() }
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

        // ExitPlanMode with plain "allow" (backwards compat): same flag + mode switch
        if toolName == "ExitPlanMode" && decision.action == "allow" {
            createPlanApprovedFlag(sessionId: sessionId)
            let sem = DispatchSemaphore(value: 0)
            Task {
                if await self.getMode() == .plan { await self.setMode(.acceptEdits) }
                sem.signal()
            }
            sem.wait()
        }
    }

    /// Create a flag file for the PostToolUse hook to detect, and schedule cleanup.
    private nonisolated func createPlanApprovedFlag(sessionId: String) {
        let flagPath = BuildEnvironment.configDirectoryPath + "/run/plan-approved-\(sessionId)"
        FileManager.default.createFile(atPath: flagPath, contents: nil)
        // Clean stale flag after 10s if PostToolUse didn't consume it
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            try? FileManager.default.removeItem(atPath: flagPath)
        }
    }

    // MARK: - Actor-isolated request processing

    /// Register a pending request, forward to iOS, and wait for the response.
    /// This runs on the actor and properly manages the pending dictionary.
    private func processPermissionRequest(
        nonce: String,
        toolName: String,
        toolInput: [String: String],
        toolUseId: String,
        sessionId: String
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
                continuation: continuation
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
