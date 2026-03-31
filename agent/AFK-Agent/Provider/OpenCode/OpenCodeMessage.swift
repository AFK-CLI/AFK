//
//  OpenCodeMessage.swift
//  AFK-Agent
//

import Foundation

/// A part row from OpenCode's `part` table, enriched with message-level metadata.
/// OpenCode stores parts separately from messages: each part has its own row with a JSON `data` column.
struct OpenCodePart: Sendable {
    let rowId: Int64
    let partId: String
    let messageId: String
    let sessionId: String
    let role: String            // from joined message.data.role
    let projectPath: String     // from joined session.directory
    let model: String?          // from joined message.data.modelID
    let content: OpenCodePartContent
    let createdAt: Date
}

/// Parsed content from a part's `data` JSON column.
/// OpenCode uses a single "tool" type with state tracking, not separate call/result parts.
enum OpenCodePartContent: Sendable {
    case text(String)
    case reasoning(String)
    case stepStart
    case stepFinish(reason: String, cost: Double, tokensIn: Int64, tokensOut: Int64)
    /// A tool invocation with its full state. status is "completed" or "error".
    case tool(callId: String, name: String, status: String,
              input: [String: String], output: String, title: String)
    case unknown(String)
}

/// Parses a single part's `data` JSON column into typed content.
struct OpenCodePartParser {
    static func parse(_ json: String) -> OpenCodePartContent {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = dict["type"] as? String else {
            return .unknown(json)
        }

        switch type {
        case "text":
            let text = dict["text"] as? String ?? ""
            return .text(text)

        case "reasoning":
            let text = dict["text"] as? String ?? ""
            return .reasoning(text)

        case "step-start":
            return .stepStart

        case "step-finish":
            let reason = dict["reason"] as? String ?? "stop"
            let cost = dict["cost"] as? Double ?? 0
            var tokensIn: Int64 = 0
            var tokensOut: Int64 = 0
            if let tokens = dict["tokens"] as? [String: Any] {
                tokensIn = (tokens["input"] as? Int64) ?? Int64(tokens["input"] as? Int ?? 0)
                tokensOut = (tokens["output"] as? Int64) ?? Int64(tokens["output"] as? Int ?? 0)
            }
            return .stepFinish(reason: reason, cost: cost, tokensIn: tokensIn, tokensOut: tokensOut)

        case "tool":
            let callId = dict["callID"] as? String ?? ""
            let name = dict["tool"] as? String ?? ""
            let state = dict["state"] as? [String: Any] ?? [:]
            let status = state["status"] as? String ?? "pending"
            let title = state["title"] as? String ?? ""

            // Parse input: flatten string values, serialize nested as JSON
            let input: [String: String]
            if let inputDict = state["input"] as? [String: Any] {
                input = inputDict.reduce(into: [:]) { result, pair in
                    if let str = pair.value as? String {
                        result[pair.key] = str
                    } else if pair.value is [Any] || pair.value is [String: Any],
                              let data = try? JSONSerialization.data(withJSONObject: pair.value),
                              let str = String(data: data, encoding: .utf8) {
                        result[pair.key] = str
                    } else {
                        result[pair.key] = "\(pair.value)"
                    }
                }
            } else {
                input = [:]
            }

            // Extract output text
            let output: String
            if let o = state["output"] as? String {
                output = o
            } else {
                output = ""
            }

            return .tool(callId: callId, name: name, status: status,
                        input: input, output: output, title: title)

        default:
            return .unknown(type)
        }
    }
}
