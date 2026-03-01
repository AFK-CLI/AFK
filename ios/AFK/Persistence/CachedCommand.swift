import Foundation
import SwiftData

@Model
final class CachedCommand {
    @Attribute(.unique) var id: String
    var sessionId: String
    var prompt: String
    var statusRaw: String
    var output: String?
    var error: String?
    var createdAt: Date
    var completedAt: Date?

    init(id: String, sessionId: String, prompt: String, status: String = "pending") {
        self.id = id
        self.sessionId = sessionId
        self.prompt = prompt
        self.statusRaw = status
        self.createdAt = Date()
    }
}
