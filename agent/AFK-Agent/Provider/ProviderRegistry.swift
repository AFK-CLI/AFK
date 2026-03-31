//
//  ProviderRegistry.swift
//  AFK-Agent
//

import Foundation
import OSLog

/// Manages enabled coding tool providers based on configuration.
actor ProviderRegistry {
    private var providers: [String: any CodingToolProvider] = [:]

    init(config: AgentConfig) {
        for id in config.enabledProviders {
            switch id {
            case "claude_code":
                providers[id] = ClaudeCodeProvider(config: config)
            case "opencode":
                providers[id] = OpenCodeProvider(config: config)
            default:
                AppLogger.agent.warning("Unknown provider: \(id, privacy: .public)")
            }
        }
        AppLogger.agent.info("Enabled providers: \(config.enabledProviders.joined(separator: ", "), privacy: .public)")
    }

    var enabledProviders: [any CodingToolProvider] {
        Array(providers.values)
    }

    func provider(for identifier: String) -> (any CodingToolProvider)? {
        providers[identifier]
    }

    /// Find which provider owns a given session by checking each provider's data files.
    func providerForSession(sessionId: String) async -> (any CodingToolProvider)? {
        for (_, provider) in providers {
            if await provider.findSessionFile(sessionId: sessionId) != nil {
                return provider
            }
        }
        return nil
    }
}
