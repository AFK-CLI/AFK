//
//  Agent+E2EE.swift
//  AFK-Agent
//

import Foundation
import CryptoKit

/// Thread-safe cache of per-session E2EE symmetric keys for multiple peers.
final class SessionKeyCache: @unchecked Sendable {
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

extension Agent {

    // MARK: - E2EE Content Encryption

    func setupE2EEEncryptor(deviceId: String) async {
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

    // MARK: - Device Key Rotation

    func handleDeviceKeyRotated(_ msg: WSMessage) async {
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
}
