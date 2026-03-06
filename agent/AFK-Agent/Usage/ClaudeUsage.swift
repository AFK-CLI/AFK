//
//  ClaudeUsage.swift
//  AFK-Agent
//

import Foundation

struct ClaudeUsage: Codable, Sendable {
    let sessionPercentage: Double
    let sessionResetTime: Date
    let weeklyPercentage: Double
    let weeklyResetTime: Date
    let opusWeeklyPercentage: Double
    let sonnetWeeklyPercentage: Double
    let sonnetWeeklyResetTime: Date?
    let subscriptionType: String
    let lastUpdated: Date
}
