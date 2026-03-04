//
//  Agent+SleepWake.swift
//  AFK-Agent
//
//  Handles macOS sleep/wake notifications to ensure the WebSocket connection
//  recovers quickly after the system wakes from sleep.
//

import Foundation
import AppKit
import OSLog

extension Agent {

    /// Register observers for system sleep and wake notifications.
    /// Call this during agent initialization (inside `run()`).
    func registerSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.handleSleep()
            }
        }

        center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.handleWake()
            }
        }

        AppLogger.agent.debug("Registered sleep/wake observers")
    }

    /// Called when the system is about to go to sleep.
    /// Logs the event and saves state so no data is lost.
    private func handleSleep() {
        AppLogger.agent.info("System going to sleep")
        agentState.save()
    }

    /// Called when the system wakes from sleep.
    /// Resets reconnect backoff and triggers an immediate reconnect if disconnected.
    private func handleWake() {
        AppLogger.agent.info("System waking up")

        guard let client = wsClient else { return }

        Task {
            // Reset reconnect backoff to minimum for fast recovery
            await client.resetReconnectBackoff()

            let connected = await client.getIsConnected()
            if !connected {
                AppLogger.agent.info("WebSocket disconnected after wake, triggering reconnect")
                await client.triggerReconnect()
            }
        }
    }
}
