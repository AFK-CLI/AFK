//
//  ClaudeUsage.swift
//  AFK
//

import Foundation

struct ClaudeUsage: Codable, Sendable {
    let deviceId: String
    let sessionPercentage: Double
    let sessionResetTime: Date
    let weeklyPercentage: Double
    let weeklyResetTime: Date
    let opusWeeklyPercentage: Double
    let sonnetWeeklyPercentage: Double
    let sonnetWeeklyResetTime: Date?
    let subscriptionType: String
    let lastUpdated: Date
    let deviceName: String?

    enum StatusLevel {
        case good, warning, critical
    }

    var sessionStatusLevel: StatusLevel {
        Self.statusLevel(for: sessionPercentage)
    }

    var weeklyStatusLevel: StatusLevel {
        Self.statusLevel(for: weeklyPercentage)
    }

    static func statusLevel(for percentage: Double) -> StatusLevel {
        if percentage >= 80 { return .critical }
        if percentage >= 50 { return .warning }
        return .good
    }

    func formattedResetTime(_ date: Date) -> String {
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return "now" }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
