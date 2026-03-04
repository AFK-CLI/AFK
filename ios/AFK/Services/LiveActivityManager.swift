import ActivityKit
import Foundation
import OSLog

@Observable
final class LiveActivityManager {
    private var activities: [String: String] = [:] // sessionId -> Activity.id
    private var startTimes: [String: Date] = [:]
    private var updateThrottles: [String: Date] = [:]

    /// End all active Live Activities (cleanup on launch or for testing).
    func endAllActivities() {
        Task {
            for activity in Activity<SessionActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        activities.removeAll()
        startTimes.removeAll()
        updateThrottles.removeAll()
        lastStatus.removeAll()
        AppLogger.liveActivity.info("Ended all activities")
    }

    func startActivity(sessionId: String, projectName: String, deviceName: String, apiClient: APIClient? = nil) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // Check if a push-started activity already exists for this session.
        if activities[sessionId] == nil {
            for activity in Activity<SessionActivityAttributes>.activities {
                if activity.attributes.sessionId == sessionId {
                    AppLogger.liveActivity.info("Found existing push-started activity for session \(sessionId.prefix(8), privacy: .public)")
                    activities[sessionId] = activity.id
                    startTimes[sessionId] = Date()
                    return
                }
            }
        }

        // Skip if already tracking this session.
        if activities[sessionId] != nil { return }

        let attributes = SessionActivityAttributes(
            sessionId: sessionId,
            projectName: projectName,
            deviceName: deviceName
        )
        let state = SessionActivityAttributes.ContentState(
            status: "running",
            currentTool: nil,
            turnCount: 0,
            elapsedSeconds: 0
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: .token
            )
            activities[sessionId] = activity.id
            startTimes[sessionId] = Date()

            // Observe push token updates and register with backend.
            if let apiClient {
                Task {
                    for await tokenData in activity.pushTokenUpdates {
                        let tokenString = tokenData.map { String(format: "%02x", $0) }.joined()
                        AppLogger.liveActivity.info("Push token for session \(sessionId.prefix(8), privacy: .public): \(tokenString.prefix(16), privacy: .public)...")
                        try? await apiClient.registerLiveActivityToken(
                            sessionId: sessionId,
                            pushToken: tokenString
                        )
                    }
                }
            }
        } catch {
            AppLogger.liveActivity.error("Failed to start live activity: \(error, privacy: .public)")
        }
    }

    // MARK: - Push-to-Start (iOS 17.2+)

    /// Observes the push-to-start token for SessionActivityAttributes and sends it to the backend.
    func observePushToStartToken(apiClient: APIClient) {
        if #available(iOS 17.2, *) {
            Task {
                for await tokenData in Activity<SessionActivityAttributes>.pushToStartTokenUpdates {
                    let tokenString = tokenData.map { String(format: "%02x", $0) }.joined()
                    AppLogger.liveActivity.info("Push-to-start token: \(tokenString.prefix(16), privacy: .public)...")
                    try? await apiClient.registerPushToStartToken(tokenString)
                }
            }
        }
    }

    /// Observes new activities (including push-started ones) and tracks them.
    func observeActivityUpdates(apiClient: APIClient) {
        if #available(iOS 17.2, *) {
            Task {
                for await activity in Activity<SessionActivityAttributes>.activityUpdates {
                    let sessionId = activity.attributes.sessionId
                    // Only track if we don't already know about this activity.
                    if activities[sessionId] == nil {
                        AppLogger.liveActivity.info("Detected push-started activity for session \(sessionId.prefix(8), privacy: .public)")
                        activities[sessionId] = activity.id
                        startTimes[sessionId] = Date()

                        // Observe per-activity push token and register with backend.
                        Task {
                            for await tokenData in activity.pushTokenUpdates {
                                let tokenString = tokenData.map { String(format: "%02x", $0) }.joined()
                                AppLogger.liveActivity.info("Per-activity token for push-started session \(sessionId.prefix(8), privacy: .public): \(tokenString.prefix(16), privacy: .public)...")
                                try? await apiClient.registerLiveActivityToken(
                                    sessionId: sessionId,
                                    pushToken: tokenString
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private var lastStatus: [String: String] = [:]

    func updateActivity(sessionId: String, status: String, currentTool: String? = nil, turnCount: Int = 0, agentCount: Int? = nil) {
        let now = Date()
        let statusChanged = lastStatus[sessionId] != status

        // Throttle updates to 1/second, but always allow status changes through
        if !statusChanged,
           let lastUpdate = updateThrottles[sessionId],
           now.timeIntervalSince(lastUpdate) < 1.0 {
            return
        }
        updateThrottles[sessionId] = now
        lastStatus[sessionId] = status

        guard let activityId = activities[sessionId] else { return }

        let elapsed = Int(now.timeIntervalSince(startTimes[sessionId] ?? now))
        let state = SessionActivityAttributes.ContentState(
            status: status,
            currentTool: currentTool,
            turnCount: turnCount,
            elapsedSeconds: elapsed,
            agentCount: agentCount
        )

        Task {
            for activity in Activity<SessionActivityAttributes>.activities where activity.id == activityId {
                await activity.update(.init(state: state, staleDate: Date().addingTimeInterval(180)))
            }
        }
    }

    /// End live activities for sessions that are no longer actively running.
    /// Call this on foreground transitions and WS reconnect to catch any orphaned activities.
    func cleanupStaleActivities(activeSessionIds: Set<String>) {
        var cleaned = 0
        for activity in Activity<SessionActivityAttributes>.activities {
            let sessionId = activity.attributes.sessionId
            if !activeSessionIds.contains(sessionId) {
                let elapsed = Int(Date().timeIntervalSince(startTimes[sessionId] ?? Date()))
                let finalState = SessionActivityAttributes.ContentState(
                    status: "completed",
                    currentTool: nil,
                    turnCount: 0,
                    elapsedSeconds: elapsed
                )
                Task {
                    await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
                }
                activities.removeValue(forKey: sessionId)
                startTimes.removeValue(forKey: sessionId)
                updateThrottles.removeValue(forKey: sessionId)
                lastStatus.removeValue(forKey: sessionId)
                cleaned += 1
            }
        }
        if cleaned > 0 {
            AppLogger.liveActivity.info("Cleaned up \(cleaned, privacy: .public) stale live activities")
        }
    }

    func endActivity(sessionId: String, finalStatus: String) {
        guard let activityId = activities[sessionId] else { return }

        let elapsed = Int(Date().timeIntervalSince(startTimes[sessionId] ?? Date()))
        let finalState = SessionActivityAttributes.ContentState(
            status: finalStatus,
            currentTool: nil,
            turnCount: 0,
            elapsedSeconds: elapsed
        )

        Task {
            for activity in Activity<SessionActivityAttributes>.activities where activity.id == activityId {
                await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .after(.now + 300))
            }
        }

        activities.removeValue(forKey: sessionId)
        startTimes.removeValue(forKey: sessionId)
        updateThrottles.removeValue(forKey: sessionId)
        lastStatus.removeValue(forKey: sessionId)
    }
}
