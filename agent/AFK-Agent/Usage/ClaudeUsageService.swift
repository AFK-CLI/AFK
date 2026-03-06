//
//  ClaudeUsageService.swift
//  AFK-Agent
//

import Foundation
import OSLog

actor ClaudeUsageService {
    private let keychainService = "Claude Code-credentials"

    /// Fetch current Claude usage from the Anthropic API.
    /// Returns nil if no credentials are found or the token is expired.
    func fetchUsage() async -> ClaudeUsage? {
        guard let credentials = readKeychainCredentials() else {
            AppLogger.usage.debug("No Claude Code credentials found in keychain")
            return nil
        }

        guard credentials.expiresAt > Date().timeIntervalSince1970 else {
            AppLogger.usage.warning("Claude Code token expired")
            return nil
        }

        do {
            return try await callUsageAPI(
                accessToken: credentials.accessToken,
                subscriptionType: credentials.subscriptionType
            )
        } catch {
            AppLogger.usage.error("Usage API call failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Keychain

    private struct KeychainCredentials {
        let accessToken: String
        let subscriptionType: String
        let expiresAt: Double
    }

    private func readKeychainCredentials() -> KeychainCredentials? {
        let username = NSUserName()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", keychainService,
            "-a", username,
            "-w"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            AppLogger.usage.error("Failed to run security command: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return nil }

        // Parse the JSON credential blob
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              let expiresAt = oauth["expiresAt"] as? Double else {
            AppLogger.usage.warning("Failed to parse Claude Code credentials JSON")
            return nil
        }

        let subscriptionType = oauth["subscriptionType"] as? String ?? "unknown"

        return KeychainCredentials(
            accessToken: accessToken,
            subscriptionType: subscriptionType,
            expiresAt: expiresAt
        )
    }

    // MARK: - API

    private struct UsageAPIResponse: Decodable {
        let five_hour: UsageBucket?
        let seven_day: UsageBucket?
        let seven_day_opus: UsageBucket?
        let seven_day_sonnet: UsageBucket?
    }

    private struct UsageBucket: Decodable {
        let utilization: Double?
        let resets_at: String?
    }

    private func callUsageAPI(accessToken: String, subscriptionType: String) async throws -> ClaudeUsage {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.5", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "Usage API returned status \(statusCode)"
            ])
        }

        let apiResponse = try JSONDecoder().decode(UsageAPIResponse.self, from: data)
        let iso = ISO8601DateFormatter()
        let now = Date()

        return ClaudeUsage(
            sessionPercentage: apiResponse.five_hour?.utilization ?? 0,
            sessionResetTime: apiResponse.five_hour?.resets_at.flatMap { iso.date(from: $0) } ?? now,
            weeklyPercentage: apiResponse.seven_day?.utilization ?? 0,
            weeklyResetTime: apiResponse.seven_day?.resets_at.flatMap { iso.date(from: $0) } ?? now,
            opusWeeklyPercentage: apiResponse.seven_day_opus?.utilization ?? 0,
            sonnetWeeklyPercentage: apiResponse.seven_day_sonnet?.utilization ?? 0,
            sonnetWeeklyResetTime: apiResponse.seven_day_sonnet?.resets_at.flatMap { iso.date(from: $0) },
            subscriptionType: subscriptionType,
            lastUpdated: now
        )
    }
}
