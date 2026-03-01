import Foundation
import Security

struct KeychainService: Sendable {
    private static let serviceName = BuildEnvironment.keychainServiceName
    /// Serializes all Keychain operations to prevent race conditions.
    /// The "delete then add" pattern in save() has a window where load() returns nil
    /// if called between delete and SecItemAdd. This lock prevents that.
    private static let lock = NSLock()

    enum KeychainError: Error {
        case duplicateEntry
        case unexpectedStatus(OSStatus)
        case encodingFailed
    }

    func save(_ data: Data, forKey key: String) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        // Try update first — avoids the delete+add race window
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: key
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)

        if updateStatus == errSecSuccess {
            return // Updated existing item
        }

        if updateStatus != errSecItemNotFound {
            // Unexpected error during update — fall through to delete+add
            print("[Keychain] SecItemUpdate failed for '\(key)': OSStatus \(updateStatus), trying delete+add")
        }

        // Item doesn't exist — delete any stale entry and add fresh
        SecItemDelete(updateQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            print("[Keychain] SecItemAdd failed for '\(key)': OSStatus \(status)")
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func save(_ string: String, forKey key: String) throws {
        guard let data = string.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        try save(data, forKey: key)
    }

    func load(forKey key: String) -> Data? {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                print("[Keychain] SecItemCopyMatching failed for '\(key)': OSStatus \(status)")
            }
            return nil
        }

        return result as? Data
    }

    func loadString(forKey key: String) -> String? {
        guard let data = load(forKey: key) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func delete(forKey key: String) {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceName,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }
}
