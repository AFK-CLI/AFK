//
//  Agent+Heartbeat.swift
//  AFK-Agent
//

import Foundation
import OSLog

extension Agent {

    func heartbeatLoop(deviceId: String) async {
        while true {
            try? await Task.sleep(for: .seconds(config.heartbeatInterval))
            guard let client = wsClient else { continue }
            let sessions = await stateManager.allSessions()
            let activeIds = sessions.filter { $0.value.status == .running || $0.value.status == .idle }.map(\.key)
            if let msg = try? MessageEncoder.heartbeat(deviceID: deviceId, activeSessions: activeIds) {
                try? await client.send(msg)
            }
        }
    }

    func timeoutLoop() async {
        while true {
            try? await Task.sleep(for: .seconds(10))

            // Check for sessions with pending restart intents that have gone idle/completed
            if let socket = permissionSocket, await socket.hasPendingRestarts() {
                for sid in await socket.pendingRestartSessionIds() {
                    let status = (await stateManager.getInfo(sid))?.status
                    if status == .idle || status == .completed {
                        if let intent = await socket.consumeRestartIntent(sessionId: sid) {
                            AppLogger.agent.info("Session \(sid.prefix(8), privacy: .public) stopped — executing plan restart")
                            await spawnPlanRestart(sessionId: sid, planContent: intent.planContent)
                        }
                    }
                }
                // Stale fallback: force-execute after 5 minutes
                for (sid, intent) in await socket.consumeStaleRestartIntents(olderThan: 300) {
                    AppLogger.agent.warning("Stale restart intent for \(sid.prefix(8), privacy: .public) — force-spawning")
                    await spawnPlanRestart(sessionId: sid, planContent: intent.planContent)
                }
            }

            let timeoutEvents = await stateManager.checkTimeouts(
                idleTimeout: config.idleTimeout,
                completedTimeout: config.completedTimeout
            )
            for event in timeoutEvents {
                _ = await stateManager.processEvent(event)
                if let client = wsClient {
                    if event.eventType == .sessionCompleted {
                        if let msg = try? MessageEncoder.sessionCompleted(sessionId: event.sessionId) {
                            try? await client.send(msg)
                        }
                        // Remove completed session from persistent state
                        cleanupCompletedSession(event.sessionId)
                    }
                }
                AppLogger.session.debug("\(event.sessionId.prefix(8), privacy: .public) \(event.eventType.rawValue, privacy: .public) (timeout)")
            }
        }
    }

    func permissionStallLoop() async {
        while true {
            try? await Task.sleep(for: .seconds(5))
            let allSessions = await stateManager.allSessions()
            let activeSessions = Set(allSessions.filter { $0.value.status == .running }.map(\.key))
            let stallEvents = normalizer.checkPermissionStalls(stallTimeout: config.permissionStallTimeout, activeSessions: activeSessions)
            for event in stallEvents {
                _ = await stateManager.processEvent(event)
                if let client = wsClient {
                    do {
                        let msg = try MessageEncoder.sessionEvent(sessionId: event.sessionId, event: event)
                        try await client.send(msg)
                    } catch {
                        AppLogger.ws.error("Failed to send permission stall: \(error.localizedDescription, privacy: .public)")
                    }
                }
                AppLogger.session.debug("\(event.sessionId.prefix(8), privacy: .public) \(event.eventType.rawValue, privacy: .public) (permission stall)")
            }
        }
    }

    // MARK: - Plan Restart

    func spawnPlanRestart(sessionId: String, planContent: String) async {
        let projectPath = await sessionIndex.projectPath(for: sessionId) ?? ""
        guard !projectPath.isEmpty else {
            AppLogger.agent.error("Cannot restart \(sessionId.prefix(8), privacy: .public) — no project path")
            return
        }
        let planPath = BuildEnvironment.configDirectoryPath + "/plans/\(sessionId).md"
        let prompt = "Read and implement the plan at \(planPath). Begin immediately."
        do {
            let claudePath = try CommandValidator.resolveClaudePath()
            let args = ["-p", prompt, "--output-format", "json"]
            try CommandValidator.validate(args: [claudePath] + args)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: claudePath)
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if FileManager.default.fileExists(atPath: projectPath) {
                process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
            }
            try process.run()
            AppLogger.agent.info("Spawned plan restart for \(sessionId.prefix(8), privacy: .public) in \(projectPath, privacy: .public)")
        } catch {
            AppLogger.agent.error("Failed to spawn plan restart: \(error.localizedDescription, privacy: .public)")
        }
    }
}
