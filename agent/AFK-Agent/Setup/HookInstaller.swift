//
//  HookInstaller.swift
//  AFK-Agent
//
//  Installs/uninstalls the afk-permission-hook.sh into Claude Code's
//  hook system at ~/.claude/settings.json.
//

import Foundation
import OSLog

struct HookInstaller {
    private let hookInstallDir: String   // e.g. ~/.claude/hooks
    private let settingsPath: String     // ~/.claude/settings.json
    private let hookScriptName = "afk-permission-hook.sh"

    private let notificationHookScriptName = "afk-notification-hook.sh"
    private let stopHookScriptName = "afk-stop-hook.sh"
    private let sessionStartHookScriptName = "afk-session-start-hook.sh"
    private let promptSubmitHookScriptName = "afk-prompt-submit-hook.sh"
    private let toolUsedHookScriptName = "afk-tool-used-hook.sh"
    private let hookTimeout: Int         // ms

    /// All AFK hook script names for install/uninstall management.
    private var allScriptNames: [String] {
        [hookScriptName, notificationHookScriptName,
         stopHookScriptName, sessionStartHookScriptName, promptSubmitHookScriptName,
         toolUsedHookScriptName]
    }

    /// Legacy script names to clean up from older installs.
    private let legacyScriptNames = ["afk-plan-exit-hook.sh"]

    /// OTLP telemetry environment variables to inject into Claude Code settings.
    private static let otlpEnvValues: [String: String] = [
        "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
        "OTEL_LOGS_EXPORTER": "otlp",
        "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL": "http/json",
        "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": "http://localhost:4318/v1/logs",
        "OTEL_LOGS_EXPORT_INTERVAL": "5000"
    ]

    /// OTLP env key names for cleanup on uninstall.
    private static let otlpEnvKeys: Set<String> = Set(otlpEnvValues.keys)

    /// All settings.json hook keys that AFK may register under.
    private static let allHookKeys = [
        "PreToolUse", "PostToolUse", "Notification", "Stop",
        "SessionStart", "UserPromptSubmit", "PermissionRequest"
    ]

    init(hookInstallDir: String, timeoutSeconds: TimeInterval) {
        self.hookInstallDir = hookInstallDir
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.settingsPath = "\(home)/.claude/settings.json"
        self.hookTimeout = Int(timeoutSeconds * 1000)
    }

    var installedHookPath: String {
        "\(hookInstallDir)/\(hookScriptName)"
    }

    private func scriptPath(_ name: String) -> String {
        "\(hookInstallDir)/\(name)"
    }

    /// Install the hook script and register it in Claude Code settings.
    func install() throws {
        let fm = FileManager.default

        // 1. Ensure hooks directory exists
        try fm.createDirectory(atPath: hookInstallDir, withIntermediateDirectories: true)

        // 2. Copy the bundled hook script to the install location
        let bundledScript = bundledHookScriptContents()
        try bundledScript.write(toFile: installedHookPath, atomically: true, encoding: .utf8)

        // Make executable
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedHookPath)

        // 3. Register in settings.json
        var settings = loadSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let hookEntry: [String: Any] = [
            "type": "command",
            "command": installedHookPath,
            "timeout": hookTimeout
        ]
        let matcherEntry: [String: Any] = [
            "matcher": "",
            "hooks": [hookEntry]
        ]

        // Remove from old PermissionRequest key if present (migrating to PreToolUse).
        if var oldHooks = hooks["PermissionRequest"] as? [[String: Any]] {
            oldHooks.removeAll { entry in
                if let entryHooks = entry["hooks"] as? [[String: Any]] {
                    return entryHooks.contains { ($0["command"] as? String)?.contains(hookScriptName) == true }
                }
                return false
            }
            if oldHooks.isEmpty {
                hooks.removeValue(forKey: "PermissionRequest")
            } else {
                hooks["PermissionRequest"] = oldHooks
            }
        }

        // Delete legacy PostToolUse script file
        for name in legacyScriptNames {
            let path = scriptPath(name)
            if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: path)
            }
        }

        // Register under PreToolUse — this fires before the permission check
        // and can auto-approve/deny tool calls.
        var preToolHooks = hooks["PreToolUse"] as? [[String: Any]] ?? []
        let alreadyInstalled = preToolHooks.contains { entry in
            if let entryHooks = entry["hooks"] as? [[String: Any]] {
                return entryHooks.contains { ($0["command"] as? String)?.contains(hookScriptName) == true }
            }
            return false
        }

        if !alreadyInstalled {
            preToolHooks.append(matcherEntry)
            hooks["PreToolUse"] = preToolHooks
        }

        // 4. Install Notification hook (async, fire-and-forget)
        try installScript(notificationHookScriptName, contents: bundledNotificationHookContents(), fm: fm)
        registerHook(
            &hooks, key: "Notification", matcher: "permission_prompt|idle_prompt",
            scriptName: notificationHookScriptName, timeout: 5000
        )

        // 5. Install Stop hook (async, fire-and-forget)
        try installScript(stopHookScriptName, contents: bundledStopHookContents(), fm: fm)
        registerHook(&hooks, key: "Stop", matcher: "", scriptName: stopHookScriptName, timeout: 5000)

        // 6. Install SessionStart hook (sync, returns additionalContext)
        try installScript(sessionStartHookScriptName, contents: bundledSessionStartHookContents(), fm: fm)
        registerHook(
            &hooks, key: "SessionStart", matcher: "startup|resume",
            scriptName: sessionStartHookScriptName, timeout: 5000
        )

        // 7. Install UserPromptSubmit hook (sync, returns additionalContext)
        try installScript(promptSubmitHookScriptName, contents: bundledPromptSubmitHookContents(), fm: fm)
        registerHook(
            &hooks, key: "UserPromptSubmit", matcher: "",
            scriptName: promptSubmitHookScriptName, timeout: 3000
        )

        // 8. Install PostToolUse hook (async, fire-and-forget — records tool usage for WWUD learning)
        try installScript(toolUsedHookScriptName, contents: bundledToolUsedHookContents(), fm: fm)
        registerHook(&hooks, key: "PostToolUse", matcher: "", scriptName: toolUsedHookScriptName, timeout: 3000)

        settings["hooks"] = hooks

        // Merge OTLP telemetry env vars
        var env = settings["env"] as? [String: String] ?? [:]
        for (key, value) in Self.otlpEnvValues {
            env[key] = value
        }
        settings["env"] = env

        try saveSettings(settings)

        AppLogger.hook.info("Installed all AFK hooks (\(allScriptNames.count, privacy: .public) scripts)")
    }

    /// Remove all hook scripts and unregister from Claude Code settings.
    func uninstall() throws {
        let fm = FileManager.default

        // 1. Remove all script files (current + legacy)
        for name in allScriptNames + legacyScriptNames {
            let path = scriptPath(name)
            if fm.fileExists(atPath: path) {
                try fm.removeItem(atPath: path)
            }
        }

        // 2. Remove from settings.json — clean all AFK hook keys
        var settings = loadSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for hookKey in Self.allHookKeys {
            if var hookEntries = hooks[hookKey] as? [[String: Any]] {
                let before = hookEntries.count
                hookEntries.removeAll { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { cmd in
                            guard let command = cmd["command"] as? String else { return false }
                            return (allScriptNames + legacyScriptNames).contains(where: { command.contains($0) })
                        }
                    }
                    return false
                }
                if hookEntries.count != before {
                    changed = true
                    if hookEntries.isEmpty {
                        hooks.removeValue(forKey: hookKey)
                    } else {
                        hooks[hookKey] = hookEntries
                    }
                }
            }
        }

        // Remove OTLP env vars
        if var env = settings["env"] as? [String: String] {
            for key in Self.otlpEnvKeys {
                env.removeValue(forKey: key)
            }
            if env.isEmpty {
                settings.removeValue(forKey: "env")
            } else {
                settings["env"] = env
            }
            changed = true
        }

        if changed {
            if hooks.isEmpty {
                settings.removeValue(forKey: "hooks")
            } else {
                settings["hooks"] = hooks
            }
            try saveSettings(settings)
        }

        AppLogger.hook.info("Uninstalled all AFK hooks (\(allScriptNames.count, privacy: .public) scripts)")
    }

    var isInstalled: Bool {
        allScriptNames.allSatisfy { FileManager.default.fileExists(atPath: scriptPath($0)) }
    }

    // MARK: - Private

    // MARK: - Helpers

    /// Write a hook script to disk and make it executable.
    private func installScript(_ name: String, contents: String, fm: FileManager) throws {
        let path = scriptPath(name)
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    /// Register a hook in settings.json if not already present.
    private func registerHook(
        _ hooks: inout [String: Any],
        key: String,
        matcher: String,
        scriptName: String,
        timeout: Int
    ) {
        let hookEntry: [String: Any] = [
            "type": "command",
            "command": scriptPath(scriptName),
            "timeout": timeout
        ]
        let matcherEntry: [String: Any] = [
            "matcher": matcher,
            "hooks": [hookEntry]
        ]

        var entries = hooks[key] as? [[String: Any]] ?? []
        let alreadyInstalled = entries.contains { entry in
            if let entryHooks = entry["hooks"] as? [[String: Any]] {
                return entryHooks.contains { ($0["command"] as? String)?.contains(scriptName) == true }
            }
            return false
        }
        if !alreadyInstalled {
            entries.append(matcherEntry)
            hooks[key] = entries
        }
    }

    private func loadSettings() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func saveSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
    }

    private func bundledHookScriptContents() -> String {
        // Inline the script contents so the agent binary is self-contained.
        // Uses Python for reliable bidirectional Unix socket communication.
        // Falls back to socat, then nc as last resort.
        let configDir = BuildEnvironment.configDirectoryName
        return """
        #!/bin/bash
        # AFK Agent — Claude Code PreToolUse hook
        # Connects to the AFK Agent's Unix socket, sends the tool call JSON,
        # and waits for a permission decision response.
        set -euo pipefail
        LOG="$HOME/\(configDir)/run/hook-debug.log"
        BYPASS="$HOME/\(configDir)/run/hook-bypass"
        SOCKET="$HOME/\(configDir)/run/agent.sock"
        TIMEOUT=\(Int(hookTimeout / 1000))

        mkdir -p "$HOME/\(configDir)/run"

        # If bypass flag exists, exit immediately — no output means Claude Code
        # falls through to its normal built-in terminal permission prompts.
        if [ -f "$BYPASS" ]; then
            echo "$(date '+%H:%M:%S') HOOK BYPASSED (local mode)" >> "$LOG"
            exit 0
        fi

        INPUT=$(cat)

        echo "$(date '+%H:%M:%S') HOOK CALLED: input=${INPUT:0:200}" >> "$LOG"

        # Wait briefly for socket to become available (race with agent startup)
        for i in 1 2 3; do
            if [ -S "$SOCKET" ]; then break; fi
            sleep 0.5
        done
        if [ ! -S "$SOCKET" ]; then
            echo "$(date '+%H:%M:%S') SOCKET NOT FOUND" >> "$LOG"
            exit 0
        fi

        echo "$(date '+%H:%M:%S') SENDING TO SOCKET..." >> "$LOG"

        # Python approach: reliable bidirectional Unix socket communication.
        # Sends input, shuts down write side (signals EOF), reads response until
        # the Agent closes the connection. Handles long waits (iOS approval) correctly.
        send_via_python() {
            echo "$INPUT" | python3 -c "
        import sys, socket
        data = sys.stdin.buffer.read()
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect('$SOCKET')
        sock.settimeout($TIMEOUT)
        sock.sendall(data)
        sock.shutdown(socket.SHUT_WR)
        resp = b''
        try:
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                resp += chunk
        except socket.timeout:
            pass
        sock.close()
        sys.stdout.buffer.write(resp)
        " 2>/dev/null
        }

        # socat fallback: bidirectional with proper timeout handling.
        send_via_socat() {
            echo "$INPUT" | socat -t "$TIMEOUT" -T "$TIMEOUT" - "UNIX-CONNECT:$SOCKET" 2>/dev/null
        }

        # nc last resort: may have pipe/timing issues on some macOS versions.
        send_via_nc() {
            echo "$INPUT" | nc -U "$SOCKET" -w "$TIMEOUT" 2>/dev/null
        }

        RESPONSE=""
        if command -v python3 >/dev/null 2>&1; then
            RESPONSE=$(send_via_python) || true
            echo "$(date '+%H:%M:%S') USED: python3" >> "$LOG"
        elif command -v socat >/dev/null 2>&1; then
            RESPONSE=$(send_via_socat) || true
            echo "$(date '+%H:%M:%S') USED: socat" >> "$LOG"
        elif command -v nc >/dev/null 2>&1; then
            RESPONSE=$(send_via_nc) || true
            echo "$(date '+%H:%M:%S') USED: nc (last resort)" >> "$LOG"
        else
            echo "$(date '+%H:%M:%S') NO PYTHON3, SOCAT, OR NC" >> "$LOG"
            exit 0
        fi

        echo "$(date '+%H:%M:%S') RESPONSE: ${RESPONSE:-empty}" >> "$LOG"

        if [ -z "${RESPONSE:-}" ]; then
            exit 0
        fi

        echo "$RESPONSE"
        """
    }

    // MARK: - Notification Hook (async, fire-and-forget)

    private func bundledNotificationHookContents() -> String {
        let configDir = BuildEnvironment.configDirectoryName
        return """
        #!/bin/bash
        # AFK Agent — Claude Code Notification hook (async)
        # Fire-and-forget: wraps notification JSON in envelope and sends to Unix socket.
        # Always exits 0. No response expected.
        SOCKET="$HOME/\(configDir)/run/agent.sock"

        INPUT=$(cat 2>/dev/null) || true
        [ -z "$INPUT" ] && exit 0
        [ ! -S "$SOCKET" ] && exit 0

        ENVELOPE="{\\"type\\":\\"notification\\",\\"payload\\":$INPUT}"
        echo "$ENVELOPE" | python3 -c "
        import sys, socket
        data = sys.stdin.buffer.read()
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect('$SOCKET')
            sock.settimeout(5)
            sock.sendall(data)
            sock.shutdown(socket.SHUT_WR)
        except:
            pass
        sock.close()
        " 2>/dev/null || true
        exit 0
        """
    }

    // MARK: - Stop Hook (async, fire-and-forget)

    private func bundledStopHookContents() -> String {
        let configDir = BuildEnvironment.configDirectoryName
        return """
        #!/bin/bash
        # AFK Agent — Claude Code Stop hook (async)
        # Fire-and-forget: forwards stop event to Unix socket.
        # CRITICAL: Must check stop_hook_active to prevent infinite loops.
        SOCKET="$HOME/\(configDir)/run/agent.sock"

        INPUT=$(cat 2>/dev/null) || true
        [ -z "$INPUT" ] && exit 0

        # Infinite loop prevention: if stop_hook_active is true, Claude is already
        # continuing from a previous Stop hook block. Exit immediately.
        if echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('stop_hook_active') else 1)" 2>/dev/null; then
            exit 0
        fi

        [ ! -S "$SOCKET" ] && exit 0

        ENVELOPE="{\\"type\\":\\"stop\\",\\"payload\\":$INPUT}"
        echo "$ENVELOPE" | python3 -c "
        import sys, socket
        data = sys.stdin.buffer.read()
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect('$SOCKET')
            sock.settimeout(5)
            sock.sendall(data)
            sock.shutdown(socket.SHUT_WR)
        except:
            pass
        sock.close()
        " 2>/dev/null || true
        exit 0
        """
    }

    // MARK: - SessionStart Hook (sync, returns additionalContext)

    private func bundledSessionStartHookContents() -> String {
        return """
        #!/bin/bash
        # AFK Agent — Claude Code SessionStart hook
        # Injects additionalContext so Claude knows it's in an AFK-monitored session.
        cat > /dev/null
        cat << 'JSONEOF'
        {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"[AFK] This session is monitored by the AFK mobile app. The user is away from the keyboard and may approve or deny tool calls remotely from their phone. Permission requests are forwarded to the user's iOS device."}}
        JSONEOF
        """
    }

    // MARK: - UserPromptSubmit Hook (sync, returns additionalContext)

    private func bundledPromptSubmitHookContents() -> String {
        return """
        #!/bin/bash
        # AFK Agent — Claude Code UserPromptSubmit hook
        # Re-injects AFK context on every prompt. Survives context compaction.
        cat > /dev/null
        cat << 'JSONEOF'
        {"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"[AFK] Session is remotely monitored via the AFK mobile app. Tool permissions are managed remotely."}}
        JSONEOF
        """
    }

    // MARK: - PostToolUse Hook (async, fire-and-forget — WWUD learning)

    private func bundledToolUsedHookContents() -> String {
        let configDir = BuildEnvironment.configDirectoryName
        return """
        #!/bin/bash
        # AFK Agent — Claude Code PostToolUse hook (async)
        # Fire-and-forget: notifies agent that a tool was executed (allowed).
        # Used by WWUD engine to learn from terminal permission decisions.
        SOCKET="$HOME/\(configDir)/run/agent.sock"

        INPUT=$(cat 2>/dev/null) || true
        [ -z "$INPUT" ] && exit 0
        [ ! -S "$SOCKET" ] && exit 0

        ENVELOPE="{\\"type\\":\\"tool_used\\",\\"payload\\":$INPUT}"
        echo "$ENVELOPE" | python3 -c "
        import sys, socket
        data = sys.stdin.buffer.read()
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect('$SOCKET')
            sock.settimeout(3)
            sock.sendall(data)
            sock.shutdown(socket.SHUT_WR)
        except:
            pass
        sock.close()
        " 2>/dev/null || true
        exit 0
        """
    }
}
