import Foundation

struct User: Codable, Identifiable, Sendable {
    let id: String
    let appleUserId: String
    let email: String
    let displayName: String
    let createdAt: String?
    let updatedAt: String?
    let subscriptionTier: String?
    let subscriptionExpiresAt: String?

    var isPro: Bool { subscriptionTier == "pro" || subscriptionTier == "contributor" }
}
