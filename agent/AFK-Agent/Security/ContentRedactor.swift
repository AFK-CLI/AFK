//
//  ContentRedactor.swift
//  AFK-Agent
//

import Foundation
import CryptoKit

struct ContentRedactor: Sendable {

    struct Config: Sendable {
        let maxSnippetLength: Int
        let maxToolInputLength: Int
        let maxToolResultLength: Int
        let hashFilePaths: Bool

        static let `default` = Config(
            maxSnippetLength: 8000,
            maxToolInputLength: 2000,
            maxToolResultLength: 4000,
            hashFilePaths: true
        )
    }

    let config: Config

    init(config: Config = .default) {
        self.config = config
    }

    // Secret patterns with labels for redaction replacement
    private static let secretPatterns: [(label: String, pattern: String)] = [
        // AWS access keys
        ("AWS_ACCESS_KEY", #"AKIA[0-9A-Z]{16}"#),
        // AWS secret keys
        ("AWS_SECRET_KEY", #"(?i)aws[_\-]?secret[_\-]?access[_\-]?key\s*[:=]\s*[A-Za-z0-9/+=]{40}"#),
        // Generic high-entropy secrets (api_key, secret_key, private_key, access_token, auth_token)
        ("SECRET", #"(?i)(api[_\-]?key|secret[_\-]?key|private[_\-]?key|access[_\-]?token|auth[_\-]?token)\s*[:=]\s*['"]?[A-Za-z0-9+/=_\-]{20,}['"]?"#),
        // JWTs
        ("JWT", #"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#),
        // Private key blocks
        ("PRIVATE_KEY", #"-----BEGIN[A-Z ]+PRIVATE KEY-----[\s\S]*?-----END[A-Z ]+PRIVATE KEY-----"#),
        // Connection strings
        ("CONNECTION_STRING", #"(?i)(postgres|mysql|mongodb|redis|amqp)://[^\s'"]+"#),
        // GitHub/GitLab tokens
        ("GIT_TOKEN", #"(?i)(ghp_|gho_|ghu_|ghs_|ghr_|glpat-)[A-Za-z0-9_]{16,}"#),
        // Slack tokens
        ("SLACK_TOKEN", #"xox[bprs]-[A-Za-z0-9-]+"#),
        // Generic password assignments
        ("PASSWORD", #"(?i)password\s*[:=]\s*['\"][^'\"]{8,}['\"]"#),
    ]

    // Compiled regex cache (static, compiled once)
    private static let compiledPatterns: [(label: String, regex: NSRegularExpression)] = {
        secretPatterns.compactMap { item in
            guard let regex = try? NSRegularExpression(pattern: item.pattern, options: [.dotMatchesLineSeparators]) else {
                return nil
            }
            return (label: item.label, regex: regex)
        }
    }()

    /// Redact secrets from text, replacing matches with [REDACTED:<label>]
    func redact(_ text: String) -> String {
        var result = text
        for (label, regex) in Self.compiledPatterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: "[REDACTED:\(label)]"
            )
        }
        return result
    }

    /// Truncate text to maxLength, appending "... [truncated]" if needed
    func truncate(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let truncated = String(text.prefix(maxLength))
        return truncated + "… [truncated]"
    }

    /// Redact a file path: SHA-256 hash all path components except the filename
    func redactFilePath(_ path: String) -> String {
        guard config.hashFilePaths else { return path }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count > 1 else { return path }

        let filename = String(components.last!)
        let dirComponents = components.dropLast()

        let hashedDir = dirComponents.map { component -> String in
            guard !component.isEmpty else { return "" }
            let hash = SHA256.hash(data: Data(component.utf8))
            return String(hash.map { String(format: "%02x", $0) }.joined().prefix(8))
        }.joined(separator: "/")

        return hashedDir + "/" + filename
    }

    /// Redact and truncate a user or assistant snippet
    func redactSnippet(_ text: String) -> String {
        return truncate(redact(text), maxLength: config.maxSnippetLength)
    }

    /// Redact tool input, returning a summary dictionary
    func redactToolInput(_ input: [String: String], toolName: String) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in input {
            let redacted = redact(value)
            let truncated = truncate(redacted, maxLength: config.maxToolInputLength)
            result[key] = truncated
        }
        return result
    }

    /// Redact and truncate tool result text
    func redactToolResult(_ text: String) -> String {
        return truncate(redact(text), maxLength: config.maxToolResultLength)
    }
}
