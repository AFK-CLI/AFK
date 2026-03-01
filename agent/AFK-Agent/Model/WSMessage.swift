//
//  WSMessage.swift
//  AFK-Agent
//

import Foundation

struct WSMessage: Sendable {
    let type: String
    let payloadJSON: Data  // Already JSON-encoded payload
    let ts: Int64

    init(type: String, payload: some Encodable & Sendable) throws {
        self.type = type
        self.payloadJSON = try JSONEncoder().encode(payload)
        self.ts = Int64(Date().timeIntervalSince1970 * 1000)
    }

    private init(type: String, rawPayload: Data, ts: Int64) {
        self.type = type
        self.payloadJSON = rawPayload
        self.ts = ts
    }

    /// Encode as `{"type":"...","payload":{...},"ts":123}` with payload as raw JSON
    func encode() throws -> Data {
        var dict: [String: Any] = [
            "type": type,
            "ts": ts
        ]
        dict["payload"] = try JSONSerialization.jsonObject(with: payloadJSON)
        return try JSONSerialization.data(withJSONObject: dict)
    }

    static func decode(from data: Data) throws -> WSMessage {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = dict["type"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        let ts = (dict["ts"] as? NSNumber)?.int64Value ?? 0
        let payloadData: Data
        if let payloadObj = dict["payload"] {
            payloadData = try JSONSerialization.data(withJSONObject: payloadObj)
        } else {
            payloadData = Data("{}".utf8)
        }
        return WSMessage(type: type, rawPayload: payloadData, ts: ts)
    }
}
