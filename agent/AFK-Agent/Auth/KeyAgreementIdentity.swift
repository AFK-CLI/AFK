import Foundation
import CryptoKit
import OSLog

/// Manages the agent's Curve25519 KeyAgreement key pair for E2EE.
/// Separate from the Ed25519 signing key in DeviceIdentity.
struct KeyAgreementIdentity: Sendable {
    private static let keychainKey = "device-key-agreement-private"
    private static let backupKeychainKey = "device-key-agreement-private-backup"

    let privateKey: Curve25519.KeyAgreement.PrivateKey

    var publicKeyBase64: String {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Load key from keychain, trying primary then backup.
    /// Performs integrity check against stored fingerprint and auto-recovers from backup if needed.
    static func load(from keychain: KeychainStore) throws -> KeyAgreementIdentity? {
        // Try primary
        if let data = try? keychain.loadData(forKey: keychainKey) {
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
            let identity = KeyAgreementIdentity(privateKey: key)

            // Ensure backup exists
            if (try? keychain.loadData(forKey: backupKeychainKey)) == nil {
                try? keychain.saveData(key.rawRepresentation, forKey: backupKeychainKey)
                AppLogger.e2ee.info("KA backup created for primary key")
            }

            // Integrity check against stored fingerprint
            if let storedFPData = try? keychain.loadData(forKey: "last-registered-ka-fingerprint"),
               let storedFP = String(data: storedFPData, encoding: .utf8) {
                let loadedFP = fingerprint(of: key.publicKey.rawRepresentation.base64EncodedString())
                if loadedFP != storedFP {
                    AppLogger.e2ee.error("KA INTEGRITY CHECK FAILED: loaded=\(loadedFP, privacy: .public) registered=\(storedFP, privacy: .public)")
                    // Try backup
                    if let backupData = try? keychain.loadData(forKey: backupKeychainKey),
                       let backupKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: backupData) {
                        let backupFP = fingerprint(of: backupKey.publicKey.rawRepresentation.base64EncodedString())
                        if backupFP == storedFP {
                            try keychain.saveData(backupData, forKey: keychainKey)
                            AppLogger.e2ee.warning("KA key restored from backup after integrity failure")
                            return KeyAgreementIdentity(privateKey: backupKey)
                        }
                    }
                    AppLogger.e2ee.error("KA both primary and backup corrupted — caller must regenerate")
                    return nil
                } else {
                    AppLogger.e2ee.debug("KA key integrity check passed: fingerprint=\(loadedFP, privacy: .public)")
                }
            }

            AppLogger.e2ee.debug("KA key loaded from primary")
            return identity
        }

        // Try backup
        if let backupData = try? keychain.loadData(forKey: backupKeychainKey) {
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: backupData)
            // Restore primary
            try keychain.saveData(backupData, forKey: keychainKey)
            AppLogger.e2ee.warning("KA key recovered from backup — primary was missing")
            return KeyAgreementIdentity(privateKey: key)
        }

        // Neither found
        return nil
    }

    /// Generate a new key pair.
    static func generate() -> KeyAgreementIdentity {
        KeyAgreementIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
    }

    /// Save to Keychain (primary + backup).
    func save(to keychain: KeychainStore) throws {
        let data = privateKey.rawRepresentation
        try keychain.saveData(data, forKey: Self.keychainKey)
        try keychain.saveData(data, forKey: Self.backupKeychainKey)
        AppLogger.e2ee.info("KA key saved to primary + backup")
    }

    // MARK: - Key Archival

    /// Archive the current key before rotation.
    static func archiveCurrentKey(version: Int, keychain: KeychainStore) {
        guard let data = try? keychain.loadData(forKey: keychainKey) else {
            AppLogger.e2ee.warning("KA no current key to archive")
            return
        }
        let archiveKey = "\(keychainKey)-v\(version)"
        do {
            try keychain.saveData(data, forKey: archiveKey)
            if let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
                let fp = fingerprint(of: key.publicKey.rawRepresentation.base64EncodedString())
                AppLogger.e2ee.info("KA key archived: version=\(version, privacy: .public) fingerprint=\(fp, privacy: .public)")
            }
        } catch {
            AppLogger.e2ee.error("KA failed to archive key v\(version, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Load a historical key by version.
    static func loadHistorical(version: Int, from keychain: KeychainStore) -> Curve25519.KeyAgreement.PrivateKey? {
        let archiveKey = "\(keychainKey)-v\(version)"
        guard let data = try? keychain.loadData(forKey: archiveKey) else {
            AppLogger.e2ee.debug("KA no archived key for version \(version, privacy: .public)")
            return nil
        }
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) else {
            AppLogger.e2ee.error("KA archived key v\(version, privacy: .public) corrupted")
            return nil
        }
        AppLogger.e2ee.debug("KA loaded archived key: version=\(version, privacy: .public)")
        return key
    }

    /// Remove old archived keys, keeping the last `keepCount` versions.
    static func pruneArchivedKeys(currentVersion: Int, keepCount: Int = 3, keychain: KeychainStore) {
        let oldestToKeep = currentVersion - keepCount
        guard oldestToKeep > 0 else { return }
        for v in max(1, oldestToKeep - 5)...oldestToKeep {
            let archiveKey = "\(keychainKey)-v\(v)"
            try? keychain.deleteToken(forKey: archiveKey)
            AppLogger.e2ee.debug("KA pruned archived key: version=\(v, privacy: .public)")
        }
    }

    // MARK: - Fingerprint

    /// Compute a short hex fingerprint (first 4 bytes of SHA-256) for integrity checks and logging.
    private static func fingerprint(of publicKeyBase64: String) -> String {
        guard let data = Data(base64Encoded: publicKeyBase64) else { return "invalid" }
        let hash = SHA256.hash(data: data)
        return Array(hash).prefix(4).map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}
