//
//  Agent+Lifecycle.swift
//  AFK-Agent
//

import Foundation
import AppKit
import OSLog

extension Agent {

    /// Register for NSApplication.willTerminateNotification to handle clean
    /// macOS shutdown, restart, and logout. Calls gracefulShutdown() to mark
    /// active sessions offline before the process exits.
    func registerTerminationObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            AppLogger.agent.info("Application will terminate — running graceful shutdown")
            // Use a semaphore to block the notification handler until shutdown completes,
            // since willTerminateNotification expects synchronous handling.
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await self.gracefulShutdown()
                semaphore.signal()
            }
            // Wait briefly (up to 2s) for shutdown to complete
            _ = semaphore.wait(timeout: .now() + 2.0)
        }
        AppLogger.agent.debug("Registered termination observer")
    }

    /// Send session.completed for all active sessions before exiting.
    func gracefulShutdown() async {
        // Save state before shutdown so next run can resume
        agentState.save()
        AppLogger.state.info("Saved state on shutdown")

        guard let client = wsClient else {
            AppLogger.agent.warning("No WS client — skipping session cleanup")
            return
        }
        let sessions = await stateManager.allSessions()
        let active = sessions.filter { $0.value.status == .running || $0.value.status == .idle }
        for (sessionId, _) in active {
            if let msg = try? MessageEncoder.sessionCompleted(sessionId: sessionId) {
                try? await client.send(msg)
                AppLogger.agent.info("Sent session.completed for \(sessionId.prefix(8), privacy: .public)")
            }
        }
        // Stop permission socket
        if let socket = permissionSocket {
            await socket.stop()
        }
        // Stop OTLP telemetry receiver
        if let receiver = otlpReceiver {
            await receiver.stop()
        }
        // Clean up shared skill files on quit
        if let installer = sharedSkillInstaller {
            await installer.cleanupSharedFiles()
        }
        // Close disk queue
        diskQueue?.close()
        // Brief delay to let WS messages flush
        try? await Task.sleep(for: .milliseconds(500))
        AppLogger.agent.info("Graceful shutdown complete")
    }

    /// Save current state to disk (called periodically and on shutdown).
    func saveState() {
        agentState.save()
    }

    // MARK: - State Cleanup

    /// Remove completed sessions from persistent state (called from timeoutLoop).
    func cleanupCompletedSession(_ sessionId: String) {
        agentState.removeSession(sessionId)
    }
}
