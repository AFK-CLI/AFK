import Foundation
import CryptoKit

struct PermissionRequest: Codable, Identifiable, Sendable {
    let sessionId: String
    let toolName: String
    let toolInput: [String: String]
    let toolUseId: String
    let nonce: String
    let expiresAt: Int64
    let deviceId: String
    let challenge: String?

    /// UI-only flag: true when the request was shown after the secure-connection timeout.
    /// Not encoded/decoded from wire — excluded via CodingKeys.
    var isUnverified: Bool

    enum CodingKeys: String, CodingKey {
        case sessionId, toolName, toolInput, toolUseId, nonce, expiresAt, deviceId, challenge
    }

    init(sessionId: String, toolName: String, toolInput: [String: String], toolUseId: String, nonce: String, expiresAt: Int64, deviceId: String, challenge: String? = nil, isUnverified: Bool = false) {
        self.sessionId = sessionId
        self.toolName = toolName
        self.toolInput = toolInput
        self.toolUseId = toolUseId
        self.nonce = nonce
        self.expiresAt = expiresAt
        self.deviceId = deviceId
        self.challenge = challenge
        self.isUnverified = isUnverified
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        toolName = try container.decode(String.self, forKey: .toolName)
        toolInput = try container.decode([String: String].self, forKey: .toolInput)
        toolUseId = try container.decode(String.self, forKey: .toolUseId)
        nonce = try container.decode(String.self, forKey: .nonce)
        expiresAt = try container.decode(Int64.self, forKey: .expiresAt)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        challenge = try container.decodeIfPresent(String.self, forKey: .challenge)
        isUnverified = false
    }

    var id: String { nonce }

    var expiresAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(expiresAt))
    }

    var isExpired: Bool {
        Date() > expiresAtDate
    }

    var timeRemaining: TimeInterval {
        max(0, expiresAtDate.timeIntervalSinceNow)
    }

    /// Preview of what the tool will do (e.g., the bash command)
    var toolInputPreview: String {
        if let command = toolInput["command"] {
            return command
        }
        if let pattern = toolInput["pattern"] {
            return pattern
        }
        if let filePath = toolInput["file_path"] {
            return filePath
        }
        return toolInput.values.first ?? ""
    }
}

struct PermissionResponse: Codable, Sendable {
    let nonce: String
    let action: String       // "allow" or "deny"
    let signature: String
    let deviceId: String     // so backend can route to correct agent
    let fallbackSignature: String?

    /// Create a signed response using HMAC-SHA256.
    /// - signingKey: E2EE-derived key (nil if E2EE not yet ready)
    /// - challengeKey: Tier 2 challenge-derived key (nil if no challenge)
    static func create(
        nonce: String,
        action: String,
        expiresAt: Int64,
        deviceId: String,
        signingKey: SymmetricKey?,
        challenge: String? = nil,
        challengeKey: SymmetricKey? = nil
    ) -> PermissionResponse {
        let signature: String
        if let signingKey {
            signature = sign(nonce: nonce, action: action, expiresAt: expiresAt, key: signingKey)
        } else {
            signature = ""
        }

        let fallbackSignature: String?
        if let challengeKey {
            fallbackSignature = sign(nonce: nonce, action: action, expiresAt: expiresAt, key: challengeKey)
        } else {
            fallbackSignature = nil
        }

        return PermissionResponse(
            nonce: nonce,
            action: action,
            signature: signature,
            deviceId: deviceId,
            fallbackSignature: fallbackSignature
        )
    }

    /// HMAC-SHA256 over "nonce|action|expiresAt"
    private static func sign(nonce: String, action: String, expiresAt: Int64, key: SymmetricKey) -> String {
        let message = "\(nonce)|\(action)|\(expiresAt)"
        let signature = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(signature).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - WWUD (What Would User Do?)

/// Auto-decision event from the WWUD engine, for the transparency feed.
struct WWUDAutoDecision: Codable, Identifiable {
    let deviceId: String?
    let sessionId: String
    let toolName: String
    let toolInputPreview: String
    let action: String
    let confidence: Double
    let patternDescription: String
    let timestamp: Int64
    let decisionId: String

    var id: String { decisionId }

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
}

/// Aggregate stats from the WWUD engine.
struct WWUDStatsPayload: Codable {
    let deviceId: String?
    let totalDecisions: Int
    let autoApproved: Int
    let autoDenied: Int
    let forwarded: Int
    let topPatterns: [WWUDPatternStat]
}

/// A single pattern stat entry.
struct WWUDPatternStat: Codable {
    let pattern: String
    let action: String
    let confidence: Double
    let count: Int
}
