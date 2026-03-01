import Foundation
import SwiftData

@Model
final class CachedEvent {
    @Attribute(.unique) var id: String
    var sessionId: String
    var deviceId: String?
    var eventType: String
    var timestamp: String
    var payloadJSON: Data?
    var contentJSON: Data?
    var seq: Int?
    var cachedAt: Date

    init(from event: SessionEvent) {
        self.id = event.id
        self.sessionId = event.sessionId
        self.deviceId = event.deviceId
        self.eventType = event.eventType
        self.timestamp = event.timestamp
        self.payloadJSON = Self.encode(event.payload)
        self.contentJSON = Self.encode(event.content)
        self.seq = event.seq
        self.cachedAt = Date()
    }

    func toSessionEvent() -> SessionEvent {
        SessionEvent(
            id: id,
            sessionId: sessionId,
            deviceId: deviceId,
            eventType: eventType,
            timestamp: timestamp,
            payload: Self.decode(payloadJSON),
            content: Self.decode(contentJSON),
            seq: seq
        )
    }

    private static func encode(_ dict: [String: String]?) -> Data? {
        guard let dict else { return nil }
        return try? JSONEncoder().encode(dict)
    }

    private static func decode(_ data: Data?) -> [String: String]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }
}
