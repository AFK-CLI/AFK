import Foundation
import CryptoKit

/// Manages the device's Curve25519 KeyAgreement key pair for E2EE.
/// The private key is stored in the iOS Keychain with a backup copy
/// under a separate key. If the primary key is lost, the backup is
/// used to restore it, preventing permanent loss of encrypted content.
struct DeviceKeyPair {
    private static let keychainKey = "device-key-agreement-private"
    private static let backupKeychainKey = "device-key-agreement-private-backup"
    private static let keychain = KeychainService()

    let privateKey: Curve25519.KeyAgreement.PrivateKey

    var publicKeyBase64: String {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    var publicKeyRaw: Data {
        privateKey.publicKey.rawRepresentation
    }

    /// Load an existing key pair from the Keychain, or generate and save a new one.
    /// Uses a backup key to recover from Keychain losses.
    /// Includes integrity check against last-registered fingerprint.
    static func loadOrCreate() -> DeviceKeyPair {
        // Step 1: Try primary key first
        var loadedPair: DeviceKeyPair? = nil
        if let existing = load() {
            let fp = E2EEService.fingerprint(of: existing.publicKeyBase64)
            print("[DeviceKeyPair] Key loaded from primary: fingerprint=\(fp)")
            loadedPair = existing
        } else if let backup = loadBackup() {
            // Primary key missing — try to recover from backup
            let fp = E2EEService.fingerprint(of: backup.publicKeyBase64)
            print("[DeviceKeyPair] Key loaded from backup (primary missing): fingerprint=\(fp)")
            // Restore primary from backup
            do {
                try keychain.save(backup.privateKey.rawRepresentation, forKey: keychainKey)
                print("[DeviceKeyPair] Restored primary key from backup")
            } catch {
                print("[DeviceKeyPair] WARNING: Failed to restore primary from backup: \(error)")
            }
            loadedPair = backup
        }

        // Step 2: Integrity check against last-registered fingerprint
        if let loaded = loadedPair {
            if let storedFingerprint = BuildEnvironment.userDefaults.string(forKey: "afk_last_registered_ka_fingerprint") {
                let loadedFingerprint = E2EEService.fingerprint(of: loaded.publicKeyBase64)
                if loadedFingerprint != storedFingerprint {
                    print("[DeviceKeyPair] INTEGRITY CHECK FAILED: loaded=\(loadedFingerprint) registered=\(storedFingerprint)")
                    // Try backup
                    if let backupPair = loadBackup() {
                        let backupFingerprint = E2EEService.fingerprint(of: backupPair.publicKeyBase64)
                        if backupFingerprint == storedFingerprint {
                            print("[DeviceKeyPair] Key restored from backup after integrity failure")
                            backupPair.save()
                            return backupPair
                        }
                    }
                    // Both corrupted — must regenerate
                    print("[DeviceKeyPair] Both primary and backup keys corrupted — regenerating")
                    // Fall through to generation below
                } else {
                    print("[DeviceKeyPair] Key integrity check passed: fingerprint=\(loadedFingerprint)")
                    ensureBackup(loaded)
                    return loaded
                }
            } else {
                // No stored fingerprint — first time, skip integrity check
                ensureBackup(loaded)
                return loaded
            }
        }

        // Step 3: No key or integrity failed — generate new one
        let hadDeviceId = BuildEnvironment.userDefaults.string(forKey: "afk_ios_device_id") != nil
        if hadDeviceId {
            print("[DeviceKeyPair] WARNING: Neither primary nor backup key found! Device was previously enrolled.")
            print("[DeviceKeyPair] All previously encrypted content will become permanently unreadable.")
        } else {
            print("[DeviceKeyPair] No existing key — first-time enrollment")
        }
        let kp = DeviceKeyPair(privateKey: Curve25519.KeyAgreement.PrivateKey())
        do {
            try keychain.save(kp.privateKey.rawRepresentation, forKey: keychainKey)
            let fp = E2EEService.fingerprint(of: kp.publicKeyBase64)
            print("[DeviceKeyPair] New key generated: fingerprint=\(fp)")
        } catch {
            print("[DeviceKeyPair] CRITICAL: Failed to save key to Keychain: \(error)")
            print("[DeviceKeyPair] Key exists only in memory — will be lost on next app launch!")
        }
        // Save backup copy
        ensureBackup(kp)
        return kp
    }

    /// Load from Keychain (primary key). Returns nil if not found.
    static func load() -> DeviceKeyPair? {
        guard let data = keychain.load(forKey: keychainKey) else {
            return nil
        }
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) else {
            print("[DeviceKeyPair] Keychain data (\(data.count) bytes) is not a valid Curve25519 key")
            return nil
        }
        return DeviceKeyPair(privateKey: key)
    }

    /// Load backup key from Keychain.
    private static func loadBackup() -> DeviceKeyPair? {
        guard let data = keychain.load(forKey: backupKeychainKey) else { return nil }
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) else { return nil }
        return DeviceKeyPair(privateKey: key)
    }

    /// Ensure backup key exists and matches primary.
    private static func ensureBackup(_ kp: DeviceKeyPair) {
        let existing = loadBackup()
        if existing?.publicKeyBase64 != kp.publicKeyBase64 {
            do {
                try keychain.save(kp.privateKey.rawRepresentation, forKey: backupKeychainKey)
            } catch {
                print("[DeviceKeyPair] WARNING: Failed to save backup key: \(error)")
            }
        }
    }

    /// Save to Keychain.
    func save() {
        do {
            try Self.keychain.save(privateKey.rawRepresentation, forKey: Self.keychainKey)
            print("[DeviceKeyPair] Key saved to keychain")
        } catch {
            print("[DeviceKeyPair] ERROR: Failed to save key to Keychain: \(error)")
        }
    }

    /// Delete from Keychain (for key rotation).
    static func delete() {
        keychain.delete(forKey: keychainKey)
        keychain.delete(forKey: backupKeychainKey)
    }

    // MARK: - Key Archival

    /// Archive the current key before rotation.
    static func archiveCurrentKey(version: Int) {
        guard let currentKeyData = keychain.load(forKey: keychainKey) else {
            print("[DeviceKeyPair] No current key to archive")
            return
        }
        let archiveKey = "\(keychainKey)-v\(version)"
        do {
            try keychain.save(currentKeyData, forKey: archiveKey)
            let fingerprint = E2EEService.fingerprint(
                of: (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: currentKeyData))?.publicKey.rawRepresentation.base64EncodedString() ?? ""
            )
            print("[DeviceKeyPair] Key archived: version=\(version) fingerprint=\(fingerprint)")
        } catch {
            print("[DeviceKeyPair] Failed to archive key v\(version): \(error)")
        }
    }

    /// Load a historical key by version.
    static func loadHistorical(version: Int) -> Curve25519.KeyAgreement.PrivateKey? {
        let archiveKey = "\(keychainKey)-v\(version)"
        guard let data = keychain.load(forKey: archiveKey) else {
            print("[DeviceKeyPair] No archived key for version \(version)")
            return nil
        }
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) else {
            print("[DeviceKeyPair] Archived key v\(version) corrupted")
            return nil
        }
        print("[DeviceKeyPair] Loaded archived key: version=\(version)")
        return key
    }

    /// Remove old archived keys, keeping the last `keepCount` versions.
    static func pruneArchivedKeys(currentVersion: Int, keepCount: Int = 3) {
        let oldestToKeep = currentVersion - keepCount
        guard oldestToKeep > 0 else { return }
        // Safety sweep: try a few extra in case versions were skipped
        for v in max(1, oldestToKeep - 5)...oldestToKeep {
            let archiveKey = "\(keychainKey)-v\(v)"
            keychain.delete(forKey: archiveKey)
            print("[DeviceKeyPair] Pruned archived key: version=\(v)")
        }
    }

    /// Rotate: archive old key, generate new one, save, prune old archives, and return the new pair.
    static func rotate(currentVersion: Int) -> DeviceKeyPair {
        // 1. Archive current key before rotation
        archiveCurrentKey(version: currentVersion)
        // 2. Generate new key
        let newKey = Curve25519.KeyAgreement.PrivateKey()
        let newPair = DeviceKeyPair(privateKey: newKey)
        // 3. Save as primary + backup
        newPair.save()
        ensureBackup(newPair)
        // 4. Prune old archives
        pruneArchivedKeys(currentVersion: currentVersion)
        let fingerprint = E2EEService.fingerprint(of: newPair.publicKeyBase64)
        print("[DeviceKeyPair] Key rotated: new fingerprint=\(fingerprint)")
        return newPair
    }
}
