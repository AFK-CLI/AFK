import Foundation
import CryptoKit

struct EventPagination {
    var minSeq: Int = 0
    var hasMore: Bool = false
    var isLoading: Bool = false
}

struct AgentControlState {
    var remoteApproval: Bool
    var autoPlanExit: Bool
}

@Observable
final class SessionStore {
    var sessions: [Session] = []
    var events: [String: [SessionEvent]] = [:]
    var isLoading = false
    var isOffline = false
    var pendingPermissions: [String: PermissionRequest] = [:]  // keyed by nonce
    private(set) var queuedPermissions: [PermissionRequest] = []
    private var permissionQueueTimers: [String: Task<Void, Never>] = [:]
    var eventPagination: [String: EventPagination] = [:]
    var liveActivityManager: LiveActivityManager?
    /// Session IDs the user is currently viewing — events are reloaded on WS reconnect
    var viewingSessionIds: Set<String> = []
    var permissionModes: [String: String] = [:]  // deviceId -> mode
    var agentControlStates: [String: AgentControlState] = [:]  // deviceId -> control state

    /// E2EE: cached session keys (sessionId -> SymmetricKey)
    private var e2eeSessionKeys: [String: SymmetricKey] = [:]
    /// E2EE: cached historical session keys ("sessionId:v:version" -> SymmetricKey)
    private var historicalSessionKeys: [String: SymmetricKey] = [:]
    /// E2EE: cached permission signing keys (deviceId -> SymmetricKey)
    private var permissionSigningKeys: [String: SymmetricKey] = [:]
    /// E2EE: device KA public keys (deviceId -> base64 public key)
    private(set) var deviceKAKeys: [String: String] = [:]
    /// E2EE: tracks whether each session uses v1 or v2 key derivation
    private var sessionKeyVersions: [String: Int] = [:]
    /// E2EE: maps sessionId -> peer device ID (for looking up peer key version in v2 encryption)
    private var sessionPeerDeviceId: [String: String] = [:]
    private var e2eeService: E2EEService?
    /// This iOS device's ID — used to find device-prefixed E2EE content keys
    var myDeviceId: String?
    /// This iOS device's key version — used for versioned wire format
    var myKeyVersion: Int?

    private let apiClient: APIClient
    private let wsService: WebSocketService
    private let localStore: LocalStore
    private let syncService: SyncService

    init(apiClient: APIClient, wsService: WebSocketService, localStore: LocalStore, syncService: SyncService) {
        self.apiClient = apiClient
        self.wsService = wsService
        self.localStore = localStore
        self.syncService = syncService
        self.e2eeService = E2EEService()
        self.myDeviceId = BuildEnvironment.userDefaults.string(forKey: "afk_ios_device_id")
        self.myKeyVersion = BuildEnvironment.userDefaults.object(forKey: "afk_my_key_version") as? Int
        loadCachedSessions()
        setupWebSocketHandlers()
        setupE2EEDecryptor()
    }

    /// Set up content decryptor on the WS service for E2EE.
    private func setupE2EEDecryptor() {
        wsService.contentDecryptor = { [weak self] (content, sessionId) in
            guard let self else {
                return Self.sanitizeCiphertext(content)
            }
            let extracted = Self.extractMyContent(content, myDeviceId: self.myDeviceId)
            guard !extracted.isEmpty else {
                return Self.sanitizeCiphertext(content)
            }

            // Try V1→V2 key upgrade if ephemeral key became available since last derivation
            if let session = self.sessions.first(where: { $0.id == sessionId }) {
                self.ensureE2EEKey(for: session)
            }

            guard let key = self.e2eeSessionKeys[sessionId] else {
                print("[E2EE] No session key for \(sessionId.prefix(8)), sanitizing \(extracted.count) field(s)")
                return Self.sanitizeCiphertext(extracted)
            }

            // Decrypt each field individually, falling back to historical key cache
            var result: [String: String] = [:]
            var hasEncrypted = false
            for (field, value) in extracted {
                let blob = E2EEService.parseEncryptedValue(value)

                // 1. Try primary session key
                if let plaintext = try? E2EEService.decrypt(blob.ciphertext, key: key) {
                    result[field] = plaintext
                    continue
                }

                // 2. Try historical keys from cache (populated by prior async fallbacks)
                if let senderVer = blob.senderKeyVersion {
                    var found = false
                    for suffix in ["", ":v2"] {
                        let cacheKey = "\(sessionId):v:\(senderVer)\(suffix)"
                        if let histKey = self.historicalSessionKeys[cacheKey],
                           let plaintext = try? E2EEService.decrypt(blob.ciphertext, key: histKey) {
                            result[field] = plaintext
                            found = true
                            break
                        }
                    }
                    if found { continue }
                }

                // 3. Failed — if it looks like ciphertext, mark as encrypted (async fallback will handle it).
                //    Otherwise keep the original value (it's likely unencrypted plain text).
                if blob.version != nil || E2EEService.looksLikeCiphertext(blob.ciphertext) {
                    result[field] = "[encrypted]"
                    hasEncrypted = true
                } else {
                    result[field] = value
                }
            }

            if hasEncrypted {
                print("[E2EE] WS decryptor: \(result.filter { $0.value == "[encrypted]" }.count) field(s) still encrypted for \(sessionId.prefix(8))")
            }
            return result
        }
    }

    /// Decrypt content fields, handling both multi-peer (device-prefixed) and legacy (un-prefixed) formats.
    /// Supports both versioned (e1:...) and legacy (raw base64) ciphertext values.
    private static func decryptContentFields(_ content: [String: String], key: SymmetricKey, myDeviceId: String?) -> [String: String] {
        // Try multi-peer format first: look for keys prefixed with our device ID
        let extracted = extractMyContent(content, myDeviceId: myDeviceId)
        do {
            return try E2EEService.decryptContentVersioned(extracted, key: key)
        } catch {
            print("[E2EE] Decryption failed: \(error)")
            return sanitizeCiphertext(extracted)
        }
    }

    /// Extract content fields for this device from multi-peer format.
    /// Multi-peer: keys are "deviceId:fieldName" — extract fields matching our device ID.
    /// Legacy: keys are plain "fieldName" — returned as-is.
    private static func extractMyContent(_ content: [String: String], myDeviceId: String?) -> [String: String] {
        guard let myId = myDeviceId else { return content }
        let prefix = "\(myId):"

        // Check if any key is prefixed with our device ID (multi-peer format)
        guard content.keys.contains(where: { $0.hasPrefix(prefix) }) else {
            // No keys for us — could be legacy format or content for other devices only
            // If keys look like "uuid:field" but not ours, return empty to avoid showing wrong device's ciphertext
            let looksMultiPeer = content.keys.contains { key in
                let colonIdx = key.firstIndex(of: ":")
                return colonIdx != nil && key.distance(from: key.startIndex, to: colonIdx!) >= 36
            }
            return looksMultiPeer ? [:] : content
        }

        // Extract fields matching our device ID, stripping the prefix
        var myContent: [String: String] = [:]
        for (k, v) in content where k.hasPrefix(prefix) {
            let fieldName = String(k.dropFirst(prefix.count))
            myContent[fieldName] = v
        }
        return myContent
    }

    /// Replace ciphertext-looking values with "[encrypted]" to avoid showing raw base64 in the UI.
    /// Detects legacy (raw base64), v1 (e1:...), and v2 (e2:...) ciphertext formats.
    private static func sanitizeCiphertext(_ content: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (k, v) in content {
            if v.hasPrefix("e1:") || v.hasPrefix("e2:") || E2EEService.looksLikeCiphertext(v) {
                result[k] = "[encrypted]"
            } else {
                result[k] = v
            }
        }
        return result
    }

    /// Reinitialize the E2EE service with a fresh key pair.
    /// Call this when the own device key changes (e.g., key regenerated from Keychain loss).
    /// Clears all cached session keys since they were derived from the old private key.
    func reinitializeE2EE() {
        let oldFingerprint = e2eeService.map { E2EEService.fingerprint(of: $0.publicKeyBase64) } ?? "none"
        e2eeService = E2EEService()
        let newFingerprint = e2eeService.map { E2EEService.fingerprint(of: $0.publicKeyBase64) } ?? "none"
        print("[E2EE] Reinitialized E2EE service: \(oldFingerprint) -> \(newFingerprint)")

        // Clear ALL derived keys — they were computed from the old private key
        let sessionKeyCount = e2eeSessionKeys.count
        let historicalKeyCount = historicalSessionKeys.count
        let permKeyCount = permissionSigningKeys.count
        e2eeSessionKeys.removeAll()
        historicalSessionKeys.removeAll()
        permissionSigningKeys.removeAll()
        sessionKeyVersions.removeAll()
        sessionPeerDeviceId.removeAll()
        print("[E2EE] Cleared \(sessionKeyCount) session keys, \(historicalKeyCount) historical keys, \(permKeyCount) permission keys")

        // Re-wire the content decryptor
        setupE2EEDecryptor()
    }

    /// Cache an E2EE session key for a device's session.
    func cacheE2EEKey(for sessionId: String, peerPublicKeyBase64: String) {
        guard let service = e2eeService else { return }
        do {
            let key = try service.sessionKey(peerPublicKeyBase64: peerPublicKeyBase64, sessionId: sessionId)
            e2eeSessionKeys[sessionId] = key
            let fingerprint = E2EEService.fingerprint(of: peerPublicKeyBase64)
            print("[E2EE] Cached session key for \(sessionId.prefix(8)) (peer \(fingerprint))")
        } catch {
            print("[E2EE] Failed to derive session key: \(error)")
        }
    }

    /// Cache an E2EE v2 (forward-secret) session key using both long-term and ephemeral peer keys.
    func cacheE2EEKeyV2(for sessionId: String, peerPublicKeyBase64: String, ephemeralPublicKeyBase64: String) {
        guard let service = e2eeService else { return }
        do {
            let key = try service.deriveSessionKeyV2(
                peerPublicKeyBase64: peerPublicKeyBase64,
                ephemeralPublicKeyBase64: ephemeralPublicKeyBase64,
                sessionId: sessionId
            )
            e2eeSessionKeys[sessionId] = key
            let fingerprint = E2EEService.fingerprint(of: peerPublicKeyBase64)
            let ephFingerprint = E2EEService.fingerprint(of: ephemeralPublicKeyBase64)
            print("[E2EE] Cached v2 session key for \(sessionId.prefix(8)) (peer LT \(fingerprint), eph \(ephFingerprint))")
        } catch {
            print("[E2EE] Failed to derive v2 session key for \(sessionId): \(error)")
        }
    }

    /// Encrypt a prompt before sending as a remote continue command.
    /// Uses v2 wire format (e2:...) for forward-secret sessions, v1 (e1:...) otherwise.
    func encryptPrompt(_ prompt: String, sessionId: String) -> String? {
        guard let key = e2eeSessionKeys[sessionId] else { return nil }
        if let deviceId = myDeviceId {
            let keyVersion = myKeyVersion ?? 1
            if sessionKeyVersions[sessionId] == 2 {
                // V2: include receiver's key version so agent knows which ephemeral key was used
                let receiverKeyVersion = 1
                return try? E2EEService.encryptVersionedV2(
                    prompt, key: key, keyVersion: keyVersion,
                    senderDeviceId: deviceId, receiverKeyVersion: receiverKeyVersion
                )
            }
            return try? E2EEService.encryptVersioned(prompt, key: key, keyVersion: keyVersion, senderDeviceId: deviceId)
        }
        return try? E2EEService.encrypt(prompt, key: key)
    }

    /// Cache a device's KA public key for E2EE key derivation.
    func cacheDeviceKey(deviceId: String, publicKey: String) {
        deviceKAKeys[deviceId] = publicKey
        let fingerprint = E2EEService.fingerprint(of: publicKey)
        print("[E2EE] Cached device KA key for \(deviceId.prefix(8)) (fingerprint \(fingerprint))")

        // Flush any queued permission requests now that we have the KA key
        flushQueuedPermissions(for: deviceId)
    }

    /// Derive and cache the E2EE session key for a given session if not already cached.
    /// Uses v2 (forward-secret) derivation when the session has an ephemeral key, otherwise v1.
    /// Returns true if a key was derived (or was already cached), false otherwise.
    @discardableResult
    func ensureE2EEKey(for session: Session) -> Bool {
        // If a key is already cached, check if it needs upgrading from V1 to V2.
        // This happens when the session.update with ephemeralPublicKey arrives after
        // the initial key was derived (e.g., first update had no ephemeral key).
        if e2eeSessionKeys[session.id] != nil {
            let hasEphKey = session.ephemeralPublicKey != nil && !session.ephemeralPublicKey!.isEmpty
            let cachedVersion = sessionKeyVersions[session.id] ?? 1
            if hasEphKey && cachedVersion < 2 {
                // Upgrade: invalidate V1 key so we re-derive as V2 below
                e2eeSessionKeys.removeValue(forKey: session.id)
                print("[E2EE] Upgrading session \(session.id.prefix(8)) key from v1 → v2 (ephemeral key now available)")
            } else {
                return true
            }
        }
        guard let peerKey = deviceKAKeys[session.deviceId] else {
            let availableIds = deviceKAKeys.keys.map { $0.prefix(8) }.joined(separator: ", ")
            print("[E2EE] Warning: no KA key for device \(session.deviceId.prefix(8)) (session \(session.id.prefix(8))). Available devices: [\(availableIds)]")
            return false
        }
        sessionPeerDeviceId[session.id] = session.deviceId
        if let ephKey = session.ephemeralPublicKey, !ephKey.isEmpty {
            // V2: forward-secret key using ephemeral + long-term
            cacheE2EEKeyV2(for: session.id, peerPublicKeyBase64: peerKey, ephemeralPublicKeyBase64: ephKey)
            sessionKeyVersions[session.id] = 2
        } else {
            // V1: long-term only
            cacheE2EEKey(for: session.id, peerPublicKeyBase64: peerKey)
            sessionKeyVersions[session.id] = 1
        }
        return true
    }

    /// Decrypt event content fields using the cached session key.
    /// Handles both multi-peer (device-prefixed) and legacy (un-prefixed) content formats.
    /// When no key exists, sanitize ciphertext-looking values to "[encrypted]".
    func decryptEvents(_ events: [SessionEvent], sessionId: String) -> [SessionEvent] {
        let key = e2eeSessionKeys[sessionId]
        let deviceId = myDeviceId
        return events.map { event in
            guard let content = event.content, !content.isEmpty else { return event }
            let extracted = Self.extractMyContent(content, myDeviceId: deviceId)
            if let key {
                let decrypted = Self.decryptContentFields(extracted, key: key, myDeviceId: deviceId)
                return SessionEvent(
                    id: event.id,
                    sessionId: event.sessionId,
                    deviceId: event.deviceId,
                    eventType: event.eventType,
                    timestamp: event.timestamp,
                    payload: event.payload,
                    content: decrypted,
                    seq: event.seq
                )
            }
            // No key — sanitize ciphertext
            let sanitized = Self.sanitizeCiphertext(extracted)
            if sanitized != extracted {
                return SessionEvent(
                    id: event.id,
                    sessionId: event.sessionId,
                    deviceId: event.deviceId,
                    eventType: event.eventType,
                    timestamp: event.timestamp,
                    payload: event.payload,
                    content: sanitized,
                    seq: event.seq
                )
            }
            return event
        }
    }

    /// Decrypt events with multi-stage fallback for E2EE key mismatches.
    /// Stage 1: Try cached session key (fast path, same as decryptEvents).
    /// Stage 2: On failure, refetch peer's current key, re-derive, retry.
    /// Stage 3: For versioned (e1:) format, fetch historical key by version, derive, retry.
    /// Stage 4: Give up, show [encrypted].
    func decryptEventsWithFallback(_ events: [SessionEvent], sessionId: String) async -> [SessionEvent] {
        // Stage 1: fast-path with cached key
        let fastResult = decryptEvents(events, sessionId: sessionId)

        // Check if any events still have [encrypted] content — if not, we're done
        let hasEncrypted = fastResult.contains { event in
            event.content?.values.contains("[encrypted]") == true
        }
        guard hasEncrypted else { return fastResult }

        // Stage 2: Refetch peer's current key, re-derive session key, retry
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return fastResult }
        do {
            let peerKeyResp = try await apiClient.getPeerKeyAgreement(deviceId: session.deviceId)
            let currentCachedKey = deviceKAKeys[session.deviceId]
            if currentCachedKey != peerKeyResp.publicKey {
                print("[E2EE] Stage 2: Peer key changed for device \(session.deviceId.prefix(8)), re-deriving")
                deviceKAKeys[session.deviceId] = peerKeyResp.publicKey
                e2eeSessionKeys.removeValue(forKey: sessionId)
                cacheE2EEKey(for: sessionId, peerPublicKeyBase64: peerKeyResp.publicKey)
            }
        } catch {
            print("[E2EE] Stage 2: Failed to refetch peer key: \(error)")
        }

        let stage2Result = decryptEvents(events, sessionId: sessionId)
        let stillEncrypted = stage2Result.contains { $0.content?.values.contains("[encrypted]") == true }
        guard stillEncrypted else { return stage2Result }

        // Stage 3: For versioned format, try historical keys.
        // IMPORTANT: Use the ORIGINAL events for wire format parsing, not stage2Result
        // which has already been sanitized (encrypted values replaced with "[encrypted]").
        guard let service = e2eeService else { return stage2Result }
        var result = stage2Result
        for (i, stage2Event) in result.enumerated() {
            guard let stage2Content = stage2Event.content, stage2Content.values.contains("[encrypted]") else { continue }

            // Use the ORIGINAL event content to parse wire format and extract version info
            guard let originalContent = events[i].content else { continue }
            let originalExtracted = Self.extractMyContent(originalContent, myDeviceId: myDeviceId)

            var decrypted: [String: String] = stage2Content // start with stage2 results (some fields may already be decrypted)
            for (field, value) in originalExtracted {
                // Skip fields that were already successfully decrypted in stage 2
                if let existing = stage2Content[field], existing != "[encrypted]" {
                    continue
                }
                let blob = E2EEService.parseEncryptedValue(value)
                guard let senderVersion = blob.senderKeyVersion,
                      let senderDeviceId = blob.senderDeviceId else {
                    // Legacy format without version — can't look up historical key
                    continue
                }
                // Check both V1 and V2 historical key caches
                let cacheKeyV1 = "\(sessionId):v:\(senderVersion)"
                let cacheKeyV2 = "\(sessionId):v:\(senderVersion):v2"
                if let historicalKey = historicalSessionKeys[cacheKeyV1],
                   let plaintext = try? E2EEService.decrypt(blob.ciphertext, key: historicalKey) {
                    decrypted[field] = plaintext
                    continue
                }
                if let historicalKey = historicalSessionKeys[cacheKeyV2],
                   let plaintext = try? E2EEService.decrypt(blob.ciphertext, key: historicalKey) {
                    decrypted[field] = plaintext
                    continue
                }
                // Key already cached but decryption failed — don't refetch from API
                if historicalSessionKeys[cacheKeyV1] != nil || historicalSessionKeys[cacheKeyV2] != nil {
                    decrypted[field] = "[encrypted]"
                    continue
                }
                do {
                    let keyResp = try await apiClient.getPeerKeyByVersion(deviceId: senderDeviceId, version: senderVersion)

                    // Try V1 derivation (long-term only)
                    let keyV1 = try service.sessionKey(peerPublicKeyBase64: keyResp.publicKey, sessionId: sessionId)
                    historicalSessionKeys[cacheKeyV1] = keyV1
                    if let plaintext = try? E2EEService.decrypt(blob.ciphertext, key: keyV1) {
                        decrypted[field] = plaintext
                        print("[E2EE] Stage 3: Decrypted with historical key v\(senderVersion) (v1) for session \(sessionId.prefix(8))")
                        continue
                    }

                    // V1 failed — try V2 derivation if session has ephemeral key
                    if let ephKey = session.ephemeralPublicKey, !ephKey.isEmpty,
                       let keyV2 = try? service.deriveSessionKeyV2(
                        peerPublicKeyBase64: keyResp.publicKey,
                        ephemeralPublicKeyBase64: ephKey,
                        sessionId: sessionId
                    ) {
                        historicalSessionKeys[cacheKeyV2] = keyV2
                        if let plaintext = try? E2EEService.decrypt(blob.ciphertext, key: keyV2) {
                            decrypted[field] = plaintext
                            print("[E2EE] Stage 3: Decrypted with historical key v\(senderVersion) (v2) for session \(sessionId.prefix(8))")
                            continue
                        }
                    }

                    // Both V1 and V2 failed
                    print("[E2EE] Stage 3: Historical key v\(senderVersion) derived but decryption failed for session \(sessionId.prefix(8))")
                    decrypted[field] = "[encrypted]"
                } catch {
                    print("[E2EE] Stage 3: Failed to fetch historical key v\(senderVersion): \(error)")
                    decrypted[field] = "[encrypted]"
                }
            }
            result[i] = SessionEvent(
                id: stage2Event.id, sessionId: stage2Event.sessionId, deviceId: stage2Event.deviceId,
                eventType: stage2Event.eventType, timestamp: stage2Event.timestamp,
                payload: stage2Event.payload, content: decrypted, seq: stage2Event.seq
            )
        }

        // Log summary of Stage 3 results
        let stage3EncryptedCount = result.filter { $0.content?.values.contains("[encrypted]") == true }.count
        if stage3EncryptedCount > 0 {
            print("[E2EE] Stage 3: \(stage3EncryptedCount) event(s) still undecryptable for session \(sessionId.prefix(8))")
        }

        // Stage 3b: Receiver historical key fallback (e2 format only).
        // When the receiver's key has been rotated since the content was encrypted,
        // the receiverKeyVersion in the e2 blob won't match our current key version.
        // Load our historical private key for that version and re-derive the session key.
        let stillEncryptedAfter3 = stage3EncryptedCount > 0
        if stillEncryptedAfter3 {
            for (i, stage3Event) in result.enumerated() {
                guard let stage3Content = stage3Event.content, stage3Content.values.contains("[encrypted]") else { continue }

                guard let originalContent = events[i].content else { continue }
                let originalExtracted = Self.extractMyContent(originalContent, myDeviceId: myDeviceId)

                var decrypted: [String: String] = stage3Content
                for (field, value) in originalExtracted {
                    if let existing = stage3Content[field], existing != "[encrypted]" {
                        continue
                    }
                    let blob = E2EEService.parseEncryptedValue(value)
                    guard blob.version == 2,
                          let receiverKeyVer = blob.receiverKeyVersion,
                          receiverKeyVer != (myKeyVersion ?? 1) else {
                        continue
                    }

                    let recvCacheKey = "\(sessionId):recv:v\(receiverKeyVer)"
                    let recvCacheKeyV2 = "\(sessionId):recv:v\(receiverKeyVer):v2"

                    // Check both v1 and v2 receiver historical caches
                    if let cachedKey = historicalSessionKeys[recvCacheKey],
                       let plaintext = try? E2EEService.decrypt(blob.ciphertext, key: cachedKey) {
                        decrypted[field] = plaintext
                        continue
                    }
                    if let cachedKey = historicalSessionKeys[recvCacheKeyV2],
                       let plaintext = try? E2EEService.decrypt(blob.ciphertext, key: cachedKey) {
                        decrypted[field] = plaintext
                        continue
                    }
                    // Key already cached but decryption failed — don't re-derive
                    if historicalSessionKeys[recvCacheKey] != nil || historicalSessionKeys[recvCacheKeyV2] != nil {
                        decrypted[field] = "[encrypted]"
                        continue
                    }

                    // Load historical private key for the receiver version
                    guard let historicalPrivateKey = DeviceKeyPair.loadHistorical(version: receiverKeyVer) else {
                        continue
                    }
                    let historicalService = E2EEService(deviceKeyPair: DeviceKeyPair(privateKey: historicalPrivateKey))

                    // Get sender's public key
                    let senderDeviceId = blob.senderDeviceId ?? ""
                    let senderPubKey = deviceKAKeys[senderDeviceId] ??
                        deviceKAKeys[session.deviceId]

                    guard let peerKey = senderPubKey else { continue }

                    // Try v1 derivation
                    if let sessionKey = try? historicalService.sessionKey(
                        peerPublicKeyBase64: peerKey, sessionId: sessionId
                    ) {
                        historicalSessionKeys[recvCacheKey] = sessionKey
                        if let plaintext = try? E2EEService.decrypt(blob.ciphertext, key: sessionKey) {
                            decrypted[field] = plaintext
                            print("[E2EE] Stage 3b: Decrypted with receiver historical key v\(receiverKeyVer) (v1 derivation) for session \(sessionId.prefix(8))")
                            continue
                        }
                    }

                    // Try v2 derivation if session has ephemeral key
                    if let ephKey = session.ephemeralPublicKey, !ephKey.isEmpty {
                        if let sessionKeyV2 = try? historicalService.deriveSessionKeyV2(
                            peerPublicKeyBase64: peerKey,
                            ephemeralPublicKeyBase64: ephKey,
                            sessionId: sessionId
                        ) {
                            let v2CacheKey = "\(sessionId):recv:v\(receiverKeyVer):v2"
                            historicalSessionKeys[v2CacheKey] = sessionKeyV2
                            if let plaintext = try? E2EEService.decrypt(blob.ciphertext, key: sessionKeyV2) {
                                decrypted[field] = plaintext
                                print("[E2EE] Stage 3b: Decrypted with receiver historical key v\(receiverKeyVer) (v2 derivation) for session \(sessionId.prefix(8))")
                                continue
                            }
                        }
                    }
                }

                result[i] = SessionEvent(
                    id: stage3Event.id, sessionId: stage3Event.sessionId, deviceId: stage3Event.deviceId,
                    eventType: stage3Event.eventType, timestamp: stage3Event.timestamp,
                    payload: stage3Event.payload, content: decrypted, seq: stage3Event.seq
                )
            }
        }

        return result
    }

    /// Re-fetch device list and update KA public keys, invalidating stale session keys.
    func refreshDeviceKAKeys() async {
        do {
            let devices = try await apiClient.listDevices()
            var newKeys: [String: String] = [:]
            for device in devices {
                if device.id == myDeviceId {
                    // Update our own key version and persist
                    myKeyVersion = device.keyVersion
                    BuildEnvironment.userDefaults.set(device.keyVersion ?? 1, forKey: "afk_my_key_version")
                }
                if let kaKey = device.keyAgreementPublicKey, !kaKey.isEmpty {
                    newKeys[device.id] = kaKey
                }
            }
            // Invalidate session keys for devices whose KA key changed
            for (deviceId, oldKey) in deviceKAKeys {
                if newKeys[deviceId] != oldKey {
                    // Remove all session keys that were derived from the old device key
                    for session in sessions where session.deviceId == deviceId {
                        e2eeSessionKeys.removeValue(forKey: session.id)
                        sessionKeyVersions.removeValue(forKey: session.id)
                        sessionPeerDeviceId.removeValue(forKey: session.id)
                    }
                    permissionSigningKeys.removeValue(forKey: deviceId)
                }
            }
            deviceKAKeys = newKeys
            print("[E2EE] Refreshed \(newKeys.count) device KA keys")
        } catch {
            print("[E2EE] Failed to refresh device KA keys: \(error)")
        }
    }

    /// Get or derive the HMAC signing key for permission responses to a device.
    /// Returns nil when E2EE key is not yet available (no deterministic fallback).
    private func permissionSigningKey(for deviceId: String) async -> SymmetricKey? {
        if let cached = permissionSigningKeys[deviceId] {
            return cached
        }
        guard let service = e2eeService else { return nil }
        // Fast path: use cached KA key (avoids API round-trip)
        if let peerKey = deviceKAKeys[deviceId] {
            if let key = try? service.derivePermissionKey(peerPublicKeyBase64: peerKey, deviceId: deviceId) {
                permissionSigningKeys[deviceId] = key
                print("[E2EE] Derived permission signing key for device \(deviceId.prefix(8)) (fast path)")
                return key
            }
        }
        // Slow path: fetch from API
        do {
            let peer = try await apiClient.getPeerKeyAgreement(deviceId: deviceId)
            let key = try service.derivePermissionKey(
                peerPublicKeyBase64: peer.publicKey,
                deviceId: deviceId
            )
            permissionSigningKeys[deviceId] = key
            print("[E2EE] Derived permission signing key for device \(deviceId.prefix(8))")
            return key
        } catch {
            print("[E2EE] Failed to derive permission key for \(deviceId.prefix(8)): \(error)")
        }
        return nil
    }

    /// Derive a symmetric key from a challenge and device ID for Tier 2 fallback verification.
    /// HKDF(SHA256(challenge), deviceId, "afk-permission-fallback-v2")
    /// Must match the Agent's deriveChallengeKey exactly.
    private func deriveChallengeKey(challenge: String, deviceId: String) -> SymmetricKey {
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

    /// Load cached sessions from local DB for instant cold start.
    private func loadCachedSessions() {
        let cached = localStore.cachedSessions()
        if !cached.isEmpty {
            sessions = cached
            print("[SessionStore] Loaded \(cached.count) sessions from cache")
        }
    }

    func loadSessions() async {
        isLoading = true
        defer { isLoading = false }

        let result = await syncService.syncSessions()
        if result.isEmpty && !sessions.isEmpty {
            // API failed but we have cached data — mark offline
            isOffline = true
            print("[SessionStore] Offline — showing \(sessions.count) cached sessions")
        } else {
            isOffline = result.isEmpty && sessions.isEmpty
            sessions = result
            sessions.sort { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            print("[SessionStore] Synced \(result.count) sessions")
        }
    }

    func loadEvents(for sessionId: String) async {
        // Derive E2EE key for this session if we have the agent device's KA key
        if let session = sessions.first(where: { $0.id == sessionId }) {
            ensureE2EEKey(for: session)
        }

        let (syncedEvents, hasMore) = await syncService.syncEvents(for: sessionId)

        // Fast-path decrypt — show results immediately so the UI isn't blocked
        let fastDecrypted = decryptEvents(syncedEvents, sessionId: sessionId)
        events[sessionId] = fastDecrypted
        let minSeq = syncedEvents.first?.seq ?? 0
        eventPagination[sessionId] = EventPagination(minSeq: minSeq, hasMore: hasMore)

        // If any fields couldn't be decrypted, run multi-stage fallback in background
        let hasEncrypted = fastDecrypted.contains { $0.content?.values.contains("[encrypted]") == true }
        if hasEncrypted {
            let fallbackResult = await decryptEventsWithFallback(syncedEvents, sessionId: sessionId)
            events[sessionId] = fallbackResult
        }
    }

    /// Load older events (prepend to the beginning of the list)
    func loadMoreEvents(for sessionId: String) async {
        guard let pagination = eventPagination[sessionId],
              pagination.hasMore, !pagination.isLoading else { return }

        eventPagination[sessionId]?.isLoading = true
        defer { eventPagination[sessionId]?.isLoading = false }

        do {
            let (olderEvents, hasMore) = try await apiClient.getOlderEvents(
                sessionId: sessionId,
                beforeSeq: pagination.minSeq
            )
            var existing = events[sessionId] ?? []
            existing.insert(contentsOf: decryptEvents(olderEvents, sessionId: sessionId), at: 0)
            events[sessionId] = existing
            localStore.saveEvents(olderEvents, for: sessionId)
            let minSeq = olderEvents.first?.seq ?? pagination.minSeq
            eventPagination[sessionId] = EventPagination(minSeq: minSeq, hasMore: hasMore)
        } catch {
            print("Failed to load more events: \(error)")
        }
    }

    /// Sessions dismissed from the Now tab by the user (cleared on next app launch).
    var dismissedFromNow: Set<String> = []

    /// Active sessions for the Now tab, ordered by priority:
    /// running > waitingPermission > idle (recent only).
    /// Idle sessions older than 4 hours are excluded — they're stale, not "now".
    var activeSessions: [Session] {
        let staleThreshold = Date().addingTimeInterval(-4 * 3600) // 4 hours
        return sessions
            .filter { session in
                guard !dismissedFromNow.contains(session.id) else { return false }
                switch session.status {
                case .running, .waitingPermission:
                    return true
                case .idle:
                    return (session.updatedAt ?? .distantPast) > staleThreshold
                default:
                    return false
                }
            }
            .sorted { a, b in
                let priorityA = a.status.nowTabPriority
                let priorityB = b.status.nowTabPriority
                if priorityA != priorityB { return priorityA < priorityB }
                return (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast)
            }
    }

    func dismissFromNow(_ sessionId: String) {
        dismissedFromNow.insert(sessionId)
    }

    /// Archive a session locally (mark as completed). Only for idle/error sessions.
    func archiveSession(_ sessionId: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }),
              sessions[index].status == .idle || sessions[index].status == .error else { return }
        sessions[index].status = .completed
        sessions[index].updatedAt = Date()
        dismissedFromNow.remove(sessionId)
    }

    /// Sessions grouped by project path for the grouped session list.
    /// Worktree sessions are grouped under their parent project.
    var sessionsByProject: [(project: String, sessions: [Session])] {
        var groups: [String: [Session]] = [:]
        var pathToName: [String: String] = [:]
        for session in sessions {
            let resolved = session.projectPath.isEmpty ? "" : session.resolvedProjectPath
            let key = resolved.isEmpty ? "Untitled" : resolved
            let name = resolved.isEmpty ? "Untitled" : session.projectName
            groups[key, default: []].append(session)
            pathToName[key] = name
        }
        // Sort groups: active sessions first, then by most recent update.
        return groups.sorted { lhs, rhs in
            let lhsActive = lhs.value.contains { $0.status == .running || $0.status == .waitingPermission }
            let rhsActive = rhs.value.contains { $0.status == .running || $0.status == .waitingPermission }
            if lhsActive != rhsActive { return lhsActive }
            let lhsDate = lhs.value.first?.updatedAt ?? .distantPast
            let rhsDate = rhs.value.first?.updatedAt ?? .distantPast
            return lhsDate > rhsDate
        }.map { (project: pathToName[$0.key] ?? $0.key, sessions: $0.value) }
    }

    private func setupWebSocketHandlers() {
        wsService.onSessionUpdate = { [weak self] (session: Session) in
            guard let self else { return }
            self.isOffline = false
            // Track key version before deriving, to detect upgrades
            let versionBefore = self.sessionKeyVersions[session.id] ?? 0
            // Ensure E2EE session key is derived when we first see a session
            let keyDerived = self.ensureE2EEKey(for: session)
            if !keyDerived {
                // No KA key for this device — try refreshing device keys and retry
                Task { [weak self] in
                    guard let self else { return }
                    await self.refreshDeviceKAKeys()
                    let retryResult = self.ensureE2EEKey(for: session)
                    if retryResult {
                        print("[E2EE] Retry succeeded: derived key for session \(session.id.prefix(8))")
                    } else {
                        print("[E2EE] Retry failed: still no KA key for device \(session.deviceId.prefix(8))")
                    }
                }
            }
            // Log if key was upgraded (v1→v2). Events that arrived before
            // the upgrade and have [encrypted] content will be fixed on REST reload.
            let versionAfter = self.sessionKeyVersions[session.id] ?? 0
            if versionAfter > versionBefore {
                print("[E2EE] Key upgraded for session \(session.id.prefix(8)): v\(versionBefore) → v\(versionAfter)")
            }
            print("[SessionStore] WS session.update: \(session.id.prefix(8)) status=\(session.status) project=\"\(session.projectPath)\"")
            // If a dismissed session becomes active again, un-dismiss it
            if session.status == .running || session.status == .waitingPermission {
                self.dismissedFromNow.remove(session.id)
            }
            let previousStatus = self.sessions.first(where: { $0.id == session.id })?.status
            if let idx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                self.sessions[idx] = session
            } else {
                self.sessions.insert(session, at: 0)
            }
            self.sessions.sort { s0, s1 in
                (s0.updatedAt ?? .distantPast) > (s1.updatedAt ?? .distantPast)
            }

            // Persist to local DB
            self.localStore.saveSession(session)

            // Live Activity integration
            if let lam = self.liveActivityManager {
                let hasPendingPermission = self.pendingPermissions.values.contains {
                    $0.sessionId == session.id && !$0.isExpired
                }

                switch session.status {
                case .running where previousStatus != .running:
                    lam.startActivity(
                        sessionId: session.id,
                        projectName: session.projectName,
                        deviceName: session.deviceName ?? "Mac",
                        apiClient: self.apiClient
                    )
                case .completed:
                    lam.endActivity(sessionId: session.id, finalStatus: "completed")
                case .error:
                    lam.endActivity(sessionId: session.id, finalStatus: "error")
                default:
                    let effectiveStatus = (session.status == .running && hasPendingPermission)
                        ? "waiting_permission"
                        : session.status.rawValue
                    lam.updateActivity(
                        sessionId: session.id,
                        status: effectiveStatus,
                        turnCount: session.turnCount
                    )
                }
            }

            // When a session resumes (e.g. completed → running), reload events
            // so the conversation view picks up the new turn's messages.
            if session.status == .running,
               previousStatus != nil, previousStatus != .running,
               self.viewingSessionIds.contains(session.id) {
                Task { [weak self] in
                    await self?.loadEvents(for: session.id)
                }
            }
        }

        wsService.onSessionEvent = { [weak self] (event: SessionEvent) in
            guard let self else { return }
            var list = self.events[event.sessionId] ?? []
            // Deduplicate: skip if an event with the same ID was already fetched via REST
            if !list.contains(where: { $0.id == event.id }) {
                list.append(event)
            }
            self.events[event.sessionId] = list

            // Persist to local DB
            self.localStore.saveEvent(event)

            // Async E2EE fallback: when sync decryptor couldn't decrypt (sender key version mismatch),
            // trigger full fallback with historical key lookup and update the event in-place.
            if event.content?.values.contains("[encrypted]") == true {
                Task { [weak self] in
                    guard let self else { return }
                    let decrypted = await self.decryptEventsWithFallback([event], sessionId: event.sessionId)
                    if let first = decrypted.first,
                       first.content?.values.contains("[encrypted]") != true {
                        if var list = self.events[event.sessionId],
                           let idx = list.firstIndex(where: { $0.id == first.id }) {
                            list[idx] = first
                            self.events[event.sessionId] = list
                            self.localStore.saveEvent(first)
                            print("[E2EE] Async fallback: decrypted event \(first.id.prefix(8)) for session \(event.sessionId.prefix(8))")
                        }
                    }
                }
            }

            // Update live activity with tool info
            if event.eventType == "tool_started", let lam = self.liveActivityManager {
                let hasPendingPermission = self.pendingPermissions.values.contains {
                    $0.sessionId == event.sessionId && !$0.isExpired
                }
                // Agent-computed description (no parsing needed on iOS)
                let toolDisplay = event.toolDescription ?? event.toolName
                // Count active task-type tools (spawned agents)
                let sessionEvents = self.events[event.sessionId] ?? []
                let activeTaskCount = Self.countActiveTaskTools(in: sessionEvents)

                lam.updateActivity(
                    sessionId: event.sessionId,
                    status: hasPendingPermission ? "waiting_permission" : "running",
                    currentTool: toolDisplay,
                    agentCount: activeTaskCount > 1 ? activeTaskCount : nil
                )
            }
        }

        wsService.onReconnect = { [weak self] in
            guard let self else { return }
            self.isOffline = false
            Task {
                // Refresh device KA keys on reconnect to pick up any new/rotated keys
                await self.refreshDeviceKAKeys()
                for attempt in 0..<3 {
                    if attempt > 0 {
                        let delay = Double(1 << attempt)
                        try? await Task.sleep(for: .seconds(delay))
                    }
                    await self.loadSessions()
                    if !self.sessions.isEmpty { break }
                }
                // Catch up on missed events for sessions the user is currently viewing
                for sessionId in self.viewingSessionIds {
                    await self.loadEvents(for: sessionId)
                }
            }
        }

        wsService.onDeviceKeyRotated = { [weak self] (deviceId, newPublicKey, keyVersion) in
            guard let self else { return }
            let oldFingerprint = self.deviceKAKeys[deviceId].map { E2EEService.fingerprint(of: $0) } ?? "none"
            let newFingerprint = E2EEService.fingerprint(of: newPublicKey)
            print("[E2EE] Device \(deviceId.prefix(8)) key rotated: \(oldFingerprint) -> \(newFingerprint) (v\(keyVersion))")

            // Update the cached KA key
            self.deviceKAKeys[deviceId] = newPublicKey

            // Invalidate all session keys derived from this device's old key
            for session in self.sessions where session.deviceId == deviceId {
                self.e2eeSessionKeys.removeValue(forKey: session.id)
                self.sessionKeyVersions.removeValue(forKey: session.id)
                self.sessionPeerDeviceId.removeValue(forKey: session.id)
            }

            // Clear permission signing key for this device
            self.permissionSigningKeys.removeValue(forKey: deviceId)

            // Flush any queued permission requests with the new key
            self.flushQueuedPermissions(for: deviceId)
        }

        wsService.onAgentControlState = { [weak self] (deviceId, remoteApproval, autoPlanExit) in
            guard let self else { return }
            self.agentControlStates[deviceId] = AgentControlState(remoteApproval: remoteApproval, autoPlanExit: autoPlanExit)
        }

        wsService.onPermissionRequest = { [weak self] (request: PermissionRequest) in
            guard let self else { return }
            guard !request.isExpired else { return }

            // Update live activity to show permission waiting
            self.liveActivityManager?.updateActivity(
                sessionId: request.sessionId,
                status: "waiting_permission",
                currentTool: request.toolName
            )

            // Check if E2EE signing key is available
            if self.permissionSigningKeys[request.deviceId] != nil {
                // Tier 1 ready — show immediately
                self.addPendingPermission(request)
            } else if self.deviceKAKeys[request.deviceId] != nil {
                // KA key available — try deriving the signing key
                Task { [weak self] in
                    guard let self else { return }
                    let key = await self.permissionSigningKey(for: request.deviceId)
                    if key != nil {
                        self.addPendingPermission(request)
                    } else {
                        self.enqueuePermission(request)
                    }
                }
            } else {
                // No KA key yet — queue with 30s timeout
                self.enqueuePermission(request)
            }
        }
    }

    /// Add a permission request to pendingPermissions with auto-expiry timer.
    private func addPendingPermission(_ request: PermissionRequest) {
        // Race guard: don't insert if already pending (e.g., timer fired concurrently)
        guard pendingPermissions[request.nonce] == nil else { return }
        pendingPermissions[request.nonce] = request

        // Auto-expire after the deadline
        let nonce = request.nonce
        let delay = request.timeRemaining
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            self.pendingPermissions.removeValue(forKey: nonce)
        }
    }

    /// Queue a permission request that can't be verified yet, with a 30s timeout.
    private func enqueuePermission(_ request: PermissionRequest) {
        queuedPermissions.append(request)

        // Start 30s timer — after which show as unverified
        let nonce = request.nonce
        permissionQueueTimers[nonce] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self else { return }
            // Race guard: only promote if not already pending (flush may have beaten us)
            guard self.pendingPermissions[nonce] == nil else { return }
            // Remove from queue
            self.queuedPermissions.removeAll { $0.nonce == nonce }
            self.permissionQueueTimers.removeValue(forKey: nonce)
            // Find the request and mark as unverified
            var unverified = request
            unverified.isUnverified = true
            self.addPendingPermission(unverified)
            print("[SessionStore] Permission \(nonce.prefix(8)) promoted to unverified after 30s timeout")
        }
    }

    /// Move queued permissions for a device to pending once E2EE keys become available.
    func flushQueuedPermissions(for deviceId: String) {
        let matching = queuedPermissions.filter { $0.deviceId == deviceId && !$0.isExpired }
        guard !matching.isEmpty else { return }

        queuedPermissions.removeAll { $0.deviceId == deviceId }

        // Eagerly derive signing key using the now-cached KA key
        if let service = e2eeService, let peerKey = deviceKAKeys[deviceId],
           let key = try? service.derivePermissionKey(peerPublicKeyBase64: peerKey, deviceId: deviceId) {
            permissionSigningKeys[deviceId] = key
        }

        for request in matching {
            // Cancel the 30s timer
            permissionQueueTimers[request.nonce]?.cancel()
            permissionQueueTimers.removeValue(forKey: request.nonce)
            // Race guard: don't double-insert
            guard pendingPermissions[request.nonce] == nil else { continue }
            if permissionSigningKeys[deviceId] == nil {
                var unverified = request
                unverified.isUnverified = true
                addPendingPermission(unverified)
            } else {
                addPendingPermission(request)
            }
        }
        print("[SessionStore] Flushed \(matching.count) queued permission(s) for device \(deviceId.prefix(8))")
    }

    func sendPermissionResponse(nonce: String, action: String) async {
        guard let request = pendingPermissions[nonce] else { return }

        // Derive E2EE permission signing key (nil if E2EE not ready)
        let signingKey = await permissionSigningKey(for: request.deviceId)

        // Always derive challenge-response key as Tier 2 fallback.
        // Even when E2EE key is available, the challenge signature provides
        // resilience against stale/mismatched E2EE keys (e.g., after key rotation).
        var challengeKey: SymmetricKey? = nil
        if let challenge = request.challenge {
            challengeKey = deriveChallengeKey(challenge: challenge, deviceId: request.deviceId)
        }

        let response = PermissionResponse.create(
            nonce: nonce,
            action: action,
            expiresAt: request.expiresAt,
            deviceId: request.deviceId,
            signingKey: signingKey,
            challenge: request.challenge,
            challengeKey: challengeKey
        )

        await wsService.sendPermissionResponse(response)
        pendingPermissions.removeValue(forKey: nonce)

        // Restore live activity to "running" now that permission is resolved
        liveActivityManager?.updateActivity(
            sessionId: request.sessionId,
            status: "running"
        )
    }

    /// Get pending permission requests for a specific session
    func pendingPermission(for sessionId: String) -> PermissionRequest? {
        pendingPermissions.values.first { $0.sessionId == sessionId && !$0.isExpired }
    }

    // MARK: - Permission Mode

    func setPermissionMode(deviceId: String, mode: String) async {
        permissionModes[deviceId] = mode
        await wsService.sendPermissionMode(deviceId: deviceId, mode: mode)
    }

    func permissionMode(for deviceId: String) -> String {
        permissionModes[deviceId] ?? "ask"
    }

    // MARK: - Agent Control

    func agentControl(for deviceId: String) -> AgentControlState {
        agentControlStates[deviceId] ?? AgentControlState(remoteApproval: true, autoPlanExit: false)
    }

    func setAgentRemoteApproval(deviceId: String, enabled: Bool) async {
        agentControlStates[deviceId, default: AgentControlState(remoteApproval: true, autoPlanExit: false)].remoteApproval = enabled
        await wsService.sendAgentControl(deviceId: deviceId, remoteApproval: enabled)
    }

    func setAgentAutoPlanExit(deviceId: String, enabled: Bool) async {
        agentControlStates[deviceId, default: AgentControlState(remoteApproval: true, autoPlanExit: false)].autoPlanExit = enabled
        await wsService.sendAgentControl(deviceId: deviceId, autoPlanExit: enabled)
    }

    /// Counts active task-type tool calls (spawned agents) in a session's events.
    static func countActiveTaskTools(in events: [SessionEvent]) -> Int {
        var activeToolIds = Set<String>()
        for event in events {
            guard let toolUseId = event.payload?["toolUseId"] else { continue }
            if event.eventType == "tool_started" && event.toolCategory == "task" {
                activeToolIds.insert(toolUseId)
            } else if event.eventType == "tool_finished" {
                activeToolIds.remove(toolUseId)
            }
        }
        return activeToolIds.count
    }

    // MARK: - Diagnostics

    struct PeerDiagnostic {
        let deviceId: String
        let fingerprint: String
        let keyVersion: Int?
        let capabilities: [String]
        let sessionsWithKeys: Int
    }

    struct SessionKeyDiagnostic {
        let sessionId: String
        let keyVersion: Int
        let hasEphemeralKey: Bool
        let peerDeviceId: String?
    }

    struct PermissionDiagnostic {
        let sessionId: String
        let toolName: String
        let nonce: String
        let isUnverified: Bool
        let timeRemaining: TimeInterval
    }

    struct DiagnosticSnapshot {
        // Device identity
        let myDeviceId: String?
        let myKeyVersion: Int?
        let myFingerprint: String?
        let capabilities: [String]

        // E2EE state
        let e2eeInitialized: Bool
        let sessionKeyCount: Int
        let historicalKeyCount: Int
        let permissionKeyCount: Int
        let peers: [PeerDiagnostic]
        let sessionKeys: [SessionKeyDiagnostic]

        // Sessions
        let totalSessions: Int
        let sessionsByStatus: [SessionStatus: Int]
        let dismissedSessionIds: Set<String>

        // Permissions
        let pendingPermissions: [PermissionDiagnostic]
        let queuedPermissionCount: Int
    }

    var diagnosticSnapshot: DiagnosticSnapshot {
        // Build peer info
        var peers: [PeerDiagnostic] = []
        for (deviceId, pubKey) in deviceKAKeys {
            let fp = E2EEService.fingerprint(of: pubKey)
            // Find device in sessions to get additional info
            let device = sessions.first(where: { $0.deviceId == deviceId })
            let sessionsWithKeys = sessions.filter { s in
                s.deviceId == deviceId && e2eeSessionKeys[s.id] != nil
            }.count
            // We don't store peer capabilities locally — report empty
            peers.append(PeerDiagnostic(
                deviceId: deviceId,
                fingerprint: fp,
                keyVersion: nil,
                capabilities: [],
                sessionsWithKeys: sessionsWithKeys
            ))
            _ = device // suppress unused warning
        }

        // Build session key details
        var sessionKeyDetails: [SessionKeyDiagnostic] = []
        for (sessionId, _) in e2eeSessionKeys {
            let ver = sessionKeyVersions[sessionId] ?? 1
            let session = sessions.first(where: { $0.id == sessionId })
            let hasEph = session?.ephemeralPublicKey != nil && !(session?.ephemeralPublicKey?.isEmpty ?? true)
            sessionKeyDetails.append(SessionKeyDiagnostic(
                sessionId: sessionId,
                keyVersion: ver,
                hasEphemeralKey: hasEph,
                peerDeviceId: sessionPeerDeviceId[sessionId]
            ))
        }

        // Session status breakdown
        var statusCounts: [SessionStatus: Int] = [:]
        for session in sessions {
            statusCounts[session.status, default: 0] += 1
        }

        // Permission diagnostics
        let permDiags = pendingPermissions.values.map { req in
            PermissionDiagnostic(
                sessionId: req.sessionId,
                toolName: req.toolName,
                nonce: req.nonce,
                isUnverified: req.isUnverified,
                timeRemaining: req.timeRemaining
            )
        }

        // Own fingerprint
        let myFP = e2eeService.map { E2EEService.fingerprint(of: $0.publicKeyBase64) }

        return DiagnosticSnapshot(
            myDeviceId: myDeviceId,
            myKeyVersion: myKeyVersion,
            myFingerprint: myFP,
            capabilities: ["e2ee_v2"],
            e2eeInitialized: e2eeService != nil,
            sessionKeyCount: e2eeSessionKeys.count,
            historicalKeyCount: historicalSessionKeys.count,
            permissionKeyCount: permissionSigningKeys.count,
            peers: peers,
            sessionKeys: sessionKeyDetails,
            totalSessions: sessions.count,
            sessionsByStatus: statusCounts,
            dismissedSessionIds: dismissedFromNow,
            pendingPermissions: permDiags,
            queuedPermissionCount: queuedPermissions.count
        )
    }

    /// Force clear all cached session keys, triggering re-derivation on next access.
    func clearSessionKeyCache() {
        let count = e2eeSessionKeys.count
        e2eeSessionKeys.removeAll()
        sessionKeyVersions.removeAll()
        historicalSessionKeys.removeAll()
        print("[E2EE] Diagnostics: Cleared \(count) session keys")
    }

    /// Force disconnect and reconnect the WebSocket.
    func forceReconnectWS() {
        wsService.reconnect()
    }
}
