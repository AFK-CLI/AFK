import Foundation

struct Device: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let userId: String
    let name: String
    let publicKey: String
    let systemInfo: String?
    let enrolledAt: String?
    let lastSeenAt: String?
    var isOnline: Bool
    let isRevoked: Bool
    let privacyMode: String?
    let keyAgreementPublicKey: String?
    let keyVersion: Int?
    let capabilities: [String]?

    static func == (lhs: Device, rhs: Device) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
