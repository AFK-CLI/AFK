import Foundation
import CryptoKit

/// Agent-side E2EE encryption for content fields.
///
/// Key exchange:
///   Shared secret: ECDH(agent_private, ios_public) -> 32 bytes
///   Per-session key: HKDF-SHA256(ikm: sharedSecret, salt: sessionId, info: "afk-e2ee-content-v1")
///   Encryption: AES-256-GCM(plaintext, key: sessionKey, nonce: random 12 bytes)
///   Wire format: base64(nonce || ciphertext || tag)
struct E2EEncryption: Sendable {
    private static let info = "afk-e2ee-content-v1".data(using: .utf8)!
    private static let infoV2 = "afk-e2ee-content-v2".data(using: .utf8)!

    private let identity: KeyAgreementIdentity

    init(identity: KeyAgreementIdentity) {
        self.identity = identity
    }

    /// Derive shared secret from our private key and the iOS device's public key.
    func deriveSharedSecret(peerPublicKeyBase64: String) throws -> SharedSecret {
        guard let peerData = Data(base64Encoded: peerPublicKeyBase64) else {
            throw E2EError.invalidPeerKey
        }
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerData)
        return try identity.privateKey.sharedSecretFromKeyAgreement(with: peerKey)
    }

    /// Derive a per-session symmetric key.
    func deriveSessionKey(sharedSecret: SharedSecret, sessionId: String) -> SymmetricKey {
        let salt = sessionId.data(using: .utf8)!
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Self.info,
            outputByteCount: 32
        )
    }

    /// Convenience: derive session key directly from peer public key + session ID.
    func sessionKey(peerPublicKeyBase64: String, sessionId: String) throws -> SymmetricKey {
        let shared = try deriveSharedSecret(peerPublicKeyBase64: peerPublicKeyBase64)
        return deriveSessionKey(sharedSecret: shared, sessionId: sessionId)
    }

    /// Derive a forward-secret per-session key using both long-term and ephemeral ECDH.
    /// Combined IKM = ECDH(lt_private, peer_public) || ECDH(ephemeral_private, peer_public)
    /// Key = HKDF-SHA256(combinedIKM, salt: sessionId, info: "afk-e2ee-content-v2")
    func deriveSessionKeyV2(
        peerPublicKeyBase64: String,
        ephemeralKey: Curve25519.KeyAgreement.PrivateKey,
        sessionId: String
    ) throws -> SymmetricKey {
        guard let peerData = Data(base64Encoded: peerPublicKeyBase64) else {
            throw E2EError.invalidPeerKey
        }
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerData)

        let ltSecret = try identity.privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let ephSecret = try ephemeralKey.sharedSecretFromKeyAgreement(with: peerKey)

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

    /// Encrypt a string value. Returns base64(nonce || ciphertext || tag).
    static func encrypt(_ plaintext: String, key: SymmetricKey) throws -> String {
        guard let data = plaintext.data(using: .utf8) else {
            throw E2EError.encodingFailed
        }
        let box = try AES.GCM.seal(data, using: key)
        guard let combined = box.combined else {
            throw E2EError.encryptionFailed
        }
        return combined.base64EncodedString()
    }

    /// Encrypt with versioned wire format: e1:<keyVersion>:<senderDeviceId>:<base64(nonce||ciphertext||tag)>
    static func encryptVersioned(_ plaintext: String, key: SymmetricKey, keyVersion: Int, senderDeviceId: String) throws -> String {
        let ciphertext = try encrypt(plaintext, key: key)
        return "e1:\(keyVersion):\(senderDeviceId):\(ciphertext)"
    }

    /// Encrypt with v2 wire format: e2:<keyVersion>:<senderDeviceId>:<receiverKeyVersion>:<base64(nonce||ciphertext||tag)>
    static func encryptVersionedV2(_ plaintext: String, key: SymmetricKey,
        keyVersion: Int, senderDeviceId: String, receiverKeyVersion: Int) throws -> String {
        let ciphertext = try encrypt(plaintext, key: key)
        return "e2:\(keyVersion):\(senderDeviceId):\(receiverKeyVersion):\(ciphertext)"
    }

    /// Encrypt all values in a content dictionary. Keys are preserved, values encrypted.
    static func encryptContent(_ content: [String: String], key: SymmetricKey) throws -> [String: String] {
        var result: [String: String] = [:]
        for (k, v) in content {
            result[k] = try encrypt(v, key: key)
        }
        return result
    }

    // MARK: - Decrypt

    /// Decrypt base64(nonce || ciphertext || tag) back to plaintext string.
    static func decrypt(_ ciphertext: String, key: SymmetricKey) throws -> String {
        guard let combined = Data(base64Encoded: ciphertext) else {
            throw E2EError.decryptionFailed
        }
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        let data = try AES.GCM.open(sealedBox, using: key)
        guard let plaintext = String(data: data, encoding: .utf8) else {
            throw E2EError.decryptionFailed
        }
        return plaintext
    }

    /// Decrypt raw Data from base64(nonce || ciphertext || tag).
    static func decryptData(_ ciphertext: String, key: SymmetricKey) throws -> Data {
        guard let combined = Data(base64Encoded: ciphertext) else {
            throw E2EError.decryptionFailed
        }
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(sealedBox, using: key)
    }

    /// Encrypt raw Data. Returns base64(nonce || ciphertext || tag).
    static func encryptData(_ data: Data, key: SymmetricKey) throws -> String {
        let box = try AES.GCM.seal(data, using: key)
        guard let combined = box.combined else {
            throw E2EError.encryptionFailed
        }
        return combined.base64EncodedString()
    }

    /// Parse a versioned wire format value and extract the raw ciphertext.
    /// Supports: legacy (raw base64), "e1:ver:device:base64", "e2:ver:device:rver:base64"
    static func extractCiphertext(_ value: String) -> String {
        if value.hasPrefix("e2:") {
            let parts = value.split(separator: ":", maxSplits: 4)
            if parts.count == 5 { return String(parts[4]) }
        }
        if value.hasPrefix("e1:") {
            let parts = value.split(separator: ":", maxSplits: 3)
            if parts.count == 4 { return String(parts[3]) }
        }
        return value
    }

    /// Decrypt a versioned wire format value (e1:... or e2:... or legacy base64).
    static func decryptVersioned(_ value: String, key: SymmetricKey) throws -> String {
        let raw = extractCiphertext(value)
        return try decrypt(raw, key: key)
    }

    /// Decrypt versioned wire format value to raw Data.
    static func decryptVersionedData(_ value: String, key: SymmetricKey) throws -> Data {
        let raw = extractCiphertext(value)
        return try decryptData(raw, key: key)
    }

    // MARK: - Permission Signing

    private static let permissionInfo = "afk-permission-hmac-v1".data(using: .utf8)!

    /// Derive a symmetric key for HMAC-verifying permission responses.
    /// Uses a dedicated HKDF info string, domain-separated from content encryption keys.
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

    /// Public key for registration with backend.
    var publicKeyBase64: String {
        identity.publicKeyBase64
    }

    /// Compute a short hex fingerprint (first 4 bytes of SHA-256) for logging.
    static func fingerprint(of publicKey: String) -> String {
        guard let data = Data(base64Encoded: publicKey) else { return "invalid" }
        let hash = SHA256.hash(data: data)
        return Array(hash).prefix(4).map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

enum E2EError: Error {
    case invalidPeerKey
    case encodingFailed
    case encryptionFailed
    case decryptionFailed
}
