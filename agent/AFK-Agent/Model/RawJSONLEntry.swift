//
//  RawJSONLEntry.swift
//  AFK-Agent
//

import Foundation

struct RawJSONLEntry: Codable, Sendable {
    let type: String              // "user", "assistant", "system", "progress", etc.
    let uuid: String?
    let parentUuid: String?
    let sessionId: String?
    let timestamp: String?        // ISO8601
    let cwd: String?
    let gitBranch: String?
    let version: String?
    let message: RawMessage?
    let isSidechain: Bool?
    let agentId: String?
    // system subtypes
    let subtype: String?          // e.g. "turn_duration"
    let durationMs: Double?
    let userType: String?         // "external", "internal"
}

struct RawMessage: Codable, Sendable {
    let role: String?
    let content: AnyCodableContent?
    let usage: RawUsage?
}

enum AnyCodableContent: Codable, Sendable {
    case text(String)
    case blocks([ContentBlock])
    case dictionary([String: AnyCodableValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .text(str)
        } else if let blocks = try? container.decode([ContentBlock].self) {
            self = .blocks(blocks)
        } else if let dict = try? container.decode([String: AnyCodableValue].self) {
            self = .dictionary(dict)
        } else {
            self = .text("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s): try container.encode(s)
        case .blocks(let b): try container.encode(b)
        case .dictionary(let d): try container.encode(d)
        }
    }

    /// Extract a flat [String: String] representation (useful for tool input redaction)
    var asStringDictionary: [String: String] {
        switch self {
        case .dictionary(let dict):
            var result: [String: String] = [:]
            for (key, value) in dict {
                result[key] = value.stringValue
            }
            return result
        case .text(let s):
            return ["_text": s]
        case .blocks:
            return [:]
        }
    }

    /// Extract full text representation
    var textContent: String {
        switch self {
        case .text(let s):
            return s
        case .blocks(let blocks):
            return blocks.compactMap(\.text).joined(separator: "\n")
        case .dictionary(let dict):
            return dict.map { "\($0.key): \($0.value.stringValue)" }.joined(separator: "\n")
        }
    }
}

/// A loosely-typed JSON value for tool input dictionaries
enum AnyCodableValue: Codable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case dictionary([String: AnyCodableValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let arr = try? container.decode([AnyCodableValue].self) {
            self = .array(arr)
        } else if let dict = try? container.decode([String: AnyCodableValue].self) {
            self = .dictionary(dict)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .array(let arr): try container.encode(arr)
        case .dictionary(let dict): try container.encode(dict)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return "\(i)"
        case .double(let d): return "\(d)"
        case .bool(let b): return "\(b)"
        case .array, .dictionary:
            // Serialize complex values to compact JSON
            if let data = try? JSONEncoder().encode(self),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "null"
        case .null: return "null"
        }
    }
}

struct ContentBlock: Codable, Sendable {
    let type: String              // "text", "tool_use", "tool_result", "thinking"
    let text: String?
    let id: String?               // tool_use ID
    let name: String?             // tool name
    let input: AnyCodableContent? // tool_use input (JSON object or string)
    let toolUseId: String?        // for tool_result, references tool_use id
    let isError: Bool?
    let content: AnyCodableContent?  // tool_result can have nested content

    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input
        case toolUseId = "tool_use_id"
        case isError = "is_error"
        case content
    }
}

struct RawUsage: Codable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}
