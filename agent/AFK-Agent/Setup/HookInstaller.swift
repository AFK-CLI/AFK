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
    private let postToolHookScriptName = "afk-plan-exit-hook.sh"
    private let hookTimeout: Int         // ms

    init(hookInstallDir: String, timeoutSeconds: TimeInterval) {
        self.hookInstallDir = hookInstallDir
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.settingsPath = "\(home)/.claude/settings.json"
        self.hookTimeout = Int(timeoutSeconds * 1000)
    }

    var installedHookPath: String {
        "\(hookInstallDir)/\(hookScriptName)"
    }

    var installedPostToolHookPath: String {
        "\(hookInstallDir)/\(postToolHookScriptName)"
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

        // 4. Install PostToolUse hook for ExitPlanMode TTY injection
        let postToolScript = bundledPostToolHookContents()
        try postToolScript.write(toFile: installedPostToolHookPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedPostToolHookPath)

        let postToolHookEntry: [String: Any] = [
            "type": "command",
            "command": installedPostToolHookPath,
            "timeout": 10000  // 10s timeout for PostToolUse
        ]
        let postToolMatcherEntry: [String: Any] = [
            "matcher": "ExitPlanMode",
            "hooks": [postToolHookEntry]
        ]

        var postToolHooks = hooks["PostToolUse"] as? [[String: Any]] ?? []
        let postToolAlreadyInstalled = postToolHooks.contains { entry in
            if let entryHooks = entry["hooks"] as? [[String: Any]] {
                return entryHooks.contains { ($0["command"] as? String)?.contains(postToolHookScriptName) == true }
            }
            return false
        }

        if !postToolAlreadyInstalled {
            postToolHooks.append(postToolMatcherEntry)
            hooks["PostToolUse"] = postToolHooks
        }

        settings["hooks"] = hooks
        try saveSettings(settings)

        AppLogger.hook.info("Installed \(hookScriptName, privacy: .public) at \(installedHookPath, privacy: .public)")
        AppLogger.hook.info("Installed \(postToolHookScriptName, privacy: .public) at \(installedPostToolHookPath, privacy: .public)")
    }

    /// Remove the hook script and unregister from Claude Code settings.
    func uninstall() throws {
        let fm = FileManager.default

        // 1. Remove the script files
        if fm.fileExists(atPath: installedHookPath) {
            try fm.removeItem(atPath: installedHookPath)
        }
        if fm.fileExists(atPath: installedPostToolHookPath) {
            try fm.removeItem(atPath: installedPostToolHookPath)
        }

        // 2. Remove from settings.json — clean PreToolUse, PostToolUse, and legacy PermissionRequest keys
        var settings = loadSettings()
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var changed = false

        let scriptNames = [hookScriptName, postToolHookScriptName]

        for hookKey in ["PreToolUse", "PostToolUse", "PermissionRequest"] {
            if var hookEntries = hooks[hookKey] as? [[String: Any]] {
                let before = hookEntries.count
                hookEntries.removeAll { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { cmd in
                            guard let command = cmd["command"] as? String else { return false }
                            return scriptNames.contains(where: { command.contains($0) })
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

        if changed {
            if hooks.isEmpty {
                settings.removeValue(forKey: "hooks")
            } else {
                settings["hooks"] = hooks
            }
            try saveSettings(settings)
        }

        AppLogger.hook.info("Uninstalled \(hookScriptName, privacy: .public) and \(postToolHookScriptName, privacy: .public)")
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedHookPath) &&
        FileManager.default.fileExists(atPath: installedPostToolHookPath)
    }

    // MARK: - Private

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

    private func bundledPostToolHookContents() -> String {
        // PostToolUse hook for ExitPlanMode — injects Shift+Tab to Claude Code's TTY
        // to complete the plan mode toggle after iOS approves ExitPlanMode.
        // IMPORTANT: Must NEVER exit non-zero — PostToolUse errors can break the session.
        let configDir = BuildEnvironment.configDirectoryName
        return """
        #!/bin/bash
        # AFK Agent — Claude Code PostToolUse hook (ExitPlanMode)
        # When ExitPlanMode fires after iOS approval, inject Shift+Tab into Claude's TTY
        # to complete the UI toggle from plan mode to normal mode.
        #
        # IMPORTANT: No 'set -e' — this script must ALWAYS exit 0.
        # A non-zero exit from PostToolUse causes Claude Code to raise an error.

        LOG="$HOME/\(configDir)/run/plan-hook-debug.log"
        mkdir -p "$HOME/\(configDir)/run"

        INPUT=$(cat 2>/dev/null) || true
        SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null) || true
        FLAG="$HOME/\(configDir)/run/plan-approved-${SESSION_ID:-unknown}"

        echo "$(date '+%H:%M:%S') PostToolUse fired: session=${SESSION_ID:-?}, flag=$FLAG" >> "$LOG" 2>/dev/null

        # Only act if the Agent left a flag file (meaning iOS approved ExitPlanMode)
        if [ ! -f "$FLAG" ]; then
            echo "$(date '+%H:%M:%S') No flag file — skipping (not AFK-approved)" >> "$LOG" 2>/dev/null
            exit 0
        fi
        rm -f "$FLAG"

        echo "$(date '+%H:%M:%S') Flag found — attempting Shift+Tab injection" >> "$LOG" 2>/dev/null

        # Method 1: /dev/tty — the controlling terminal of the process group.
        # This is the most reliable path for interactive sessions. Even though
        # the hook's stdin/stdout are pipes, /dev/tty opens the controlling terminal.
        if [ -w /dev/tty ] 2>/dev/null; then
            sleep 0.3
            printf '\\033[Z' > /dev/tty 2>/dev/null
            echo "$(date '+%H:%M:%S') Sent Shift+Tab via /dev/tty" >> "$LOG" 2>/dev/null
            exit 0
        fi

        echo "$(date '+%H:%M:%S') /dev/tty not writable, trying PPID chain" >> "$LOG" 2>/dev/null

        # Method 2: Walk PPID chain to find Claude Code's TTY via lsof + ps.
        PID=$PPID
        CLAUDE_TTY=""
        for i in 1 2 3 4 5 6 7 8; do
            PID=$(ps -p "$PID" -o ppid= 2>/dev/null | tr -d ' ') || true
            [ -z "$PID" ] || [ "$PID" = "1" ] && break

            # Try lsof to find stdin device (fd 0)
            TTY_DEV=$(lsof -a -p "$PID" -d 0 -Fn 2>/dev/null | grep '^n/dev/' | sed 's/^n//') || true
            if [ -n "$TTY_DEV" ] && [ -w "$TTY_DEV" ]; then
                CLAUDE_TTY="$TTY_DEV"
                echo "$(date '+%H:%M:%S') Found TTY via lsof: $CLAUDE_TTY (pid=$PID)" >> "$LOG" 2>/dev/null
                break
            fi

            # Fallback: ps tty column
            TTY=$(ps -p "$PID" -o tty= 2>/dev/null | tr -d ' ') || true
            if [ -n "$TTY" ] && [ "$TTY" != "??" ]; then
                DEV="/dev/$TTY"
                if [ -w "$DEV" ]; then
                    CLAUDE_TTY="$DEV"
                    echo "$(date '+%H:%M:%S') Found TTY via ps: $CLAUDE_TTY (pid=$PID)" >> "$LOG" 2>/dev/null
                    break
                fi
            fi
        done

        if [ -n "$CLAUDE_TTY" ]; then
            sleep 0.3
            printf '\\033[Z' > "$CLAUDE_TTY" 2>/dev/null
            echo "$(date '+%H:%M:%S') Sent Shift+Tab via $CLAUDE_TTY" >> "$LOG" 2>/dev/null
            exit 0
        fi

        echo "$(date '+%H:%M:%S') No TTY found — non-interactive session or TTY not accessible" >> "$LOG" 2>/dev/null

        # For non-interactive (-p) sessions, ExitPlanMode exits plan mode via the
        # hook's "allow" response alone — no Shift+Tab needed. Exit cleanly.
        exit 0
        """
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

        # ExitPlanMode: spawn background Shift+Tab injector (only when Auto Plan Exit is enabled).
        # Claude Code has an internal "Ready to code?" prompt for ExitPlanMode
        # that requires user interaction EVEN when the hook returns "allow".
        # The background process waits for the prompt to appear, then injects
        # Shift+Tab to answer it (selects option 1: clear context + auto-accept).
        PLAN_AUTOEXIT="$HOME/\(configDir)/run/plan-autoexit"
        if echo "$INPUT" | grep -q '"ExitPlanMode"' 2>/dev/null; then
            if echo "$RESPONSE" | grep -q '"allow"' 2>/dev/null; then
                PLOG="$HOME/\(configDir)/run/plan-hook-debug.log"
                # Clean up the PostToolUse flag file (PostToolUse doesn't fire for ExitPlanMode)
                _SID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null) || true
                rm -f "$HOME/\(configDir)/run/plan-approved-${_SID:-}" 2>/dev/null
                if [ -f "$PLAN_AUTOEXIT" ]; then
                    echo "$(date '+%H:%M:%S') ExitPlanMode allowed — spawning Shift+Tab injector" >> "$PLOG" 2>/dev/null
                    # Spawn detached background process — MUST close inherited pipes so
                    # Claude Code doesn't block waiting for our stdout/stderr to close.
                    (
                        exec </dev/null >/dev/null 2>/dev/null
                        sleep 1
                        # Use osascript System Events to send Shift+Tab keystroke to the
                        # frontmost application (the terminal running Claude Code).
                        # Requires: VS Code / Terminal.app must have Accessibility permission
                        # in System Preferences > Privacy & Security > Accessibility.
                        if osascript -e 'tell application "System Events" to key code 48 using shift down' 2>/dev/null; then
                            echo "$(date '+%H:%M:%S') Injected Shift+Tab via osascript System Events" >> "$PLOG" 2>/dev/null
                        else
                            echo "$(date '+%H:%M:%S') osascript failed (accessibility permission missing?)" >> "$PLOG" 2>/dev/null
                        fi
                    ) &
                else
                    echo "$(date '+%H:%M:%S') ExitPlanMode allowed — Auto Plan Exit disabled, skipping injection" >> "$PLOG" 2>/dev/null
                fi
            fi
        fi

        echo "$RESPONSE"
        """
    }
}
