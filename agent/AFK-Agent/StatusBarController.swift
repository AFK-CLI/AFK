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

    var onSignIn: (() -> Void)?
    var onSignOut: (() -> Void)?
    var onControlStateChanged: (() -> Void)?

    /// Runtime directory for flag files and sockets.
    static var runDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.afk-agent/run"
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

        print("[StatusBar] Remote approval \(bypassed ? "disabled — terminal prompts active" : "enabled — forwarding to iOS") (remote)")
        onControlStateChanged?()
    }

    /// Remote-control setter: enable/disable auto plan exit without confirmation dialog.
    func setAutoPlanExit(_ enabled: Bool) {
        if enabled {
            createPlanAutoExitFlag()
            planAutoExitMenuItem.state = .on
            print("[StatusBar] Auto Plan Exit enabled (remote)")
        } else {
            removePlanAutoExitFlag()
            planAutoExitMenuItem.state = .off
            print("[StatusBar] Auto Plan Exit disabled (remote)")
        }
        onControlStateChanged?()
    }

    override init() {
        super.init()
        // Clean up stale flag files on startup (default: remote approval ON, auto plan exit OFF)
        removeFlagFile()
        removePlanAutoExitFlag()
        setupStatusBar()
    }

    private var menu: NSMenu!

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "shield.lefthalf.filled",
                accessibilityDescription: "AFK Agent"
            )
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

        menu.addItem(hookMenuItem)
        menu.addItem(planAutoExitMenuItem)
        menu.addItem(loginItemMenuItem)
        menu.addItem(.separator())
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
            toggleHook()
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

        print("[StatusBar] Remote approval \(bypassed ? "disabled — terminal prompts active" : "enabled — forwarding to iOS")")
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
            print("[StatusBar] Auto Plan Exit enabled — keystroke injection active")
        } else {
            removePlanAutoExitFlag()
            planAutoExitMenuItem.state = .off
            print("[StatusBar] Auto Plan Exit disabled — no keystroke injection")
        }
        onControlStateChanged?()
    }

    @objc private func toggleLoginItem() {
        let enabling = !LoginItemManager.isEnabled
        do {
            try LoginItemManager.setEnabled(enabling)
            loginItemMenuItem.state = enabling ? .on : .off
            print("[StatusBar] Start at Login \(enabling ? "enabled" : "disabled")")
        } catch {
            print("[StatusBar] Failed to toggle login item: \(error)")
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
        print("[Agent] Shutting down via menu bar...")
        exit(0)
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
