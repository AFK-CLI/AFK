import XCTest
import CryptoKit
@testable import AFK_Agent

final class E2EEncryptionTests: XCTestCase {

    // MARK: - Helpers

    /// Create a test KeyAgreementIdentity from a fresh private key.
    private func makeIdentity() -> KeyAgreementIdentity {
        KeyAgreementIdentity.generate()
    }

    /// Create an E2EEncryption instance with a fresh identity.
    private func makeE2E() -> E2EEncryption {
        E2EEncryption(identity: makeIdentity())
    }

    // MARK: - Encrypt / Decrypt Round-Trip

    func testEncryptDecryptRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = "Hello, encrypted world!"
        let ciphertext = try E2EEncryption.encrypt(plaintext, key: key)

        // Decrypt manually
        let combined = Data(base64Encoded: ciphertext)!
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        let decrypted = try AES.GCM.open(sealedBox, using: key)
        let result = String(data: decrypted, encoding: .utf8)
        XCTAssertEqual(result, plaintext)
    }

    func testEncryptProducesDifferentCiphertextEachTime() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = "same message"
        let ct1 = try E2EEncryption.encrypt(plaintext, key: key)
        let ct2 = try E2EEncryption.encrypt(plaintext, key: key)
        XCTAssertNotEqual(ct1, ct2, "Different nonces should produce different ciphertext")
    }

    // MARK: - Versioned Wire Format (e1:)

    func testEncryptVersionedFormat() throws {
        let key = SymmetricKey(size: .bits256)
        let result = try E2EEncryption.encryptVersioned("test", key: key, keyVersion: 3, senderDeviceId: "device-abc")
        XCTAssertTrue(result.hasPrefix("e1:3:device-abc:"))
        // The part after the third colon should be valid base64
        let parts = result.split(separator: ":", maxSplits: 3)
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[0], "e1")
        XCTAssertEqual(parts[1], "3")
        XCTAssertEqual(parts[2], "device-abc")
        XCTAssertNotNil(Data(base64Encoded: String(parts[3])))
    }

    // MARK: - Versioned Wire Format V2 (e2:)

    func testEncryptVersionedV2Format() throws {
        let key = SymmetricKey(size: .bits256)
        let result = try E2EEncryption.encryptVersionedV2(
            "test", key: key, keyVersion: 5, senderDeviceId: "dev-123", receiverKeyVersion: 2
        )
        XCTAssertTrue(result.hasPrefix("e2:5:dev-123:2:"))
        let parts = result.split(separator: ":", maxSplits: 4)
        XCTAssertEqual(parts.count, 5)
        XCTAssertEqual(parts[0], "e2")
        XCTAssertEqual(parts[1], "5")
        XCTAssertEqual(parts[2], "dev-123")
        XCTAssertEqual(parts[3], "2")
    }

    // MARK: - Content Encryption

    func testEncryptContentPreservesKeys() throws {
        let key = SymmetricKey(size: .bits256)
        let content: [String: String] = [
            "userSnippet": "hello",
            "assistantSnippet": "world"
        ]
        let encrypted = try E2EEncryption.encryptContent(content, key: key)
        XCTAssertEqual(Set(encrypted.keys), Set(content.keys))
        XCTAssertNotEqual(encrypted["userSnippet"], "hello")
        XCTAssertNotEqual(encrypted["assistantSnippet"], "world")
    }

    // MARK: - Key Agreement

    func testDeriveSharedSecretIsSymmetric() throws {
        let e2eA = makeE2E()
        let e2eB = makeE2E()

        let sharedA = try e2eA.deriveSharedSecret(peerPublicKeyBase64: e2eB.publicKeyBase64)
        let sharedB = try e2eB.deriveSharedSecret(peerPublicKeyBase64: e2eA.publicKeyBase64)

        // Both sides should derive the same shared secret
        var dataA = Data()
        sharedA.withUnsafeBytes { dataA.append(contentsOf: $0) }
        var dataB = Data()
        sharedB.withUnsafeBytes { dataB.append(contentsOf: $0) }
        XCTAssertEqual(dataA, dataB)
    }

    func testSessionKeyDeterministic() throws {
        let e2eA = makeE2E()
        let e2eB = makeE2E()
        let sessionId = "test-session-123"

        let keyA = try e2eA.sessionKey(peerPublicKeyBase64: e2eB.publicKeyBase64, sessionId: sessionId)
        let keyB = try e2eB.sessionKey(peerPublicKeyBase64: e2eA.publicKeyBase64, sessionId: sessionId)

        // Both sides should derive the same session key
        var dataA = Data()
        keyA.withUnsafeBytes { dataA.append(contentsOf: $0) }
        var dataB = Data()
        keyB.withUnsafeBytes { dataB.append(contentsOf: $0) }
        XCTAssertEqual(dataA, dataB)
    }

    func testDifferentSessionIdProducesDifferentKey() throws {
        let e2eA = makeE2E()
        let e2eB = makeE2E()

        let key1 = try e2eA.sessionKey(peerPublicKeyBase64: e2eB.publicKeyBase64, sessionId: "session-1")
        let key2 = try e2eA.sessionKey(peerPublicKeyBase64: e2eB.publicKeyBase64, sessionId: "session-2")

        var data1 = Data()
        key1.withUnsafeBytes { data1.append(contentsOf: $0) }
        var data2 = Data()
        key2.withUnsafeBytes { data2.append(contentsOf: $0) }
        XCTAssertNotEqual(data1, data2)
    }

    func testInvalidPeerKeyThrows() {
        let e2e = makeE2E()
        XCTAssertThrowsError(try e2e.deriveSharedSecret(peerPublicKeyBase64: "not-valid-base64!!!")) { error in
            XCTAssertTrue(error is E2EError)
        }
    }

    // MARK: - Permission Key Derivation

    func testPermissionKeyDomainSeparated() throws {
        let e2eA = makeE2E()
        let e2eB = makeE2E()
        let deviceId = "agent-device-123"
        let sessionId = "session-abc"

        let permKey = try e2eA.derivePermissionKey(peerPublicKeyBase64: e2eB.publicKeyBase64, deviceId: deviceId)
        let sessionKey = try e2eA.sessionKey(peerPublicKeyBase64: e2eB.publicKeyBase64, sessionId: sessionId)

        var permData = Data()
        permKey.withUnsafeBytes { permData.append(contentsOf: $0) }
        var sessionData = Data()
        sessionKey.withUnsafeBytes { sessionData.append(contentsOf: $0) }
        XCTAssertNotEqual(permData, sessionData, "Permission key and session key must be different")
    }

    // MARK: - Fingerprint

    func testFingerprintFormat() {
        let identity = makeIdentity()
        let fp = E2EEncryption.fingerprint(of: identity.publicKeyBase64)
        // Format: "ab:cd:ef:12" (4 bytes, colon-separated hex)
        let parts = fp.split(separator: ":")
        XCTAssertEqual(parts.count, 4)
        for part in parts {
            XCTAssertEqual(part.count, 2)
        }
    }

    func testFingerprintInvalidKey() {
        let fp = E2EEncryption.fingerprint(of: "not-base64!!!")
        XCTAssertEqual(fp, "invalid")
    }

    func testFingerprintDeterministic() {
        let identity = makeIdentity()
        let fp1 = E2EEncryption.fingerprint(of: identity.publicKeyBase64)
        let fp2 = E2EEncryption.fingerprint(of: identity.publicKeyBase64)
        XCTAssertEqual(fp1, fp2)
    }
}
