# AFK End-to-End Encryption (E2EE) — Complete Technical Reference

> This document covers every detail of how E2EE works in the AFK system, from first login to final decryption.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Cryptographic Primitives](#2-cryptographic-primitives)
3. [Key Generation & Storage](#3-key-generation--storage)
4. [Device Enrollment & Key Registration](#4-device-enrollment--key-registration)
5. [Key Exchange & Peer Discovery](#5-key-exchange--peer-discovery)
6. [Session Key Derivation](#6-session-key-derivation)
7. [Encryption Flow (Agent → Server → iOS)](#7-encryption-flow-agent--server--ios)
8. [Decryption Flow (iOS)](#8-decryption-flow-ios)
9. [Prompt Encryption (iOS → Agent)](#9-prompt-encryption-ios--agent)
10. [Key Rotation & Broadcast](#10-key-rotation--broadcast)
11. [Permission HMAC Signing](#11-permission-hmac-signing)
12. [Privacy Modes](#12-privacy-modes)
13. [Error Handling & Recovery](#13-error-handling--recovery)
14. [Wire Formats](#14-wire-formats)
15. [Database Schema](#15-database-schema)
16. [API Endpoints](#16-api-endpoints)
17. [Known Limitations](#17-known-limitations)

---

## 1. Architecture Overview

```
┌──────────────┐       ┌──────────────────┐       ┌──────────────┐
│   iOS App    │◄─────►│   AFK Cloud      │◄─────►│  macOS Agent │
│              │  WS   │   (Go backend)   │  WS   │              │
│ Curve25519   │  +    │                  │  +    │ Curve25519   │
│ private key  │ REST  │  Zero-knowledge  │ REST  │ private key  │
│ (Keychain)   │       │  encrypted store │       │ (Keychain)   │
└──────────────┘       └──────────────────┘       └──────────────┘
     ▲                                                   ▲
     │              ECDH Shared Secret                   │
     └───────────────────────────────────────────────────┘
          Derived independently by both sides
          from: my_private_key + peer_public_key
```

**Core principle**: The backend never has access to plaintext content. It stores encrypted blobs and routes them between iOS and Agent. Only the `content` field of events is encrypted — `payload` (telemetry: event types, tool names, turn indices) stays plaintext for routing, push triggers, and summaries.

**Three participants**:
- **iOS App** — receiver/viewer of encrypted content, sender of encrypted prompts
- **macOS Agent** — sender of encrypted content (Claude session events), receiver of encrypted prompts
- **AFK Cloud** — zero-knowledge relay and encrypted store

---

## 2. Cryptographic Primitives

| Primitive | Algorithm | Purpose |
|-----------|-----------|---------|
| Key Agreement | Curve25519 (X25519 ECDH) | Derive shared secret between iOS and Agent |
| Key Derivation | HKDF-SHA256 | Derive per-session symmetric keys from shared secret |
| Content Encryption | AES-256-GCM | Encrypt/decrypt event content and prompts |
| Permission Signing | HMAC-SHA256 | Sign permission approval/denial responses |
| Fingerprinting | SHA-256 (first 4 bytes) | Human-readable key identity for logging |

**Libraries**:
- iOS + Agent: Apple CryptoKit (`import CryptoKit`)
- Backend: Go `crypto/sha256`, `encoding/base64`

---

## 3. Key Generation & Storage

### 3.1 iOS Key Pair

**File**: `AFK/Security/DeviceKeyPair.swift`

```swift
struct DeviceKeyPair {
    private static let keychainKey = "device-key-agreement-private"
    private static let backupKeychainKey = "device-key-agreement-private-backup"
    private static let keychain = KeychainService()

    let privateKey: Curve25519.KeyAgreement.PrivateKey
}
```

**`loadOrCreate()` flow**:

```
1. Try loading primary key from Keychain ("device-key-agreement-private")
   ├─ Found → return it, ensure backup exists
   └─ Not found →
      2. Try loading backup key ("device-key-agreement-private-backup")
         ├─ Found → restore primary from backup, return it
         └─ Not found →
            3. Generate new Curve25519.KeyAgreement.PrivateKey()
            4. Save to Keychain (primary + backup)
            5. If previously enrolled device exists, log WARNING
```

**Keychain parameters**:
- Service: `"com.afk.app"`
- Accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
  - Available after the device is unlocked once since boot
  - NOT included in backups or transferred to new devices
  - More reliable than `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` for background scenarios

**Thread safety**: `KeychainService` uses an `NSLock` to serialize all Keychain operations:
```swift
private static let lock = NSLock()

func save(_ data: Data, forKey key: String) throws {
    Self.lock.lock()
    defer { Self.lock.unlock() }
    // Try SecItemUpdate first (avoids delete+add race)
    // Fall back to delete + SecItemAdd if item doesn't exist
}
```

**Backup mechanism**: A second Keychain entry (`device-key-agreement-private-backup`) stores a copy of the private key. If the primary is lost (Keychain glitch, accessibility issue), the backup is used to recover without generating a new key, which would make all historical encrypted content unreadable.

### 3.2 Agent Key Pair

**File**: `AFK-Agent/AFK-Agent/Auth/KeyAgreementIdentity.swift`

```swift
struct KeyAgreementIdentity: Sendable {
    private static let keychainKey = "device-key-agreement-private"
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    static func load(from keychain: KeychainStore) throws -> KeyAgreementIdentity?
    static func generate() -> KeyAgreementIdentity
    func save(to keychain: KeychainStore) throws
}
```

**Agent Keychain** (`KeychainStore.swift`):
- Service: `"com.afk.agent"`
- Accessibility: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- No backup mechanism (agent runs on macOS where Keychain is more stable)

### 3.3 Fingerprinting

Both iOS and Agent compute human-readable fingerprints for logging:

```swift
// E2EEService.swift / E2EEncryption.swift
static func fingerprint(of publicKey: String) -> String {
    guard let data = Data(base64Encoded: publicKey) else { return "invalid" }
    let hash = SHA256.hash(data: data)
    return Array(hash).prefix(4).map { String(format: "%02x", $0) }.joined(separator: ":")
}
// Output: "cb:2a:fe:f3"
```

Used for log correlation without exposing the full public key.

---

## 4. Device Enrollment & Key Registration

### 4.1 iOS Enrollment

**File**: `AFK/AFKApp.swift` — `enrollIOSDeviceIfNeeded()`

**Triggered by**: `onChange(of: authService.isAuthenticated)` — runs every time the user logs in.

```
Authentication succeeds
  └─ onChange(isAuthenticated = true)
       └─ Task {
            await enrollIOSDeviceIfNeeded()   // ← E2EE keys set up here
            wsService.connect(token, apiClient)
          }
```

**First-time enrollment**:
1. `DeviceKeyPair.loadOrCreate()` — generates Curve25519 key pair
2. `apiClient.enrollDevice(name:, publicKey:, systemInfo:, keyAgreementPublicKey:)` — POST /v1/devices
3. Store device ID in UserDefaults (`afk_ios_device_id`)
4. Store key fingerprint (`afk_last_registered_ka_fingerprint`)
5. Set `sessionStore.myDeviceId`

**Subsequent launches** (already enrolled):
1. `DeviceKeyPair.loadOrCreate()` — loads existing key
2. Compare current fingerprint with stored fingerprint
3. If unchanged → skip registration
4. If changed (key was regenerated) →
   - Call `sessionStore.reinitializeE2EE()` to clear all cached derived keys
   - Call `apiClient.registerKeyAgreement(deviceId, publicKey)` — POST /v1/devices/{id}/key-agreement
   - Update stored fingerprint

**Cache peer keys and self-heal** (always, after enrollment check):
```swift
let devices = try await apiClient.listDevices()
for device in devices {
    if device.id == myDeviceId {
        ownDevice = device
        sessionStore.myKeyVersion = device.keyVersion
    } else if let kaKey = device.keyAgreementPublicKey, !kaKey.isEmpty {
        sessionStore.cacheDeviceKey(deviceId: device.id, publicKey: kaKey)
    }
}

// Self-healing: detect and fix missing device/key on backend
if let storedId = myDeviceId {
    if ownDevice == nil {
        // Device ID in UserDefaults doesn't exist on backend (DB rebuilt)
        // Re-enroll to recreate the device record with KA key
        let device = try await apiClient.enrollDevice(..., deviceId: storedId)
    } else if ownDevice?.keyAgreementPublicKey == nil {
        // Device exists but backend lost our KA key
        try await apiClient.registerKeyAgreement(deviceId: storedId, publicKey: ...)
    }
}
```

### 4.2 Agent Enrollment

**File**: `AFK-Agent/AFK-Agent/Agent.swift` — `emailEnroll()`

1. Get auth token via email/password or Apple Sign-In
2. Load or generate `KeyAgreementIdentity`
3. Call `api.enrollDevice(...)` with `keyAgreementPublicKey: kaIdentity.publicKeyBase64`
4. Track registered fingerprint in Agent Keychain (`last-registered-ka-fingerprint`)
5. If re-enrolling existing device, check fingerprint and re-register KA key if changed
6. Save auth token, refresh token, and device ID to Keychain

### 4.3 Backend Device Handler

**File**: `afk-cloud/internal/handler/device_handler.go` — `HandleCreate`

```
POST /v1/devices
  ├─ Parse request (name, publicKey, systemInfo, keyAgreementPublicKey, deviceId)
  ├─ Try reuse by explicit deviceId (if provided)
  ├─ Try fingerprint dedup (same name + systemInfo for same user)
  ├─ Create new device if needed
  ├─ Store keyAgreementPublicKey if provided:
  │   ├─ Idempotent: skip if key unchanged
  │   ├─ Compute newVersion = device.keyVersion + 1
  │   ├─ UPDATE devices SET key_agreement_public_key = ?, key_version = ?
  │   ├─ INSERT INTO device_keys (version, publicKey, active=1)
  │   └─ hub.BroadcastToAll(userID, "device.key_rotated")  ← notifies connected peers
  └─ Return device JSON
```

**Key broadcast on enrollment**: When a device enrolls with a KA key, the backend broadcasts `device.key_rotated` to all connected peers. This ensures that if the agent is already connected when iOS enrolls (or vice versa), the peer immediately discovers the new key and enables E2EE without requiring a restart.

### 4.4 Backend Key Registration

**File**: `afk-cloud/internal/handler/key_exchange_handler.go` — `HandleRegisterKey`

```
POST /v1/devices/{id}/key-agreement
  ├─ Verify device belongs to authenticated user
  ├─ Idempotent check:
  │   └─ If device.KeyAgreementPublicKey == req.PublicKey → return current version (no-op)
  ├─ Revoke old keys: UPDATE device_keys SET active=0, revoked_at=NOW() WHERE device_id=? AND active=1
  ├─ Bump version: newVersion = device.KeyVersion + 1
  ├─ Update device: UPDATE devices SET key_agreement_public_key=?, key_version=?
  ├─ Insert audit record: INSERT INTO device_keys (device_id, version, public_key, active=1)
  ├─ Audit log: action="key_agreement_registered", details={"version":N,"fingerprint":"..."}
  ├─ Broadcast: hub.BroadcastToAll(userID, "device.key_rotated") → sends to ALL iOS + Agent connections
  └─ Return {"version": N, "publicKey": "..."}
```

---

## 5. Key Exchange & Peer Discovery

### 5.1 How iOS Discovers Agent Keys

```
AFKApp.enrollIOSDeviceIfNeeded()
  └─ apiClient.listDevices()
       └─ For each device where id ≠ myDeviceId:
            sessionStore.cacheDeviceKey(deviceId, publicKey)
              └─ deviceKAKeys[deviceId] = publicKey
```

**Also refreshed**:
- On WS reconnect: `SessionStore.refreshDeviceKAKeys()` calls `listDevices()` again
- On key rotation event: `onDeviceKeyRotated` updates `deviceKAKeys[deviceId]`

### 5.2 How Agent Discovers iOS Keys

```
Agent.setupE2EEEncryptor(deviceId:)
  └─ api.listDevices()
       └─ For each device where id ≠ myDeviceId:
            peerKeys[device.id] = device.keyAgreementPublicKey
       └─ Create SessionKeyCache(e2ee, peerKeys, myKeyVersion, myDeviceId)
```

**Also refreshed**:
- On `device.key_rotated` WS event: re-runs `setupE2EEEncryptor()` entirely

### 5.3 ECDH Shared Secret

Both sides compute the same shared secret independently:

```
iOS:   sharedSecret = ECDH(ios_privateKey, agent_publicKey)
Agent: sharedSecret = ECDH(agent_privateKey, ios_publicKey)

Because: ECDH(A_priv, B_pub) == ECDH(B_priv, A_pub)  (mathematical property of elliptic curves)
```

**Implementation** (identical on both sides):
```swift
func deriveSharedSecret(peerPublicKeyBase64: String) throws -> SharedSecret {
    let peerKeyData = Data(base64Encoded: peerPublicKeyBase64)!
    let peerPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKeyData)
    return try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
}
```

Result: 32-byte shared secret known only to the two devices.

---

## 6. Session Key Derivation

Each session gets its own symmetric key derived from the shared secret. Two derivation methods exist:

### 6.1 V1 Derivation (Long-Term Only)

```swift
func deriveSessionKey(sharedSecret: SharedSecret, sessionId: String) -> SymmetricKey {
    let salt = sessionId.data(using: .utf8)!
    return sharedSecret.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: salt,
        sharedInfo: "afk-e2ee-content-v1".data(using: .utf8)!,
        outputByteCount: 32
    )
}
```

**HKDF parameters**:
| Parameter | Value |
|-----------|-------|
| Hash | SHA-256 |
| IKM | 32-byte ECDH shared secret |
| Salt | UTF-8 bytes of `sessionId` (UUID string) |
| Info | `"afk-e2ee-content-v1"` (domain separation) |
| Output | 32 bytes (256-bit AES key) |

### 6.2 V2 Derivation (Forward-Secret with Ephemeral Keys)

V2 provides forward secrecy by incorporating an ephemeral key pair generated per session. The agent generates an ephemeral Curve25519 key pair for each session and publishes the public key in the session metadata.

```swift
func deriveSessionKeyV2(
    peerPublicKeyBase64: String,       // Peer's long-term public key
    ephemeralPublicKeyBase64: String,   // Peer's ephemeral public key (from session)
    sessionId: String
) throws -> SymmetricKey {
    let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(base64Encoded: peerPublicKeyBase64)!)
    let ephPeerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(base64Encoded: ephemeralPublicKeyBase64)!)

    let ltSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
    let ephSecret = try privateKey.sharedSecretFromKeyAgreement(with: ephPeerKey)

    var combinedIKM = Data()
    ltSecret.withUnsafeBytes { combinedIKM.append(contentsOf: $0) }
    ephSecret.withUnsafeBytes { combinedIKM.append(contentsOf: $0) }

    let salt = sessionId.data(using: .utf8)!
    return HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: combinedIKM),
        salt: salt,
        info: "afk-e2ee-content-v2".data(using: .utf8)!,
        outputByteCount: 32
    )
}
```

**V2 HKDF parameters**:
| Parameter | Value |
|-----------|-------|
| Hash | SHA-256 |
| IKM | `ECDH(my_LT, peer_LT) \|\| ECDH(my_LT, peer_ephemeral)` (64 bytes) |
| Salt | UTF-8 bytes of `sessionId` (UUID string) |
| Info | `"afk-e2ee-content-v2"` (domain separation) |
| Output | 32 bytes (256-bit AES key) |

**Key upgrade**: Sessions start with v1 and upgrade to v2 when the ephemeral key becomes available via `session.update` WS message.

### 6.3 Caching

- iOS: `SessionStore.e2eeSessionKeys: [String: SymmetricKey]` (sessionId → key)
- iOS: `SessionStore.sessionKeyVersions: [String: Int]` (sessionId → 1 or 2, tracks derivation version)
- Agent: `SessionKeyCache.keys: [String: [String: SymmetricKey]]` (sessionId → [deviceId → key])

---

## 7. Encryption Flow (Agent → Server → iOS)

### 7.1 What Gets Encrypted

Claude session events have two data sections:
- **`payload`** (JSON dict) — telemetry metadata: `eventType`, `toolName`, `turnIndex`, `toolUseId`, etc. **NOT encrypted.** Used by the backend for routing, push notifications, and summaries.
- **`content`** (JSON dict) — sensitive data: `content` (message text), `toolInputFields`, `userSnippet`, `assistantSnippet`, etc. **ENCRYPTED** when privacy mode is `"encrypted"`.

### 7.2 Agent Encryption Path

```
Claude writes to JSONL file
  └─ Agent FileWatcher detects new lines
       └─ JSONLParser parses JSONL entries
            └─ EventNormalizer.normalize(entry, sessionId, projectPath, privacyMode)
                 ├─ Extract content fields from entry
                 ├─ If privacyMode == "encrypted" && contentEncryptor != nil:
                 │   └─ contentEncryptor(content, sessionId)
                 │        └─ For each peer device (iOS device):
                 │             For each content field:
                 │               key = "\(peerDeviceId):\(fieldName)"
                 │               value = E2EEncryption.encryptVersioned(
                 │                   plaintext, key: sessionKey,
                 │                   keyVersion: myKeyVersion,
                 │                   senderDeviceId: myDeviceId
                 │               )
                 └─ Return normalized event with encrypted content
```

### 7.3 Multi-Peer Content Format

The agent encrypts each content field separately for each peer device:

```json
{
  "aa36750f-...:content": "e1:2:8c5988db-...:NiP5j4F2zQ...",
  "aa36750f-...:userSnippet": "e1:2:8c5988db-...:xK8mPq3bR...",
  "3a66a920-...:content": "e1:2:8c5988db-...:Ym9R7kL2pX...",
  "3a66a920-...:userSnippet": "e1:2:8c5988db-...:qW5nHj1dS..."
}
```

- Key format: `"<receiverDeviceId>:<fieldName>"`
- Value format: versioned wire format (see [Wire Formats](#14-wire-formats))
- Each receiver gets their own encrypted copy (different ECDH shared secrets)

### 7.4 Server Storage

The backend stores the encrypted content blob as-is in the `session_events.content` column (TEXT/JSON). It cannot decrypt it. The backend only reads the plaintext `payload` for:
- Routing WS messages to subscribed iOS connections
- Triggering push notifications
- Computing session summaries
- Updating turn counts and tool info

### 7.5 AES-256-GCM Encryption

```swift
static func encrypt(_ plaintext: String, key: SymmetricKey) throws -> String {
    let data = plaintext.data(using: .utf8)!
    let sealedBox = try AES.GCM.seal(data, using: key)
    let combined = sealedBox.combined!  // nonce (12) + ciphertext + tag (16)
    return combined.base64EncodedString()
}
```

**Output**: `base64(nonce || ciphertext || tag)`
- Nonce: 12 bytes (random, generated by CryptoKit)
- Ciphertext: same length as plaintext
- Tag: 16 bytes (GCM authentication tag)
- Minimum combined: 28 bytes → 40+ base64 characters

---

## 8. Decryption Flow (iOS)

### 8.1 Two Decryption Paths

Events reach iOS via two channels:
1. **WebSocket** (real-time) — decrypted inline by the `contentDecryptor` closure
2. **REST API** (on-demand, e.g., opening a session) — decrypted by `SessionStore.decryptEvents()`

### 8.2 WebSocket Content Decryptor

**File**: `AFK/Services/SessionStore.swift` — `setupE2EEDecryptor()`

```swift
wsService.contentDecryptor = { [weak self] (content, sessionId) in
    guard let self else {
        return Self.sanitizeCiphertext(content)
    }
    guard let key = self.e2eeSessionKeys[sessionId] else {
        let extracted = Self.extractMyContent(content, myDeviceId: self.myDeviceId)
        return Self.sanitizeCiphertext(extracted)
    }
    return Self.decryptContentFields(content, key: key, myDeviceId: self.myDeviceId)
}
```

This closure is called by WebSocketService for every incoming event before it's stored.

### 8.3 REST Event Decryption

When the user opens a session detail view:

```
SessionDetailView .task {
    await sessionStore.loadEvents(for: sessionId)
}

loadEvents(for sessionId):
  1. ensureE2EEKey(for: session)
     └─ Look up deviceKAKeys[session.deviceId]
     └─ Derive and cache session key
  2. syncService.syncEvents(for: sessionId)
     └─ Fetch events from REST API
  3. decryptEvents(events, sessionId)          ← Fast path
     └─ If any fields still show [encrypted]:
        decryptEventsWithFallback(events, sessionId)  ← Multi-stage fallback
```

### 8.4 Content Extraction (Multi-Peer Format)

Before decrypting, iOS must extract its own content from the multi-peer format:

```swift
static func extractMyContent(_ content: [String: String], myDeviceId: String?) -> [String: String] {
    let prefix = "\(myId):"

    // Check if any key is prefixed with our device ID
    guard content.keys.contains(where: { $0.hasPrefix(prefix) }) else {
        // Detect if this is multi-peer format for OTHER devices only
        let looksMultiPeer = content.keys.contains { key in
            let colonIdx = key.firstIndex(of: ":")
            return colonIdx != nil && key.distance(from: key.startIndex, to: colonIdx!) >= 36
        }
        return looksMultiPeer ? [:] : content  // empty if multi-peer but not for us
    }

    // Strip prefix: "deviceId:fieldName" → "fieldName"
    var myContent: [String: String] = [:]
    for (k, v) in content where k.hasPrefix(prefix) {
        myContent[String(k.dropFirst(prefix.count))] = v
    }
    return myContent
}
```

### 8.5 Multi-Stage Fallback Decryption

**File**: `SessionStore.swift` — `decryptEventsWithFallback()`

When the fast path fails (some fields show `[encrypted]`), the system tries progressively more expensive recovery strategies:

```
Stage 1: CACHED KEY (fast path)
  └─ Use e2eeSessionKeys[sessionId]
  └─ Decrypt with cached session key
  └─ If all fields decrypted → DONE

Stage 2: REFETCH CURRENT PEER KEY
  └─ GET /v1/devices/{deviceId}/key-agreement
  └─ Compare with cached key
  └─ If different → re-derive session key, retry
  └─ If all fields decrypted → DONE

Stage 3: HISTORICAL SENDER KEY LOOKUP
  └─ For each still-encrypted field:
       Parse versioned wire format to get senderKeyVersion + senderDeviceId
       └─ Check historicalSessionKeys cache first (both v1 and v2 derivation)
       └─ If key cached but decrypt fails → skip (don't refetch same key from API)
       └─ GET /v1/devices/{senderDeviceId}/key-agreement/{senderKeyVersion}
       └─ Try V1 derivation: HKDF(ECDH(my, historical_peer), sessionId, "v1")
       └─ Try V2 derivation: HKDF(ECDH(my, historical_peer) || ECDH(my, eph), sessionId, "v2")
       └─ Cache derived keys for subsequent fields with same version

Stage 3b: HISTORICAL RECEIVER KEY LOOKUP (e2 format only)
  └─ For e2-format blobs where receiverKeyVersion ≠ current key version:
       └─ Check receiver historical key caches (both v1 and v2)
       └─ If key cached but decrypt fails → skip
       └─ Load archived private key from Keychain: DeviceKeyPair.loadHistorical(version)
       └─ Create temporary E2EEService with historical private key
       └─ Try V1 and V2 derivation with sender's public key
       └─ Cache derived keys for subsequent fields

Stage 4: GIVE UP
  └─ Show "[encrypted]" to user
  └─ This happens when no historical key combination can decrypt the content
```

**Cache short-circuit**: Stages 3 and 3b check if a key is already cached before making API calls or loading from Keychain. If the key exists in cache but decryption still fails, the field is marked `[encrypted]` immediately. This prevents the iOS app from making redundant API calls (previously, every undecryptable field would trigger a separate API request for the same historical key).

**Stage 3b key archival**: When iOS rotates its key, the old private key is archived in Keychain under `device-key-agreement-private-v{version}`. Stage 3b loads these archived keys to decrypt content that was encrypted for a previous key version.

### 8.6 Ciphertext Detection & Sanitization

Values that look like ciphertext but can't be decrypted are replaced with `"[encrypted]"`:

```swift
static func looksLikeCiphertext(_ value: String) -> Bool {
    guard value.count >= 40 else { return false }  // AES-GCM minimum: 28 bytes → 40 base64 chars
    let base64Chars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/="))
    return value.unicodeScalars.allSatisfy { base64Chars.contains($0) }
}

static func sanitizeCiphertext(_ content: [String: String]) -> [String: String] {
    content.mapValues { v in
        (v.hasPrefix("e1:") || looksLikeCiphertext(v)) ? "[encrypted]" : v
    }
}
```

### 8.7 AES-256-GCM Decryption

```swift
static func decrypt(_ ciphertext: String, key: SymmetricKey) throws -> String {
    let combined = Data(base64Encoded: ciphertext)!
    let sealedBox = try AES.GCM.SealedBox(combined: combined)
    let decryptedData = try AES.GCM.open(sealedBox, using: key)
    return String(data: decryptedData, encoding: .utf8)!
}
```

If the key is wrong, `AES.GCM.open` throws `CryptoKit.CryptoKitError.authenticationFailure` — the GCM tag doesn't match, so the ciphertext is rejected without producing garbage output.

---

## 9. Prompt Encryption (iOS → Agent)

### 9.1 iOS Encrypts the Prompt

When iOS sends a "continue" or "new chat" command, it can encrypt the prompt:

```swift
// SessionStore.swift
func encryptPrompt(_ prompt: String, sessionId: String) -> String? {
    guard let key = e2eeSessionKeys[sessionId] else { return nil }
    if let deviceId = myDeviceId {
        let keyVersion = myKeyVersion ?? 1
        return try? E2EEService.encryptVersioned(
            prompt, key: key,
            keyVersion: keyVersion,
            senderDeviceId: deviceId
        )
    }
    return try? E2EEService.encrypt(prompt, key: key)
}
```

The encrypted prompt is sent alongside the plaintext prompt in the REST body:
```json
{
  "prompt": "plaintext prompt",
  "promptEncrypted": "e1:34:aa36750f-...:base64(...)",
  "nonce": "uuid",
  "expiresAt": 1234567890
}
```

### 9.2 REST Endpoints

- **Continue session**: `POST /v2/sessions/{sessionId}/continue`
- **New chat**: `POST /v1/commands/new`

Both accept `promptEncrypted` alongside `prompt`.

### 9.3 Agent Receives and Decrypts

The backend forwards the command to the agent via WebSocket. The agent's `CommandExecutor` receives the request and decrypts the prompt using its own session key derivation (same ECDH shared secret, same HKDF parameters, same session ID).

---

## 10. Key Rotation & Broadcast

### 10.1 When Keys Rotate

Keys rotate when:
- iOS's Keychain key is lost and regenerated (unintentional rotation)
- `DeviceKeyPair.rotate()` is called (intentional rotation, not currently triggered by UI)
- Agent regenerates its key (rare, only on re-enrollment with key change)

### 10.2 Rotation Flow

```
Device generates new key
  └─ Calls POST /v1/devices/{id}/key-agreement with new publicKey

Backend HandleRegisterKey:
  ├─ Idempotent check: if key unchanged → return {unchanged: true}
  ├─ UPDATE device_keys SET active=0, revoked_at=NOW() WHERE device_id=? AND active=1
  ├─ newVersion = device.keyVersion + 1
  ├─ UPDATE devices SET key_agreement_public_key=?, key_version=?
  ├─ INSERT INTO device_keys (version=newVersion, publicKey, active=1)
  └─ hub.BroadcastToAll(userID, "device.key_rotated")
       ├─ Sends to ALL iOS WebSocket connections
       └─ Sends to ALL Agent WebSocket connections
```

### 10.3 iOS Handles Rotation (Peer Key Changed)

```swift
// SessionStore.swift — onDeviceKeyRotated
wsService.onDeviceKeyRotated = { (deviceId, newPublicKey, keyVersion) in
    // Update cached KA key
    deviceKAKeys[deviceId] = newPublicKey

    // Invalidate all session keys derived from this device's old key
    for session in sessions where session.deviceId == deviceId {
        e2eeSessionKeys.removeValue(forKey: session.id)
    }

    // Clear permission signing key for this device
    permissionSigningKeys.removeValue(forKey: deviceId)
}
```

Next time an event arrives for those sessions, new session keys are derived using the updated peer key.

### 10.4 Agent Handles Rotation (Peer Key Changed)

```swift
// Agent.swift — handleDeviceKeyRotated
private func handleDeviceKeyRotated(_ msg: WSMessage) async {
    // Parse payload: deviceId, keyVersion, publicKey
    // Re-run full setupE2EEEncryptor() to:
    //   - Refetch all device keys from API
    //   - Rebuild SessionKeyCache with fresh peer keys
    //   - Re-wire content encryptor
    await setupE2EEEncryptor(deviceId: deviceId)
}
```

### 10.5 Own Key Change (iOS)

When iOS detects its own key fingerprint changed during enrollment:

```swift
// AFKApp.swift
if lastFingerprint != currentFingerprint {
    sessionStore.reinitializeE2EE()  // Clear all derived keys
    try await apiClient.registerKeyAgreement(deviceId: myDeviceId!, publicKey: keyPair.publicKeyBase64)
}
```

`reinitializeE2EE()`:
```swift
func reinitializeE2EE() {
    e2eeService = E2EEService()           // New service with current key pair
    e2eeSessionKeys.removeAll()           // All session keys invalid (different private key)
    historicalSessionKeys.removeAll()
    permissionSigningKeys.removeAll()
    setupE2EEDecryptor()                  // Re-wire WS decryptor
}
```

### 10.6 Refresh on Reconnect

When WS reconnects (e.g., app returns from background):

```swift
wsService.onReconnect = {
    await self.refreshDeviceKAKeys()  // Fetch latest device keys from API
    await self.loadSessions()          // Reload sessions with fresh keys
}
```

`refreshDeviceKAKeys()` compares new keys with cached ones and invalidates session keys for any devices whose KA key changed.

---

## 11. Permission HMAC Signing

Permission responses (approve/deny tool use) are signed with an E2EE-derived key to prevent tampering.

### 11.1 Derive Permission Key

```swift
// E2EEService.swift
private static let permissionInfo = "afk-permission-hmac-v1".data(using: .utf8)!

func derivePermissionKey(peerPublicKeyBase64: String, deviceId: String) throws -> SymmetricKey {
    let shared = try deriveSharedSecret(peerPublicKeyBase64: peerPublicKeyBase64)
    let salt = deviceId.data(using: .utf8)!
    return shared.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: salt,
        sharedInfo: Self.permissionInfo,  // "afk-permission-hmac-v1"
        outputByteCount: 32
    )
}
```

**Domain separation**: Uses `"afk-permission-hmac-v1"` as HKDF info, different from content encryption's `"afk-e2ee-content-v1"`. Same ECDH shared secret, different derived keys. Salt is the agent's `deviceId` (not sessionId).

### 11.2 Sign Permission Response

```swift
// PermissionRequest.swift
static func sign(nonce: String, action: String, expiresAt: Int64, key: SymmetricKey) -> String {
    let message = "\(nonce)|\(action)|\(expiresAt)"
    let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
    return Data(signature).map { String(format: "%02x", $0) }.joined()
}
```

**Canonical string**: `"nonce|action|expiresAt"` (e.g., `"abc123|allow|1706000000"`)

### 11.3 Full Permission Flow

```
Agent → (WS) → iOS: PermissionRequest { sessionId, toolName, toolInput, nonce, expiresAt, deviceId }
iOS shows permission dialog
User taps Allow/Deny
iOS:
  1. Derive permission key: HKDF(sharedSecret, agentDeviceId, "afk-permission-hmac-v1")
  2. Sign: HMAC-SHA256("nonce|action|expiresAt", key)
  3. Send PermissionResponse { nonce, action, signature, deviceId }
iOS → (WS) → Agent
Agent:
  1. Derive same permission key: HKDF(sharedSecret, ownDeviceId, "afk-permission-hmac-v1")
  2. Verify HMAC signature
  3. If valid → apply permission decision
```

### 11.4 Fallback Key

If the E2EE key exchange hasn't completed, iOS falls back to a deterministic key:

```swift
let fallbackData = "afk-permission-\(deviceId)".data(using: .utf8)!
return SymmetricKey(data: SHA256.hash(data: fallbackData))
```

This is weaker but allows permissions to work before E2EE is fully set up.

---

## 12. Privacy Modes

### 12.1 Available Modes

| Mode | Content stored on server? | Content encrypted? | E2EE required? |
|------|--------------------------|--------------------|--------------------|
| `telemetry_only` | Yes | No | No |
| `relay_only` | No (WS relay only) | No | No |
| `encrypted` | Yes | Yes (AES-256-GCM) | Yes |

### 12.2 Configuration

Privacy mode is set per-device and configured in the agent's config:

```swift
// Agent.swift
let privacyMode = config.privacyMode(for: projectPath)
```

The mode is communicated to the backend and affects how events are handled:

- **telemetry_only**: Content extracted from JSONL, stored in plaintext in DB
- **relay_only**: Content extracted, relayed via WS to iOS, NOT persisted in DB
- **encrypted**: Content encrypted on agent before sending, stored encrypted in DB

### 12.3 Agent Encryption Check

```swift
// EventNormalizer.swift
private func maybeEncryptContent(
    _ content: [String: String]?,
    privacyMode: String,
    sessionId: String
) -> [String: String]? {
    guard let content, privacyMode == "encrypted", let encryptor = contentEncryptor else {
        return content
    }
    return encryptor(content, sessionId)
}
```

Encryption only happens when `privacyMode == "encrypted"` AND the content encryptor is wired up (peer keys available).

---

## 13. Error Handling & Recovery

### 13.1 Keychain Race Condition Prevention

**Problem**: The original "delete then SecItemAdd" pattern in `KeychainService.save()` had a window where a concurrent `load()` would return nil — the item was deleted but not yet re-added.

**Fix**: `KeychainService.swift` now:
1. Uses `NSLock` to serialize all operations
2. Tries `SecItemUpdate` first (atomic, no delete gap)
3. Falls back to delete + SecItemAdd only if item doesn't exist yet

```swift
func save(_ data: Data, forKey key: String) throws {
    Self.lock.lock()
    defer { Self.lock.unlock() }

    // Try update first (avoids delete+add race window)
    let updateStatus = SecItemUpdate(query, [kSecValueData: data])
    if updateStatus == errSecSuccess { return }

    // Item doesn't exist — delete stale + add fresh (under lock)
    SecItemDelete(query)
    let status = SecItemAdd(addQuery, nil)
    guard status == errSecSuccess else { throw ... }
}
```

### 13.2 Backup Key Recovery

If the primary Keychain entry (`device-key-agreement-private`) is lost:

```
DeviceKeyPair.loadOrCreate():
  1. Try primary → nil
  2. Try backup ("device-key-agreement-private-backup") → found!
  3. Restore primary from backup
  4. Return recovered key (same fingerprint, same ECDH shared secrets)
```

This prevents the catastrophic scenario where key regeneration makes all historical content permanently unreadable.

### 13.3 E2EE Reinitialization

When the iOS key changes (fingerprint mismatch detected):

```swift
sessionStore.reinitializeE2EE()
```

This:
- Creates a new `E2EEService` with the current key pair
- Clears ALL cached session keys (derived from old private key)
- Clears all historical session keys
- Clears all permission signing keys
- Re-wires the WS content decryptor

### 13.4 Fingerprint-Based Change Detection

Both iOS and Agent compare fingerprints to detect key changes without full key comparison:

```
iOS:  UserDefaults "afk_last_registered_ka_fingerprint" vs current fingerprint
Agent: Keychain "last-registered-ka-fingerprint" vs current fingerprint
```

If they differ → re-register with backend, trigger rotation broadcast.

### 13.5 Graceful Degradation

When decryption fails at any stage:
- Ciphertext-looking values → replaced with `"[encrypted]"`
- Plaintext values → shown as-is
- Mixed content → each field handled independently

---

## 14. Wire Formats

### 14.1 Legacy Format

```
base64(nonce || ciphertext || tag)
```

- Nonce: 12 bytes
- Ciphertext: variable
- Tag: 16 bytes
- No metadata about sender or key version

### 14.2 Versioned Format (e1)

```
e1:<senderKeyVersion>:<senderDeviceId>:<base64(nonce || ciphertext || tag)>
```

**Example**:
```
e1:2:8c5988db-fb6b-4902-88f5-0ea364e6232e:NiP5j4F2zQTk/3g8a9pBrX7q...==
```

**Components**:
- `e1` — format version 1
- `2` — sender's key version at time of encryption
- `8c5988db-...` — sender's device ID
- `NiP5j4F2...` — base64 encoded AES-GCM output

Used with V1 session key derivation (long-term keys only).

### 14.3 Forward-Secret Format (e2)

```
e2:<senderKeyVersion>:<senderDeviceId>:<receiverKeyVersion>:<base64(nonce || ciphertext || tag)>
```

**Example**:
```
e2:1:dce61c85-e541-4972-84cf-20e05e6c9f54:1:uQsgh4hG1xmir4C98icwYI...==
```

**Components**:
- `e2` — format version 2 (forward-secret)
- `1` — sender's KA key version
- `dce61c85-...` — sender's device ID
- `1` — receiver's KA key version (enables Stage 3b receiver key fallback)
- `uQsgh4hG...` — base64 encoded AES-GCM output

Used with V2 session key derivation (long-term + ephemeral keys). The receiver key version enables Stage 3b: if the receiver's key has been rotated, the decryptor can identify which historical private key to use.

**Parsing**:
```swift
static func parseEncryptedValue(_ value: String) -> EncryptedBlob {
    if value.hasPrefix("e2:") {
        let parts = value.split(separator: ":", maxSplits: 4)
        if parts.count == 5,
           let senderKeyVer = Int(parts[1]),
           let receiverKeyVer = Int(parts[3]) {
            return EncryptedBlob(version: 2, senderKeyVersion: senderKeyVer,
                                 senderDeviceId: String(parts[2]),
                                 receiverKeyVersion: receiverKeyVer,
                                 ciphertext: String(parts[4]))
        }
    }
    if value.hasPrefix("e1:") {
        let parts = value.split(separator: ":", maxSplits: 3)
        if parts.count == 4, let keyVersion = Int(parts[1]) {
            return EncryptedBlob(version: 1, senderKeyVersion: keyVersion,
                                 senderDeviceId: String(parts[2]),
                                 receiverKeyVersion: nil,
                                 ciphertext: String(parts[3]))
        }
    }
    // Legacy or unparseable
    return EncryptedBlob(version: nil, senderKeyVersion: nil,
                         senderDeviceId: nil, receiverKeyVersion: nil, ciphertext: value)
}
```

### 14.4 Multi-Peer Content Format

Event content dict with device-prefixed keys:

```json
{
  "<receiverDeviceId_1>:<fieldName>": "<versioned_ciphertext>",
  "<receiverDeviceId_1>:<fieldName2>": "<versioned_ciphertext>",
  "<receiverDeviceId_2>:<fieldName>": "<versioned_ciphertext>",
  "<receiverDeviceId_2>:<fieldName2>": "<versioned_ciphertext>"
}
```

Each receiver device gets its own encrypted copy of each field, using a different session key (from different ECDH shared secrets).

---

## 15. Database Schema

### 15.1 devices table (relevant columns)

```sql
key_agreement_public_key TEXT    -- Current active Curve25519 public key (base64)
key_version INTEGER DEFAULT 1   -- Current key version (bumped on each rotation)
```

### 15.2 device_keys table

```sql
CREATE TABLE device_keys (
    id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(id),
    key_type TEXT NOT NULL,           -- "key_agreement"
    public_key TEXT NOT NULL,         -- base64 Curve25519 public key
    version INTEGER NOT NULL DEFAULT 1,
    active INTEGER NOT NULL DEFAULT 1,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    revoked_at DATETIME               -- NULL if active, timestamp if revoked
);
CREATE INDEX idx_device_keys_device_id ON device_keys(device_id);
```

**Key behaviors**:
- Old keys are **marked inactive** (NOT deleted) — `active=0, revoked_at=NOW()`
- All historical versions are preserved for Stage 3 fallback decryption
- New keys inserted with `active=1`

### 15.3 session_events table (relevant columns)

```sql
content TEXT    -- Encrypted JSON dict (multi-peer format), stored as-is by backend
payload TEXT    -- Plaintext JSON dict with telemetry metadata
```

**Note**: Neither the sessions table nor the events table tracks which key version was active at creation time. This is a known limitation (see [Known Limitations](#17-known-limitations)).

---

## 16. API Endpoints

### E2EE Key Exchange

| Method | Path | Handler | Purpose |
|--------|------|---------|---------|
| POST | `/v1/devices/{id}/key-agreement` | HandleRegisterKey | Register/rotate KA public key |
| GET | `/v1/devices/{id}/key-agreement` | HandleGetPeerKey | Get peer's current KA key |
| GET | `/v1/devices/{id}/key-agreement/{version}` | HandleGetPeerKeyByVersion | Get historical KA key by version |

### Device Management

| Method | Path | Handler | Purpose |
|--------|------|---------|---------|
| POST | `/v1/devices` | HandleCreate | Enroll device (includes optional KA key) |
| GET | `/v1/devices` | HandleList | List all devices (includes KA keys) |

### Commands (carry encrypted prompts)

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/v2/sessions/{id}/continue` | Continue session (with optional `promptEncrypted`) |
| POST | `/v1/commands/new` | New chat (with optional `promptEncrypted`) |

---

## 17. Known Limitations

### 17.1 Receiver Key Loss is Catastrophic

If the iOS private key is regenerated (Keychain loss), ALL historical content encrypted for that device becomes permanently unreadable. The ECDH shared secret changes, and the old private key is gone. Stage 3 fallback only handles sender key changes.

**Mitigations**: Backup key in Keychain, thread-safe Keychain operations, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

### 17.2 No Session-Level Key Version Tracking

The sessions table does not store which device key versions were active when the session was created. If a device's key rotates mid-session, there's no record of the transition. The wire format (e1/e2) carries version metadata per-field, which is used for fallback decryption.

### 17.3 Forward Secrecy Scope

V2 session key derivation provides forward secrecy per-session via ephemeral keys. Compromising a long-term key alone is not sufficient to decrypt V2 content (the ephemeral key is also needed). However, if both the long-term key AND the ephemeral key for a session are compromised, that session's content is exposed. A ratcheting protocol would provide stronger guarantees but is not currently implemented.

### 17.4 Single-Device Key Per User

Each iOS device has one KA key pair. If a user has multiple iOS devices, each has an independent key pair and the agent encrypts content for each separately (multi-peer format).

### 17.5 Startup Order Independence

E2EE requires both peers to know each other's KA public keys. This is handled via:
- **Enrollment broadcast**: When a device enrolls with a KA key, the backend broadcasts `device.key_rotated` to all connected peers, who then refetch keys and enable E2EE.
- **Key caching on connect**: Both iOS and agent fetch the device list on startup to cache peer KA keys.
- If neither peer has connected yet, E2EE activates as soon as both have exchanged keys (via enrollment broadcast or device list fetch).
