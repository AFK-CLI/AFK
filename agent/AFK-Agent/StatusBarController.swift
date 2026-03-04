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
    private var planAutoExitMenuItem: NSMenuItem!
    private var loginItemMenuItem: NSMenuItem!
    private var checkForUpdatesMenuItem: NSMenuItem!
    private var accountMenuItem: NSMenuItem!
    private var signInOutMenuItem: NSMenuItem!
    private var remoteSessionsMenuItem: NSMenuItem!
    private var remoteSessionsSubmenu: NSMenu!
    private var preventSleepMenuItem: NSMenuItem!
    private var copyResumeMenuItem: NSMenuItem!

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

    /// Flag file path — when present, the hook script injects Shift+Tab after ExitPlanMode approval.
    static var planAutoExitFlagPath: String { "\(runDir)/plan-autoexit" }

    // Thread-safe bypass flag — also checked inside PermissionSocket as secondary guard.
    private static let lock = NSLock()
    private static var _hookBypassed = false

    static var isHookBypassed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _hookBypassed
    }

    static var isPlanAutoExitEnabled: Bool {
        FileManager.default.fileExists(atPath: planAutoExitFlagPath)
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

    /// Remote-control setter: enable/disable auto plan exit without confirmation dialog.
    func setAutoPlanExit(_ enabled: Bool) {
        if enabled {
            createPlanAutoExitFlag()
            planAutoExitMenuItem.state = .on
            AppLogger.statusBar.info("Auto Plan Exit enabled (remote)")
        } else {
            removePlanAutoExitFlag()
            planAutoExitMenuItem.state = .off
            AppLogger.statusBar.info("Auto Plan Exit disabled (remote)")
        }
        onControlStateChanged?()
    }

    init(config: AgentConfig? = nil) {
        self.agentConfig = config
        super.init()
        // Clean up stale flag files on startup (default: remote approval ON, auto plan exit OFF)
        removeFlagFile()
        removePlanAutoExitFlag()
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

        hookMenuItem = NSMenuItem(
            title: "Remote Approval",
            action: #selector(toggleHook),
            keyEquivalent: ""
        )
        hookMenuItem.target = self
        hookMenuItem.state = .on

        planAutoExitMenuItem = NSMenuItem(
            title: "Auto Plan Exit",
            action: #selector(togglePlanAutoExit),
            keyEquivalent: ""
        )
        planAutoExitMenuItem.target = self
        planAutoExitMenuItem.state = .off

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
        menu.addItem(planAutoExitMenuItem)
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

    @objc private func togglePlanAutoExit() {
        let enabling = planAutoExitMenuItem.state == .off

        if enabling {
            // Show warning alert before enabling
            let alert = NSAlert()
            alert.messageText = "Auto Plan Exit"
            alert.informativeText = """
                When enabled, AFK will automatically send Shift+Tab to the frontmost \
                application when a plan is approved from iOS. This requires:

                \u{2022} Terminal app (VS Code / Terminal / iTerm) must be the focused window
                \u{2022} Accessibility permission must be granted in System Preferences \u{2192} \
                Privacy & Security \u{2192} Accessibility

                If the terminal is not focused, the keystroke will go to the wrong application.
                """
            alert.addButton(withTitle: "Enable")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }

            createPlanAutoExitFlag()
            planAutoExitMenuItem.state = .on
            AppLogger.statusBar.info("Auto Plan Exit enabled — keystroke injection active")
        } else {
            removePlanAutoExitFlag()
            planAutoExitMenuItem.state = .off
            AppLogger.statusBar.info("Auto Plan Exit disabled — no keystroke injection")
        }
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
                updateCheckInterval: config.updateCheckInterval
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

    @objc private func quitApp() {
        removeFlagFile()
        removePlanAutoExitFlag()
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

    // MARK: - Flag file management

    private func createFlagFile() {
        FileManager.default.createFile(atPath: Self.bypassFlagPath, contents: nil)
    }

    private func removeFlagFile() {
        try? FileManager.default.removeItem(atPath: Self.bypassFlagPath)
    }

    private func createPlanAutoExitFlag() {
        FileManager.default.createFile(atPath: Self.planAutoExitFlagPath, contents: nil)
    }

    private func removePlanAutoExitFlag() {
        try? FileManager.default.removeItem(atPath: Self.planAutoExitFlagPath)
    }
}
