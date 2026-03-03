import Foundation
import OSLog

enum AppConfig {
    private static let apiBaseURLKey = "afk_api_base_url"

    static var isConfigured: Bool {
        if BuildEnvironment.userDefaults.string(forKey: apiBaseURLKey) != nil { return true }
        return !apiBaseURL.isEmpty
    }

    static var apiBaseURL: String {
        if let stored = BuildEnvironment.userDefaults.string(forKey: apiBaseURLKey) {
            return stored
        }
        #if DEBUG
        return "https://afk-dev.ahmetbirinci.dev"
        #else
        return "https://afk.ahmetbirinci.dev"
        #endif
    }

    static var wsBaseURL: String {
        apiBaseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
    }

    static func configure(apiURL: String) {
        guard isAllowedURL(apiURL) else {
            #if DEBUG
            AppLogger.app.warning("Rejected URL: \(apiURL, privacy: .public) — HTTPS required (HTTP allowed only for localhost)")
            #endif
            return
        }
        BuildEnvironment.userDefaults.set(apiURL, forKey: apiBaseURLKey)
    }

    /// Validates that a URL uses HTTPS, or HTTP only for localhost/127.0.0.1 (development).
    static func isAllowedURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return false
        }
        if scheme == "https" { return true }
        if scheme == "http" && (host == "localhost" || host == "127.0.0.1") { return true }
        return false
    }

    static func reset() {
        BuildEnvironment.userDefaults.removeObject(forKey: apiBaseURLKey)
    }

    /// Shared JSON decoder that handles Go's RFC3339 dates (with fractional seconds).
    static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let withoutFractional = ISO8601DateFormatter()
        withoutFractional.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = withFractional.date(from: string) { return date }
            if let date = withoutFractional.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(string)")
        }
        return decoder
    }
}
