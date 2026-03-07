//
//  AFKAgentMain.swift
//  AFK-Agent
//

import AppKit
import Foundation
import UserNotifications
#if canImport(Sparkle)
import Sparkle
#endif

// Keep strong reference so menu item targets don't dangle.
private var statusBarController: StatusBarController?
private var setupController: SetupWindowController?
private var feedbackController: FeedbackWindowController?
#if canImport(Sparkle)
// Sparkle updater — must be retained for the lifetime of the app.
private var updaterController: SPUStandardUpdaterController?
#endif

@main
struct AFKAgentMain {
    static func main() {
        // Ignore SIGPIPE so writing to closed sockets returns EPIPE instead of killing the process
        signal(SIGPIPE, SIG_IGN)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // Request notification permission for idle/waiting alerts
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        #if canImport(Sparkle)
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        let feedString = GeneratedConfig.feedURL
        if !feedString.isEmpty, let feedURL = URL(string: feedString) {
            updaterController?.updater.setFeedURL(feedURL)
        }
        try? updaterController?.updater.start()
        #endif

        let config = AgentConfig.load()

        #if canImport(Sparkle)
        if let updater = updaterController?.updater {
            updater.automaticallyChecksForUpdates = config.updateCheckInterval > 0
            updater.updateCheckInterval = config.updateCheckInterval > 0 ? config.updateCheckInterval : 3600
        }
        #endif

        if config.isConfigured {
            startAgent(config: config, app: app)
        } else {
            // Show setup window
            setupController = SetupWindowController()
            setupController?.showSetupWindow { newConfig in
                startAgent(config: newConfig, app: app)
            }
        }

        // Start main run loop — required for NSStatusItem to work.
        app.run()
    }

    private static func startAgent(config: AgentConfig, app: NSApplication) {
        statusBarController = StatusBarController(config: config)
        let agent = Agent(config: config, statusBarController: statusBarController)

        #if canImport(Sparkle)
        if let updater = updaterController {
            statusBarController?.setUpdaterAction(target: updater)
        }
        #endif

        // Configure SettingsWindow with current config and Sparkle updater
        if let sbc = statusBarController {
            SettingsWindow.shared.configure(
                config: config,
                sleepPreventer: sbc.sleepPreventer,
                onConfigChanged: { newConfig in
                    sbc.updateConfig(newConfig)
                    sbc.onSettingsChanged?(newConfig)
                    Task { await agent.updateConfig(newConfig) }
                },
                onRemoteApprovalChanged: { enabled in
                    sbc.setRemoteApproval(enabled)
                }
            )
            #if canImport(Sparkle)
            if let updater = updaterController {
                SettingsWindow.shared.setUpdaterController(updater)
            }
            #endif
        }

        statusBarController?.activeSessionProvider = {
            let sessions = await agent.stateManager.allSessions()
            var entries: [SessionEntry] = []
            for (sessionId, info) in sessions {
                guard info.status == .running || info.status == .idle || info.status == .waitingPermission else { continue }
                entries.append(SessionEntry(
                    sessionId: sessionId,
                    projectPath: info.projectPath,
                    status: info.status.rawValue
                ))
            }
            return entries
        }

        statusBarController?.onSignIn = {
            Task { await agent.signIn() }
        }
        statusBarController?.onSignOut = {
            Task { await agent.signOut() }
        }
        statusBarController?.onControlStateChanged = {
            Task { await agent.broadcastControlState() }
        }

        feedbackController = FeedbackWindowController()
        let showFeedback: () -> Void = {
            feedbackController?.showFeedbackWindow { category, message in
                Task { await agent.submitFeedback(category: category, message: message) }
            }
        }
        statusBarController?.onSendFeedback = showFeedback
        NotificationCenter.default.addObserver(forName: .settingsFeedbackRequested, object: nil, queue: .main) { _ in
            showFeedback()
        }

        statusBarController?.onShareLogs = {
            Task { await agent.shareLogs() }
        }

        agent.onAccountChanged = { email in
            DispatchQueue.main.async {
                statusBarController?.updateAccount(email: email)
            }
        }

        // Run agent on a background task
        Task {
            await agent.run()
        }
    }
}
