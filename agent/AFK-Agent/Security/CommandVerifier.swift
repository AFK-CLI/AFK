//
//  CommandVerifier.swift
//  AFK-Agent
//

import Foundation
import CryptoKit

struct CommandVerifier: Sendable {
    let serverPublicKey: Curve25519.Signing.PublicKey

    struct SignedCommand: Codable, Sendable {
        let commandId: String
        let sessionId: String
        let promptHash: String
        let nonce: String
        let expiresAt: Int64
        let signature: String  // hex-encoded Ed25519 signature
    }

    enum VerificationError: Error {
        case missingSignature
        case invalidSignatureEncoding
        case invalidSignature
        case commandExpired
        case nonceReplayed
    }

    /// Verify the server's Ed25519 signature on a command
    func verify(_ command: SignedCommand, nonceStore: NonceStore) async throws {
        guard !command.signature.isEmpty else {
            throw VerificationError.missingSignature
        }

        guard let signatureData = Data(hexString: command.signature) else {
            throw VerificationError.invalidSignatureEncoding
        }

        // Check expiry
        let now = Int64(Date().timeIntervalSince1970)
        guard now <= command.expiresAt else {
            throw VerificationError.commandExpired
        }

        // Check nonce replay
        guard await nonceStore.check(command.nonce) else {
            throw VerificationError.nonceReplayed
        }

        // Build canonical string: "commandId|sessionId|promptHash|nonce|expiresAt"
        let canonical = [
            command.commandId,
            command.sessionId,
            command.promptHash,
            command.nonce,
            String(command.expiresAt)
        ].joined(separator: "|")

        guard let canonicalData = canonical.data(using: .utf8) else {
            throw VerificationError.invalidSignature
        }

        // Verify Ed25519 signature
        guard serverPublicKey.isValidSignature(signatureData, for: canonicalData) else {
            throw VerificationError.invalidSignature
        }
    }
}

// Simple nonce store (actor for thread safety)
actor NonceStore {
    private var seen: Set<String> = []

    /// Returns true if nonce is new, false if replayed
    func check(_ nonce: String) -> Bool {
        if seen.contains(nonce) {
            return false
        }
        seen.insert(nonce)
        return true
    }

    /// Remove old nonces (call periodically)
    func cleanup(olderThan: TimeInterval = 300) {
        // For simplicity, clear all. In production could track timestamps.
        // This is acceptable since commands have short TTL.
        seen.removeAll()
    }
}

// Hex string extension
extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex
        for _ in 0..<len {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
