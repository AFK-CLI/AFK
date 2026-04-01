//
//  AgentConfig.swift
//  AFK-Agent
//

import Foundation

struct AgentConfig: Sendable {
    let serverURL: String
    let deviceID: String?
    let authToken: String?
    let claudeProjectsPath: String
    let heartbeatInterval: TimeInterval
    let idleTimeout: TimeInterval       // 120s -> session_idle
    let completedTimeout: TimeInterval   // 300s -> session_completed
    let permissionStallTimeout: TimeInterval  // 10s -> permission_needed
    let remoteApprovalEnabled: Bool      // false by default
    let remoteApprovalTimeout: TimeInterval  // 120s default
    let hookInstallPath: String          // ~/.claude/hooks
    var defaultPrivacyMode: String       // "telemetry_only", "relay_only", "encrypted"
    let projectPrivacyOverrides: [String: String]  // projectPath -> privacyMode override
    let acceptLegacyPermissionFallback: Bool  // true by default — set false to disable legacy HMAC tier
    let deviceName: String
    let logLevel: String
    let hooksEnabled: Bool
    let planAutoExit: Bool
    let obeySettingsRules: Bool          // false by default — check settings.json allow/deny lists
    let preventSleep: Bool               // false by default — IOKit sleep prevention
    let ctrlClickTogglesRemoteAndSleep: Bool  // false by default — ctrl+click combo toggle
    let notifyOnIdle: Bool               // true by default — show macOS notification when Claude is idle
    let usagePollingEnabled: Bool        // true by default — poll Claude API usage
    let updateCheckInterval: TimeInterval // 3600 (1 hour) default — Sparkle check interval
    let enabledProviders: [String]       // ["claude_code"] by default
    let openCodePollInterval: TimeInterval // 2s default — SQLite polling interval
    let openCodeServerPort: Int          // 0 = auto-detect (tries 4096), >0 = explicit
    let hookServerPort: Int              // 19280 default — HTTP hook server port
    let hookServerEnabled: Bool          // true by default — enable HTTP hook server

    var isConfigured: Bool {
        !serverURL.isEmpty
    }

    var httpBaseURL: String {
        serverURL
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")
    }

    static func load() -> AgentConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configPath = BuildEnvironment.configDirectoryPath + "/config.json"

        // Default from xcconfig (generated at build time)
        let defaultServerURL = GeneratedConfig.serverURL

        // Try to load from config file
        if let data = FileManager.default.contents(atPath: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return AgentConfig(
                serverURL: json["serverURL"] as? String ?? defaultServerURL,
                deviceID: json["deviceId"] as? String,
                authToken: json["authToken"] as? String,
                claudeProjectsPath: json["claudeProjectsPath"] as? String ?? "\(home)/.claude/projects",
                heartbeatInterval: json["heartbeatInterval"] as? TimeInterval ?? 30,
                idleTimeout: json["idleTimeout"] as? TimeInterval ?? 120,
                completedTimeout: json["completedTimeout"] as? TimeInterval ?? 300,
                permissionStallTimeout: json["permissionStallTimeout"] as? TimeInterval ?? 10,
                remoteApprovalEnabled: json["remoteApprovalEnabled"] as? Bool ?? true,
                remoteApprovalTimeout: json["remoteApprovalTimeout"] as? TimeInterval ?? 120,
                hookInstallPath: json["hookInstallPath"] as? String ?? "\(home)/.claude/hooks",
                defaultPrivacyMode: json["defaultPrivacyMode"] as? String ?? "encrypted",
                projectPrivacyOverrides: json["projectPrivacyOverrides"] as? [String: String] ?? [:],
                acceptLegacyPermissionFallback: json["acceptLegacyPermissionFallback"] as? Bool ?? true,
                deviceName: json["deviceName"] as? String ?? Host.current().localizedName ?? "Mac",
                logLevel: json["logLevel"] as? String ?? "info",
                hooksEnabled: json["hooksEnabled"] as? Bool ?? true,
                planAutoExit: json["planAutoExit"] as? Bool ?? false,
                obeySettingsRules: json["obeySettingsRules"] as? Bool ?? false,
                preventSleep: json["preventSleep"] as? Bool ?? false,
                ctrlClickTogglesRemoteAndSleep: json["ctrlClickTogglesRemoteAndSleep"] as? Bool ?? false,
                notifyOnIdle: json["notifyOnIdle"] as? Bool ?? true,
                usagePollingEnabled: json["usagePollingEnabled"] as? Bool ?? true,
                updateCheckInterval: json["updateCheckInterval"] as? TimeInterval ?? 3600,
                enabledProviders: json["enabledProviders"] as? [String] ?? ["claude_code"],
                openCodePollInterval: json["openCodePollInterval"] as? TimeInterval ?? 2,
                openCodeServerPort: json["openCodeServerPort"] as? Int ?? 0,
                hookServerPort: json["hookServerPort"] as? Int ?? 19280,
                hookServerEnabled: json["hookServerEnabled"] as? Bool ?? true
            )
        }

        // Defaults from environment → xcconfig → hardcoded
        let env = ProcessInfo.processInfo.environment
        return AgentConfig(
            serverURL: env["AFK_SERVER_URL"] ?? defaultServerURL,
            deviceID: env["AFK_DEVICE_ID"],
            authToken: env["AFK_AUTH_TOKEN"],
            claudeProjectsPath: "\(home)/.claude/projects",
            heartbeatInterval: 30,
            idleTimeout: 120,
            completedTimeout: 300,
            permissionStallTimeout: 10,
            remoteApprovalEnabled: env["AFK_REMOTE_APPROVAL"] != "0",
            remoteApprovalTimeout: 120,
            hookInstallPath: "\(home)/.claude/hooks",
            defaultPrivacyMode: env["AFK_PRIVACY_MODE"] ?? "encrypted",
            projectPrivacyOverrides: [:],
            acceptLegacyPermissionFallback: {
                if let val = env["AFK_ACCEPT_LEGACY_PERMISSION_FALLBACK"] {
                    return val != "false" && val != "0"
                }
                return true
            }(),
            deviceName: Host.current().localizedName ?? "Mac",
            logLevel: env["AFK_LOG_LEVEL"] ?? "info",
            hooksEnabled: env["AFK_HOOKS_ENABLED"] != "0",
            planAutoExit: env["AFK_PLAN_AUTO_EXIT"] == "1",
            obeySettingsRules: false,
            preventSleep: false,
            ctrlClickTogglesRemoteAndSleep: false,
            notifyOnIdle: true,
            usagePollingEnabled: true,
            updateCheckInterval: 3600,
            enabledProviders: ["claude_code"],
            openCodePollInterval: 2,
            openCodeServerPort: 0,
            hookServerPort: {
                if let val = env["AFK_HOOK_SERVER_PORT"], let port = Int(val) {
                    return port
                }
                return 19280
            }(),
            hookServerEnabled: {
                if let val = env["AFK_HOOK_SERVER_ENABLED"] {
                    return val != "false" && val != "0"
                }
                return true
            }()
        )
    }

    /// Resolve the effective privacy mode for a given project path.
    /// Project-level overrides take precedence over the default.
    func privacyMode(for projectPath: String) -> String {
        return projectPrivacyOverrides[projectPath] ?? defaultPrivacyMode
    }

    func save() {
        let fm = FileManager.default
        let configDir = BuildEnvironment.configDirectoryPath
        let configPath = "\(configDir)/config.json"

        try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        // Restrict config directory to owner only (0700)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configDir)

        var dict: [String: Any] = [
            "serverURL": serverURL,
            "deviceName": deviceName,
            "logLevel": logLevel,
            "hooksEnabled": hooksEnabled,
            "planAutoExit": planAutoExit,
            "remoteApprovalEnabled": remoteApprovalEnabled,
            "defaultPrivacyMode": defaultPrivacyMode,
            "obeySettingsRules": obeySettingsRules,
            "preventSleep": preventSleep,
            "ctrlClickTogglesRemoteAndSleep": ctrlClickTogglesRemoteAndSleep,
            "notifyOnIdle": notifyOnIdle,
            "usagePollingEnabled": usagePollingEnabled,
            "updateCheckInterval": updateCheckInterval,
            "hookServerPort": hookServerPort,
            "hookServerEnabled": hookServerEnabled,
        ]
        if let deviceID { dict["deviceId"] = deviceID }
        if let authToken { dict["authToken"] = authToken }

        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: configPath))
            // Restrict config file to owner read/write only (0600) since it may contain authToken
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath)
        }
    }
}
