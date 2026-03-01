import Foundation

struct WSMessage: Sendable {
    let type: String
    let payload: Data
    let ts: Int64

    nonisolated init(type: String, payload: any Encodable & Sendable) throws {
        self.type = type
        self.payload = try JSONEncoder().encode(payload)
        self.ts = Int64(Date().timeIntervalSince1970 * 1000)
    }

    nonisolated func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }

    nonisolated func toJSONData() throws -> Data {
        var dict: [String: Any] = [
            "type": type,
            "ts": ts
        ]
        let payloadObj = try JSONSerialization.jsonObject(with: payload)
        dict["payload"] = payloadObj
        return try JSONSerialization.data(withJSONObject: dict)
    }
}
