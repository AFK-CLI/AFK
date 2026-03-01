//
//  AFKAgentMain.swift
//  AFK-Agent
//

import AppKit
import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

// Keep strong reference so menu item targets don't dangle.
private var statusBarController: StatusBarController?
private var setupController: SetupWindowController?
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
        statusBarController = StatusBarController()
        let agent = Agent(config: config, statusBarController: statusBarController)

        #if canImport(Sparkle)
        if let updater = updaterController {
            statusBarController?.setUpdaterAction(target: updater)
        }
        #endif

        statusBarController?.onSignIn = {
            Task { await agent.signIn() }
        }
        statusBarController?.onSignOut = {
            Task { await agent.signOut() }
        }
        statusBarController?.onControlStateChanged = {
            Task { await agent.broadcastControlState() }
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
