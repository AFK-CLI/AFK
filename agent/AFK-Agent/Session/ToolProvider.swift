//
//  ToolProvider.swift
//  AFK-Agent
//

import Foundation

protocol ToolProvider: Sendable {
    var providerName: String { get }
    func displayHints(toolName: String, input: [String: String]) -> ToolDisplayHints
    func structuredFields(toolName: String, input: [String: String]) -> [ToolInputField]
}

struct ToolDisplayHints: Sendable {
    let iconName: String      // SF Symbol name
    let iconColor: String     // Hex color string, e.g. "#30D158"
    let category: String      // Grouping slug
    let description: String   // Human-readable one-liner, e.g. "Reading EventNormalizer.swift"
}

struct ToolInputField: Codable, Sendable {
    let label: String   // "File", "Command", "Pattern"
    let value: String   // The actual value
    let style: String   // "path" | "code" | "text" | "badge"
}
