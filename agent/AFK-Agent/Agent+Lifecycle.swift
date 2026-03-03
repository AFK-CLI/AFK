//
//  Agent+Lifecycle.swift
//  AFK-Agent
//

import Foundation

extension Agent {

    /// Send session.completed for all active sessions before exiting.
    func gracefulShutdown() async {
        // Save state before shutdown so next run can resume
        agentState.save()
        print("[State] Saved state on shutdown")

        guard let client = wsClient else {
            print("[Agent] No WS client — skipping session cleanup")
            return
        }
        let sessions = await stateManager.allSessions()
        let active = sessions.filter { $0.value.status == .running || $0.value.status == .idle }
        for (sessionId, _) in active {
            if let msg = try? MessageEncoder.sessionCompleted(sessionId: sessionId) {
                try? await client.send(msg)
                print("[Agent] Sent session.completed for \(sessionId.prefix(8))")
            }
        }
        // Stop permission socket
        if let socket = permissionSocket {
            await socket.stop()
        }
        // Close disk queue
        diskQueue?.close()
        // Brief delay to let WS messages flush
        try? await Task.sleep(for: .milliseconds(500))
        print("[Agent] Graceful shutdown complete")
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
