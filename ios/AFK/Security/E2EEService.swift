import Foundation
import CryptoKit
import OSLog

/// End-to-end encryption service for AFK content.
///
/// Key exchange protocol:
///   iOS:   Curve25519.KeyAgreement.PrivateKey stored in Keychain
///   Agent: Curve25519.KeyAgreement.PrivateKey stored in Keychain
///   Both public keys registered in device record on backend
///
///   Shared secret: ECDH(my_private, their_public) -> same 32 bytes
///   Per-session key: HKDF-SHA256(ikm: sharedSecret, salt: sessionId, info: "afk-e2ee-content-v1")
///   Encryption: AES-256-GCM(plaintext, key: sessionKey, nonce: random 12 bytes)
///   Wire format: base64(nonce || ciphertext || tag)
///
/// Only the `content` field of events is encrypted. `payload` (telemetry: event types,
/// tool names, turn indices) stays plaintext for routing, push triggers, and summaries.
struct E2EEService {
    private static let info = "afk-e2ee-content-v1".data(using: .utf8)!
    private static let infoV2 = "afk-e2ee-content-v2".data(using: .utf8)!

    private let deviceKeyPair: DeviceKeyPair

    init(deviceKeyPair: DeviceKeyPair = .loadOrCreate()) {
        self.deviceKeyPair = deviceKeyPair
    }

    // MARK: - Key Agreement

    /// Derive a shared secret from our private key and the peer's public key.
    func deriveSharedSecret(peerPublicKeyBase64: String) throws -> SharedSecret {
        guard let peerKeyData = Data(base64Encoded: peerPublicKeyBase64) else {
            throw E2EEError.invalidPeerKey
        }
        let peerPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKeyData)
        return try deviceKeyPair.privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
    }

    /// Derive a per-session symmetric key from the shared secret.
    func deriveSessionKey(sharedSecret: SharedSecret, sessionId: String) -> SymmetricKey {
        let salt = sessionId.data(using: .utf8)!
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Self.info,
            outputByteCount: 32
        )
    }

    /// Convenience: derive session key directly from peer public key.
    func sessionKey(peerPublicKeyBase64: String, sessionId: String) throws -> SymmetricKey {
        let shared = try deriveSharedSecret(peerPublicKeyBase64: peerPublicKeyBase64)
        return deriveSessionKey(sharedSecret: shared, sessionId: sessionId)
    }

    /// Derive a forward-secret session key (v2) using both long-term and ephemeral peer keys.
    /// iOS computes ECDH(ios_lt_priv, agent_lt_pub) || ECDH(ios_lt_priv, agent_eph_pub)
    /// then HKDF(combined, salt: sessionId, info: "afk-e2ee-content-v2").
    func deriveSessionKeyV2(
        peerPublicKeyBase64: String,       // Agent's long-term public key
        ephemeralPublicKeyBase64: String,   // Agent's ephemeral public key (from session)
        sessionId: String
    ) throws -> SymmetricKey {
        guard let peerData = Data(base64Encoded: peerPublicKeyBase64),
              let ephData = Data(base64Encoded: ephemeralPublicKeyBase64) else {
            throw E2EEError.invalidPeerKey
        }
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerData)
        let ephPeerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephData)

        let ltSecret = try deviceKeyPair.privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let ephSecret = try deviceKeyPair.privateKey.sharedSecretFromKeyAgreement(with: ephPeerKey)

        var combinedIKM = Data()
        ltSecret.withUnsafeBytes { combinedIKM.append(contentsOf: $0) }
        ephSecret.withUnsafeBytes { combinedIKM.append(contentsOf: $0) }

        let salt = sessionId.data(using: .utf8)!
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: combinedIKM),
            salt: salt,
            info: Self.infoV2,
            outputByteCount: 32
        )
    }

    // MARK: - Encrypt / Decrypt

    /// Encrypt plaintext content. Returns base64(nonce || ciphertext || tag).
    static func encrypt(_ plaintext: String, key: SymmetricKey) throws -> String {
        guard let data = plaintext.data(using: .utf8) else {
            throw E2EEError.encodingFailed
        }
        let sealedBox = try AES.GCM.seal(data, using: key)
        // combined = nonce (12) + ciphertext + tag (16)
        guard let combined = sealedBox.combined else {
            throw E2EEError.encryptionFailed
        }
        return combined.base64EncodedString()
    }

    /// Decrypt base64(nonce || ciphertext || tag) back to plaintext.
    static func decrypt(_ ciphertext: String, key: SymmetricKey) throws -> String {
        guard let combined = Data(base64Encoded: ciphertext) else {
            throw E2EEError.invalidCiphertext
        }
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        let decryptedData = try AES.GCM.open(sealedBox, using: key)
        guard let plaintext = String(data: decryptedData, encoding: .utf8) else {
            throw E2EEError.decodingFailed
        }
        return plaintext
    }

    /// Encrypt a dictionary of content fields. Each value is individually encrypted.
    static func encryptContent(_ content: [String: String], key: SymmetricKey) throws -> [String: String] {
        var encrypted: [String: String] = [:]
        for (k, v) in content {
            encrypted[k] = try encrypt(v, key: key)
        }
        return encrypted
    }

    /// Decrypt a dictionary of encrypted content fields.
    static func decryptContent(_ content: [String: String], key: SymmetricKey) throws -> [String: String] {
        var decrypted: [String: String] = [:]
        for (k, v) in content {
            do {
                decrypted[k] = try decrypt(v, key: key)
            } catch {
                // If decryption fails, show placeholder instead of raw ciphertext
                AppLogger.e2ee.warning("Failed to decrypt field '\(k, privacy: .public)': \(error, privacy: .public)")
                decrypted[k] = looksLikeCiphertext(v) ? "[encrypted]" : v
            }
        }
        return decrypted
    }

    /// Detect whether a string looks like base64-encoded ciphertext (AES-GCM: nonce+ciphertext+tag >= 28 bytes → 40+ base64 chars).
    static func looksLikeCiphertext(_ value: String) -> Bool {
        guard value.count >= 40 else { return false }
        // Check if the string is pure base64 (A-Z, a-z, 0-9, +, /, =)
        let base64Chars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/="))
        return value.unicodeScalars.allSatisfy { base64Chars.contains($0) }
    }

    // MARK: - Versioned Wire Format

    /// Parsed encrypted blob supporting legacy, v1, and v2 formats.
    struct EncryptedBlob {
        /// Format version: nil for legacy (raw base64), 1 for "e1:...", 2 for "e2:..."
        let version: Int?
        /// Sender's key version (only for versioned format)
        let senderKeyVersion: Int?
        /// Sender's device ID (only for versioned format)
        let senderDeviceId: String?
        /// Receiver's key version (v2 only — identifies which ephemeral key was used)
        let receiverKeyVersion: Int?
        /// The raw base64-encoded ciphertext (nonce || ciphertext || tag)
        let ciphertext: String
    }

    /// Parse an encrypted value into its components.
    /// Supports:
    ///   - Legacy format: raw base64(nonce || ciphertext || tag)
    ///   - V1 format: "e1:<keyVersion>:<senderDeviceId>:<base64(...)>"
    ///   - V2 format: "e2:<senderKeyVersion>:<senderDeviceId>:<receiverKeyVersion>:<base64(...)>"
    static func parseEncryptedValue(_ value: String) -> EncryptedBlob {
        if value.hasPrefix("e2:") {
            let parts = value.split(separator: ":", maxSplits: 4)
            if parts.count == 5,
               let senderKeyVer = Int(parts[1]),
               let receiverKeyVer = Int(parts[3]) {
                return EncryptedBlob(
                    version: 2,
                    senderKeyVersion: senderKeyVer,
                    senderDeviceId: String(parts[2]),
                    receiverKeyVersion: receiverKeyVer,
                    ciphertext: String(parts[4])
                )
            }
        }
        if value.hasPrefix("e1:") {
            let parts = value.split(separator: ":", maxSplits: 3)
            if parts.count == 4,
               let keyVersion = Int(parts[1]) {
                return EncryptedBlob(
                    version: 1,
                    senderKeyVersion: keyVersion,
                    senderDeviceId: String(parts[2]),
                    receiverKeyVersion: nil,
                    ciphertext: String(parts[3])
                )
            }
        }
        // Legacy or unparseable — treat as raw base64
        return EncryptedBlob(version: nil, senderKeyVersion: nil, senderDeviceId: nil, receiverKeyVersion: nil, ciphertext: value)
    }

    /// Encrypt with versioned wire format: "e1:<keyVersion>:<senderDeviceId>:<base64(...)>"
    static func encryptVersioned(_ plaintext: String, key: SymmetricKey, keyVersion: Int, senderDeviceId: String) throws -> String {
        let rawCiphertext = try encrypt(plaintext, key: key)
        return "e1:\(keyVersion):\(senderDeviceId):\(rawCiphertext)"
    }

    /// Encrypt with v2 wire format: "e2:<senderKeyVersion>:<senderDeviceId>:<receiverKeyVersion>:<base64(...)>"
    /// Used when forward-secret (ephemeral) session keys are active.
    static func encryptVersionedV2(_ plaintext: String, key: SymmetricKey,
                                   keyVersion: Int, senderDeviceId: String,
                                   receiverKeyVersion: Int) throws -> String {
        let rawCiphertext = try encrypt(plaintext, key: key)
        return "e2:\(keyVersion):\(senderDeviceId):\(receiverKeyVersion):\(rawCiphertext)"
    }

    /// Decrypt a value that may be in legacy or versioned format.
    /// For versioned format, extracts the raw ciphertext before decrypting.
    static func decryptValue(_ value: String, key: SymmetricKey) throws -> String {
        let blob = parseEncryptedValue(value)
        return try decrypt(blob.ciphertext, key: key)
    }

    /// Decrypt a dictionary of content fields, supporting both legacy and versioned formats.
    static func decryptContentVersioned(_ content: [String: String], key: SymmetricKey) throws -> [String: String] {
        var decrypted: [String: String] = [:]
        var failedFields: [String] = []
        var failureSender: String?
        for (k, v) in content {
            do {
                decrypted[k] = try decryptValue(v, key: key)
            } catch {
                let blob = parseEncryptedValue(v)
                if blob.version != nil || looksLikeCiphertext(blob.ciphertext) {
                    failedFields.append(k)
                    if failureSender == nil, let sv = blob.senderKeyVersion, let sd = blob.senderDeviceId {
                        failureSender = "sender \(sd.prefix(8)) v\(sv)"
                    }
                    decrypted[k] = "[encrypted]"
                } else {
                    // Not ciphertext — keep original value (likely unencrypted plain text)
                    decrypted[k] = v
                }
            }
        }
        if !failedFields.isEmpty {
            let senderInfo = failureSender.map { " (\($0))" } ?? ""
            AppLogger.e2ee.warning("Failed to decrypt \(failedFields.count, privacy: .public) field(s): \(failedFields.joined(separator: ", "), privacy: .public)\(senderInfo, privacy: .public)")
        }
        return decrypted
    }

    // MARK: - Permission Signing

    private static let permissionInfo = "afk-permission-hmac-v1".data(using: .utf8)!

    /// Derive a symmetric key for HMAC-signing permission responses.
    /// Uses a dedicated HKDF info string so it's domain-separated from content encryption keys.
    func derivePermissionKey(peerPublicKeyBase64: String, deviceId: String) throws -> SymmetricKey {
        let shared = try deriveSharedSecret(peerPublicKeyBase64: peerPublicKeyBase64)
        let salt = deviceId.data(using: .utf8)!
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Self.permissionInfo,
            outputByteCount: 32
        )
    }

    // MARK: - Fingerprint

    /// Compute a short fingerprint (first 4 bytes of SHA-256) for a base64-encoded public key.
    /// Format: "ab:cd:ef:12" — useful for log correlation without exposing the full key.
    static func fingerprint(of publicKey: String) -> String {
        guard let data = Data(base64Encoded: publicKey) else { return "invalid" }
        let hash = SHA256.hash(data: data)
        return Array(hash).prefix(4).map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    // MARK: - Public Key

    var publicKeyBase64: String {
        deviceKeyPair.publicKeyBase64
    }
}

enum E2EEError: Error, LocalizedError {
    case invalidPeerKey
    case encodingFailed
    case decodingFailed
    case encryptionFailed
    case invalidCiphertext
    case noPeerKey

    var errorDescription: String? {
        switch self {
        case .invalidPeerKey: "Invalid peer public key"
        case .encodingFailed: "Failed to encode plaintext"
        case .decodingFailed: "Failed to decode decrypted data"
        case .encryptionFailed: "Encryption failed"
        case .invalidCiphertext: "Invalid ciphertext format"
        case .noPeerKey: "No peer key available for this device"
        }
    }
}
