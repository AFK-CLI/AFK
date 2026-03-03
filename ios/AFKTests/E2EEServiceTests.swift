import XCTest
import CryptoKit
@testable import AFK

final class E2EEServiceTests: XCTestCase {

    // MARK: - Encrypt / Decrypt Round-Trip

    func testEncryptDecryptRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = "Hello, encrypted world!"

        let ciphertext = try E2EEService.encrypt(plaintext, key: key)
        let decrypted = try E2EEService.decrypt(ciphertext, key: key)

        XCTAssertEqual(decrypted, plaintext)
    }

    func testEncryptDecryptEmptyString() throws {
        let key = SymmetricKey(size: .bits256)
        let ciphertext = try E2EEService.encrypt("", key: key)
        let decrypted = try E2EEService.decrypt(ciphertext, key: key)
        XCTAssertEqual(decrypted, "")
    }

    func testEncryptDecryptUnicodeContent() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = "Hello \u{1F680}\u{1F30D} emoji test \u{2764}\u{FE0F}"
        let ciphertext = try E2EEService.encrypt(plaintext, key: key)
        let decrypted = try E2EEService.decrypt(ciphertext, key: key)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testDifferentNoncesPerEncryption() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = "same message"
        let ct1 = try E2EEService.encrypt(plaintext, key: key)
        let ct2 = try E2EEService.encrypt(plaintext, key: key)
        XCTAssertNotEqual(ct1, ct2, "Each encryption should use a random nonce")
    }

    func testDecryptWithWrongKeyFails() throws {
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let ciphertext = try E2EEService.encrypt("secret", key: key1)
        XCTAssertThrowsError(try E2EEService.decrypt(ciphertext, key: key2))
    }

    // MARK: - Content Encryption

    func testEncryptContentRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let content: [String: String] = [
            "userSnippet": "hello",
            "assistantSnippet": "world",
        ]
        let encrypted = try E2EEService.encryptContent(content, key: key)
        let decrypted = try E2EEService.decryptContent(encrypted, key: key)
        XCTAssertEqual(decrypted["userSnippet"], "hello")
        XCTAssertEqual(decrypted["assistantSnippet"], "world")
    }

    func testEncryptContentPreservesKeys() throws {
        let key = SymmetricKey(size: .bits256)
        let content: [String: String] = ["a": "1", "b": "2"]
        let encrypted = try E2EEService.encryptContent(content, key: key)
        XCTAssertEqual(Set(encrypted.keys), Set(content.keys))
    }

    // MARK: - Versioned Wire Format (e1:)

    func testVersionedEncryptDecrypt() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = "versioned test"
        let versioned = try E2EEService.encryptVersioned(plaintext, key: key, keyVersion: 3, senderDeviceId: "dev-abc")

        XCTAssertTrue(versioned.hasPrefix("e1:3:dev-abc:"))

        let decrypted = try E2EEService.decryptValue(versioned, key: key)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testParseVersionedV1() {
        let value = "e1:5:device-123:SGVsbG8gV29ybGQ="
        let blob = E2EEService.parseEncryptedValue(value)
        XCTAssertEqual(blob.version, 1)
        XCTAssertEqual(blob.senderKeyVersion, 5)
        XCTAssertEqual(blob.senderDeviceId, "device-123")
        XCTAssertNil(blob.receiverKeyVersion)
        XCTAssertEqual(blob.ciphertext, "SGVsbG8gV29ybGQ=")
    }

    // MARK: - Versioned Wire Format V2 (e2:)

    func testVersionedV2EncryptDecrypt() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = "v2 test"
        let versioned = try E2EEService.encryptVersionedV2(
            plaintext, key: key, keyVersion: 7, senderDeviceId: "dev-xyz", receiverKeyVersion: 2
        )

        XCTAssertTrue(versioned.hasPrefix("e2:7:dev-xyz:2:"))

        let decrypted = try E2EEService.decryptValue(versioned, key: key)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testParseVersionedV2() {
        let value = "e2:7:device-456:3:SGVsbG8gV29ybGQ="
        let blob = E2EEService.parseEncryptedValue(value)
        XCTAssertEqual(blob.version, 2)
        XCTAssertEqual(blob.senderKeyVersion, 7)
        XCTAssertEqual(blob.senderDeviceId, "device-456")
        XCTAssertEqual(blob.receiverKeyVersion, 3)
        XCTAssertEqual(blob.ciphertext, "SGVsbG8gV29ybGQ=")
    }

    // MARK: - Legacy Format

    func testParseLegacyFormat() {
        let value = "SGVsbG8gV29ybGQ="
        let blob = E2EEService.parseEncryptedValue(value)
        XCTAssertNil(blob.version)
        XCTAssertNil(blob.senderKeyVersion)
        XCTAssertNil(blob.senderDeviceId)
        XCTAssertNil(blob.receiverKeyVersion)
        XCTAssertEqual(blob.ciphertext, value)
    }

    func testLegacyEncryptDecryptViaDecryptValue() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = "legacy format"
        let ciphertext = try E2EEService.encrypt(plaintext, key: key)
        // decryptValue should handle raw base64 (legacy format)
        let decrypted = try E2EEService.decryptValue(ciphertext, key: key)
        XCTAssertEqual(decrypted, plaintext)
    }

    // MARK: - Versioned Content Decryption

    func testDecryptContentVersionedHandlesMixedFormats() throws {
        let key = SymmetricKey(size: .bits256)
        let legacyCt = try E2EEService.encrypt("legacy", key: key)
        let v1Ct = try E2EEService.encryptVersioned("v1-msg", key: key, keyVersion: 1, senderDeviceId: "d1")
        let v2Ct = try E2EEService.encryptVersionedV2("v2-msg", key: key, keyVersion: 2, senderDeviceId: "d2", receiverKeyVersion: 1)

        let content = [
            "a": legacyCt,
            "b": v1Ct,
            "c": v2Ct,
        ]
        let decrypted = try E2EEService.decryptContentVersioned(content, key: key)
        XCTAssertEqual(decrypted["a"], "legacy")
        XCTAssertEqual(decrypted["b"], "v1-msg")
        XCTAssertEqual(decrypted["c"], "v2-msg")
    }

    func testDecryptContentVersionedShowsEncryptedOnFailure() throws {
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let ct = try E2EEService.encryptVersioned("secret", key: key1, keyVersion: 1, senderDeviceId: "d1")
        let content = ["field": ct]
        let decrypted = try E2EEService.decryptContentVersioned(content, key: key2)
        XCTAssertEqual(decrypted["field"], "[encrypted]")
    }

    // MARK: - looksLikeCiphertext

    func testLooksLikeCiphertextPositive() {
        // Valid base64, 40+ characters
        let text = String(repeating: "A", count: 50)
        XCTAssertTrue(E2EEService.looksLikeCiphertext(text))
    }

    func testLooksLikeCiphertextTooShort() {
        XCTAssertFalse(E2EEService.looksLikeCiphertext("short"))
    }

    func testLooksLikeCiphertextNonBase64() {
        let text = String(repeating: "!", count: 50)
        XCTAssertFalse(E2EEService.looksLikeCiphertext(text))
    }

    func testLooksLikeCiphertextPlainText() {
        XCTAssertFalse(E2EEService.looksLikeCiphertext("This is just normal text with spaces"))
    }

    // MARK: - Fingerprint

    func testFingerprintFormat() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let pubBase64 = key.publicKey.rawRepresentation.base64EncodedString()
        let fp = E2EEService.fingerprint(of: pubBase64)
        let parts = fp.split(separator: ":")
        XCTAssertEqual(parts.count, 4)
        for part in parts {
            XCTAssertEqual(part.count, 2)
        }
    }

    func testFingerprintInvalidKey() {
        let fp = E2EEService.fingerprint(of: "not-valid-base64!!!")
        XCTAssertEqual(fp, "invalid")
    }

    func testFingerprintDeterministic() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let pubBase64 = key.publicKey.rawRepresentation.base64EncodedString()
        XCTAssertEqual(E2EEService.fingerprint(of: pubBase64), E2EEService.fingerprint(of: pubBase64))
    }
}
