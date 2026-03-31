//
//  StatusBarController.swift
//  AFK-Agent
//
//  Menu bar status item that lets the user bypass the permission hook
//  when they're at their Mac. When bypassed, a flag file is created
//  that the hook script checks — if present, the script exits before
//  connecting to the socket, so Claude Code falls back to its normal
//  built-in terminal permission prompts.
//

import AppKit
import OSLog
#if canImport(Sparkle)
import Sparkle
#endif

final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var hookMenuItem: NSMenuItem!

    private var loginItemMenuItem: NSMenuItem!
    private var checkForUpdatesMenuItem: NSMenuItem!
    private var accountMenuItem: NSMenuItem!
    private var signInOutMenuItem: NSMenuItem!
    private var remoteSessionsMenuItem: NSMenuItem!
    private var remoteSessionsSubmenu: NSMenu!
    private var preventSleepMenuItem: NSMenuItem!
    private var copyResumeMenuItem: NSMenuItem!
    private var usageSessionMenuItem: NSMenuItem!
    private var usageWeeklyMenuItem: NSMenuItem!

    let sleepPreventer = SleepPreventer()
    private var sessionPickerWindow: SessionPickerWindow?
    private(set) var agentConfig: AgentConfig?

    /// Tracks sessions started from iOS for the menu bar submenu.
    /// Must be a class (not struct) so NSMenuItem.representedObject can round-trip via `as?`.
    class RemoteSession: NSObject {
        let sessionId: String
        let projectPath: String
        init(sessionId: String, projectPath: String) {
            self.sessionId = sessionId
            self.projectPath = projectPath
        }
    }
    private var remoteSessions: [RemoteSession] = []
    private static let maxRemoteSessions = 10

    var onSignIn: (() -> Void)?
    var onSignOut: (() -> Void)?
    var onControlStateChanged: (() -> Void)?
    var onSendFeedback: (() -> Void)?
    var onShareLogs: (() -> Void)?
    var onSettingsChanged: ((AgentConfig) -> Void)?

    /// Async provider for all active sessions (local + remote).
    /// Wired by AFKAgentMain to query Agent's SessionStateManager + SessionIndex.
    var activeSessionProvider: (@Sendable () async -> [SessionEntry])?

    /// Runtime directory for flag files and sockets.
    static var runDir: String {
        let dir = BuildEnvironment.configDirectoryPath + "/run"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Flag file path — the hook script checks this before connecting to the socket.
    static var bypassFlagPath: String { "\(runDir)/hook-bypass" }

    // Thread-safe bypass flag — also checked inside PermissionSocket as secondary guard.
    private static let lock = NSLock()
    private static var _hookBypassed = false

    static var isHookBypassed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _hookBypassed
    }

    /// Remote-control setter: enable/disable remote approval without confirmation dialog.
    func setRemoteApproval(_ enabled: Bool) {
        let bypassed = !enabled
        Self.lock.lock()
        Self._hookBypassed = bypassed
        Self.lock.unlock()

        if bypassed {
            createFlagFile()
        } else {
            removeFlagFile()
        }

        hookMenuItem.state = bypassed ? .off : .on

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: bypassed ? "shield.slash" : "shield.lefthalf.filled",
                accessibilityDescription: "AFK Agent"
            )
        }

        AppLogger.statusBar.info("Remote approval \(bypassed ? "disabled — terminal prompts active" : "enabled — forwarding to iOS", privacy: .public) (remote)")
        onControlStateChanged?()
    }

    init(config: AgentConfig? = nil) {
        self.agentConfig = config
        super.init()
        // Clean up stale flag files on startup (default: remote approval ON)
        removeFlagFile()
        setupStatusBar()

        // Sync sleep preventer with config on startup
        if config?.preventSleep == true {
            sleepPreventer.start()
            preventSleepMenuItem.state = .on
        }
    }

    /// Update the stored config reference (called when settings change).
    func updateConfig(_ config: AgentConfig) {
        self.agentConfig = config

        // Sync sleep preventer state
        if config.preventSleep && !sleepPreventer.isActive {
            sleepPreventer.start()
        } else if !config.preventSleep && sleepPreventer.isActive {
            sleepPreventer.stop()
        }
        preventSleepMenuItem.state = sleepPreventer.isActive ? .on : .off
    }

    private var menu: NSMenu!

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "shield.lefthalf.filled",
                accessibilityDescription: "AFK Agent"
            )
            #if DEBUG
            button.title = " DEV"
            #endif
            button.target = self
            button.action = #selector(statusBarClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        menu = NSMenu()

        accountMenuItem = NSMenuItem(title: "Not signed in", action: nil, keyEquivalent: "")
        accountMenuItem.isEnabled = false
        menu.addItem(accountMenuItem)

        signInOutMenuItem = NSMenuItem(title: "Sign In\u{2026}", action: #selector(handleSignInOut), keyEquivalent: "")
        signInOutMenuItem.target = self
        menu.addItem(signInOutMenuItem)

        menu.addItem(.separator())

        usageSessionMenuItem = NSMenuItem(title: "No CLI account", action: nil, keyEquivalent: "")
        usageSessionMenuItem.isEnabled = false
        usageSessionMenuItem.isHidden = true
        menu.addItem(usageSessionMenuItem)

        usageWeeklyMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        usageWeeklyMenuItem.isEnabled = false
        usageWeeklyMenuItem.isHidden = true
        menu.addItem(usageWeeklyMenuItem)

        menu.addItem(.separator())

        hookMenuItem = NSMenuItem(
            title: "Remote Approval",
            action: #selector(toggleHook),
            keyEquivalent: ""
        )
        hookMenuItem.target = self
        hookMenuItem.state = .on

        loginItemMenuItem = NSMenuItem(
            title: "Start at Login",
            action: #selector(toggleLoginItem),
            keyEquivalent: ""
        )
        loginItemMenuItem.target = self
        loginItemMenuItem.state = LoginItemManager.isEnabled ? .on : .off

        checkForUpdatesMenuItem = NSMenuItem(
            title: "Check for Updates\u{2026}",
            action: nil, // wired when Sparkle is available
            keyEquivalent: ""
        )
        checkForUpdatesMenuItem.isEnabled = false

        remoteSessionsSubmenu = NSMenu()
        remoteSessionsMenuItem = NSMenuItem(
            title: "Remote Sessions",
            action: nil,
            keyEquivalent: ""
        )
        remoteSessionsMenuItem.submenu = remoteSessionsSubmenu
        remoteSessionsMenuItem.isHidden = true  // hidden until first remote session

        copyResumeMenuItem = NSMenuItem(
            title: "Copy Resume Command",
            action: #selector(handleCopyResumeCommand),
            keyEquivalent: ""
        )
        copyResumeMenuItem.target = self
        copyResumeMenuItem.isEnabled = true

        preventSleepMenuItem = NSMenuItem(
            title: "Prevent Sleep",
            action: #selector(togglePreventSleep),
            keyEquivalent: ""
        )
        preventSleepMenuItem.target = self
        preventSleepMenuItem.state = .off

        menu.addItem(remoteSessionsMenuItem)
        menu.addItem(copyResumeMenuItem)
        menu.addItem(.separator())
        menu.addItem(hookMenuItem)
        menu.addItem(preventSleepMenuItem)
        menu.addItem(loginItemMenuItem)

        menu.addItem(.separator())

        let feedbackItem = NSMenuItem(
            title: "Send Feedback\u{2026}",
            action: #selector(handleSendFeedback),
            keyEquivalent: ""
        )
        feedbackItem.target = self
        menu.addItem(feedbackItem)

        let shareLogsItem = NSMenuItem(
            title: "Share Logs\u{2026}",
            action: #selector(handleShareLogs),
            keyEquivalent: ""
        )
        shareLogsItem.target = self
        menu.addItem(shareLogsItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings\u{2026}",
            action: #selector(handleShowSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(checkForUpdatesMenuItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Agent",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

    }

    @objc private func statusBarClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.modifierFlags.contains(.control) {
            if agentConfig?.ctrlClickTogglesRemoteAndSleep == true {
                // Combo toggle: remote approval + sleep prevention together
                toggleHook()
                togglePreventSleep()
            } else {
                toggleHook()
            }
        } else {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        }
    }

    @objc private func toggleHook() {
        Self.lock.lock()
        Self._hookBypassed.toggle()
        let bypassed = Self._hookBypassed
        Self.lock.unlock()

        if bypassed {
            createFlagFile()
        } else {
            removeFlagFile()
        }

        hookMenuItem.state = bypassed ? .off : .on

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: bypassed ? "shield.slash" : "shield.lefthalf.filled",
                accessibilityDescription: "AFK Agent"
            )
        }

        AppLogger.statusBar.info("Remote approval \(bypassed ? "disabled — terminal prompts active" : "enabled — forwarding to iOS", privacy: .public)")
        onControlStateChanged?()
    }

    @objc private func toggleLoginItem() {
        let enabling = !LoginItemManager.isEnabled
        do {
            try LoginItemManager.setEnabled(enabling)
            loginItemMenuItem.state = enabling ? .on : .off
            AppLogger.statusBar.info("Start at Login \(enabling ? "enabled" : "disabled", privacy: .public)")
        } catch {
            AppLogger.statusBar.error("Failed to toggle login item: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Wire Sparkle's "Check for Updates" action to the menu item.
    #if canImport(Sparkle)
    func setUpdaterAction(target: SPUStandardUpdaterController) {
        checkForUpdatesMenuItem.target = target
        checkForUpdatesMenuItem.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        checkForUpdatesMenuItem.isEnabled = true
    }
    #else
    func setUpdaterAction(target: Any) {
        // Sparkle not available — menu item stays disabled.
    }
    #endif

    @objc private func handleSignInOut() {
        if signInOutMenuItem.title == "Sign In\u{2026}" {
            onSignIn?()
        } else {
            onSignOut?()
        }
    }

    @objc private func handleSendFeedback() {
        onSendFeedback?()
    }

    @objc private func handleShareLogs() {
        onShareLogs?()
    }

    @objc private func togglePreventSleep() {
        if sleepPreventer.isActive {
            sleepPreventer.stop()
            preventSleepMenuItem.state = .off
        } else {
            sleepPreventer.start()
            preventSleepMenuItem.state = .on
        }

        // Persist the change to config
        if var config = agentConfig {
            config = AgentConfig(
                serverURL: config.serverURL,
                deviceID: config.deviceID,
                authToken: config.authToken,
                claudeProjectsPath: config.claudeProjectsPath,
                heartbeatInterval: config.heartbeatInterval,
                idleTimeout: config.idleTimeout,
                completedTimeout: config.completedTimeout,
                permissionStallTimeout: config.permissionStallTimeout,
                remoteApprovalEnabled: config.remoteApprovalEnabled,
                remoteApprovalTimeout: config.remoteApprovalTimeout,
                hookInstallPath: config.hookInstallPath,
                defaultPrivacyMode: config.defaultPrivacyMode,
                projectPrivacyOverrides: config.projectPrivacyOverrides,
                acceptLegacyPermissionFallback: config.acceptLegacyPermissionFallback,
                deviceName: config.deviceName,
                logLevel: config.logLevel,
                hooksEnabled: config.hooksEnabled,
                planAutoExit: config.planAutoExit,
                obeySettingsRules: config.obeySettingsRules,
                preventSleep: sleepPreventer.isActive,
                ctrlClickTogglesRemoteAndSleep: config.ctrlClickTogglesRemoteAndSleep,
                notifyOnIdle: config.notifyOnIdle,
                usagePollingEnabled: config.usagePollingEnabled,
                updateCheckInterval: config.updateCheckInterval,
                enabledProviders: config.enabledProviders,
                openCodePollInterval: config.openCodePollInterval,
                openCodeServerPort: config.openCodeServerPort
            )
            config.save()
            agentConfig = config
            onSettingsChanged?(config)
        }
    }

    @objc private func handleShowSettings() {
        SettingsWindow.shared.show()
    }

    @objc private func handleCopyResumeCommand() {
        guard let provider = activeSessionProvider else {
            // Fallback to remote sessions if no provider wired
            handleCopyResume(entries: remoteSessions.map {
                SessionEntry(sessionId: $0.sessionId, projectPath: $0.projectPath, status: "running")
            })
            return
        }

        Task {
            let entries = await provider()
            DispatchQueue.main.async { [weak self] in
                self?.handleCopyResume(entries: entries)
            }
        }
    }

    private func handleCopyResume(entries: [SessionEntry]) {
        if entries.count == 1, let entry = entries.first {
            copyResumeCommand(sessionId: entry.sessionId, projectPath: entry.projectPath)
            NSSound.beep()
        } else if entries.count > 1 {
            sessionPickerWindow = SessionPickerWindow()
            sessionPickerWindow?.show(sessions: entries) { [weak self] entry in
                self?.copyResumeCommand(sessionId: entry.sessionId, projectPath: entry.projectPath)
                NSSound.beep()
            }
        }
    }

    func updateAccount(email: String?) {
        if let email {
            accountMenuItem.title = email
            signInOutMenuItem.title = "Sign Out"
        } else {
            accountMenuItem.title = "Not signed in"
            signInOutMenuItem.title = "Sign In\u{2026}"
        }
    }

    func updateUsage(_ usage: ClaudeUsage?) {
        guard let usage else {
            usageSessionMenuItem.isHidden = true
            usageWeeklyMenuItem.isHidden = true
            return
        }

        let resetIn = Self.formatTimeRemaining(until: usage.sessionResetTime)
        let sessionColor = Self.usageColor(usage.sessionPercentage)
        usageSessionMenuItem.title = "Session: \(Int(usage.sessionPercentage))% used \u{2014} resets in \(resetIn)"
        usageSessionMenuItem.isHidden = false
        let sessionImage = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        sessionImage?.isTemplate = false
        usageSessionMenuItem.image = Self.tintedCircle(sessionColor)

        usageWeeklyMenuItem.title = "Weekly: \(Int(usage.weeklyPercentage))% \u{2014} Opus: \(Int(usage.opusWeeklyPercentage))% \u{2014} Sonnet: \(Int(usage.sonnetWeeklyPercentage))%"
        usageWeeklyMenuItem.isHidden = false
        let weeklyColor = Self.usageColor(usage.weeklyPercentage)
        usageWeeklyMenuItem.image = Self.tintedCircle(weeklyColor)
    }

    private static func usageColor(_ percentage: Double) -> NSColor {
        if percentage >= 80 { return .systemRed }
        if percentage >= 50 { return .systemOrange }
        return .systemGreen
    }

    private static func tintedCircle(_ color: NSColor) -> NSImage? {
        guard let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
        let sized = image.withSymbolConfiguration(config) ?? image
        return sized.tinted(with: color)
    }

    private static func formatTimeRemaining(until date: Date) -> String {
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return "now" }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    @objc private func quitApp() {
        removeFlagFile()
        sleepPreventer.stop()
        AppLogger.agent.info("Shutting down via menu bar...")
        exit(0)
    }

    // MARK: - Remote session management

    /// Register a session started from the iOS app and post a notification with the resume command.
    func addRemoteSession(sessionId: String, projectPath: String) {
        let session = RemoteSession(sessionId: sessionId, projectPath: projectPath)
        remoteSessions.insert(session, at: 0)
        if remoteSessions.count > Self.maxRemoteSessions {
            remoteSessions.removeLast()
        }
        rebuildRemoteSessionsSubmenu()
        copyResumeCommand(sessionId: sessionId, projectPath: projectPath)
        postResumeNotification(sessionId: sessionId, projectPath: projectPath)
    }

    /// Remove a remote session (e.g. when it completes).
    func removeRemoteSession(sessionId: String) {
        remoteSessions.removeAll { $0.sessionId == sessionId }
        rebuildRemoteSessionsSubmenu()
    }

    private func rebuildRemoteSessionsSubmenu() {
        remoteSessionsSubmenu.removeAllItems()
        remoteSessionsMenuItem.isHidden = remoteSessions.isEmpty
        copyResumeMenuItem.isEnabled = !remoteSessions.isEmpty

        for session in remoteSessions {
            let projectName = (session.projectPath as NSString).lastPathComponent
            let shortId = String(session.sessionId.prefix(8))
            let title = "\(projectName) (\(shortId))"

            let item = NSMenuItem(title: title, action: #selector(copySessionCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = session
            item.toolTip = "Click to copy resume command"
            remoteSessionsSubmenu.addItem(item)
        }

        if !remoteSessions.isEmpty {
            remoteSessionsSubmenu.addItem(.separator())
            let clearItem = NSMenuItem(title: "Clear All", action: #selector(clearRemoteSessions), keyEquivalent: "")
            clearItem.target = self
            remoteSessionsSubmenu.addItem(clearItem)
        }
    }

    @objc private func copySessionCommand(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? RemoteSession else { return }
        copyResumeCommand(sessionId: session.sessionId, projectPath: session.projectPath)
    }

    @objc private func clearRemoteSessions() {
        remoteSessions.removeAll()
        rebuildRemoteSessionsSubmenu()
    }

    private func copyResumeCommand(sessionId: String, projectPath: String) {
        let command: String
        if !projectPath.isEmpty {
            command = "cd \(shellEscape(projectPath)) && claude --resume \(sessionId)"
        } else {
            command = "claude --resume \(sessionId)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        AppLogger.statusBar.info("Copied resume command for session \(sessionId.prefix(8), privacy: .public)")
    }

    private func postResumeNotification(sessionId: String, projectPath: String) {
        let projectName = projectPath.isEmpty ? "unknown" : (projectPath as NSString).lastPathComponent
        let shortId = String(sessionId.prefix(8))
        // Sanitize for AppleScript to prevent injection
        let safeProject = projectName.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." || $0 == " " }
        let safeId = shortId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !safeId.isEmpty else { return }
        let script = "display notification \"Resume command copied to clipboard (\(safeId))\" with title \"AFK: Remote Session\" subtitle \"\(safeProject)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Shell-escape a path for safe pasting into a terminal.
    private func shellEscape(_ path: String) -> String {
        if path.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/-_.")).inverted) != nil {
            return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return path
    }

    // MARK: - Attention state (idle/waiting icon)

    /// Set the menu bar icon to an attention color (orange) indicating Claude is waiting.
    func setAttention(_ on: Bool) {
        guard let button = statusItem.button else { return }
        let bypassed = Self.isHookBypassed
        let symbolName = bypassed ? "shield.slash" : "shield.lefthalf.filled"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "AFK Agent")

        if on {
            let config = NSImage.SymbolConfiguration(paletteColors: [.orange])
            button.image = image?.withSymbolConfiguration(config)
        } else {
            button.image = image
        }
    }

    // MARK: - Flag file management

    private func createFlagFile() {
        FileManager.default.createFile(atPath: Self.bypassFlagPath, contents: nil)
    }

    private func removeFlagFile() {
        try? FileManager.default.removeItem(atPath: Self.bypassFlagPath)
    }
}

// MARK: - NSImage tinting

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let image = self.copy() as! NSImage
        image.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: image.size)
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
