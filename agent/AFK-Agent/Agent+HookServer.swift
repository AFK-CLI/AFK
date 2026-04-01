//
//  Agent+HookServer.swift
//  AFK-Agent
//
//  Wires HookHTTPServer into the Agent, converting hook events into
//  ProviderSessionBatch and permission round-trips.
//

import Foundation
import OSLog

extension Agent {

    func setupHookServer(deviceId: String) async {
        guard config.hookServerEnabled else { return }

        let server = HookHTTPServer(port: UInt16(config.hookServerPort))
        self.hookServer = server

        // Fire-and-forget session lifecycle events
        await server.setOnSessionEvent { [weak self] event in
            guard let self else { return }

            let sessionId = event.sessionId ?? ""
            guard !sessionId.isEmpty else {
                AppLogger.hook.warning("Hook event \(event.type) missing session_id, ignoring")
                return
            }

            let projectPath = event.payload["cwd"] as? String ?? ""

            // Map hook type to NormalizedEventType
            let eventType: NormalizedEventType
            switch event.type {
            case "session_start":
                eventType = .sessionStarted
            case "session_end":
                eventType = .sessionCompleted
            case "stop":
                eventType = .sessionCompleted
            case "notification":
                eventType = .sessionIdle  // notifications map to idle state
            case "user_prompt_submit":
                eventType = .turnStarted
            case "subagent_start":
                eventType = .subagentStarted
            case "subagent_stop":
                eventType = .subagentStopped
            default:
                AppLogger.hook.debug("Unknown hook event type: \(event.type)")
                return
            }

            // Extract subagent metadata if present
            var eventData: [String: String] = ["source": "hook_http"]
            if let agentId = event.payload["agent_id"] as? String {
                eventData["agentId"] = agentId
            }
            if let agentType = event.payload["agent_type"] as? String {
                eventData["agentType"] = agentType
            }
            if let agentName = event.payload["agent_name"] as? String {
                eventData["agentName"] = agentName
            }

            let normalized = NormalizedEvent(
                sessionId: sessionId,
                eventType: eventType,
                data: eventData
            )
            let providerEvent = ProviderEvent(
                event: normalized,
                cwd: projectPath,
                gitBranch: "",
                privacyMode: await self.config.defaultPrivacyMode
            )
            let batch = ProviderSessionBatch(
                sessionId: sessionId,
                projectPath: projectPath,
                provider: "claude_code",
                dataPath: "",
                events: [providerEvent],
                rawUserPrompt: nil
            )
            await self.handleProviderBatch(batch)
        }

        // Pre-tool-use / permission-request: NO-OP passthrough.
        // Permission handling stays on the Unix socket (E2EE, HMAC, WWUD).
        // HTTP hooks for PreToolUse/PermissionRequest are NOT registered in
        // settings.json, but if somehow called, just approve silently.
        await server.setOnPermissionRequest { _ in
            return HookPermissionResponse(behavior: "allow", updatedInput: nil)
        }

        // Post-tool-use: convert to normalized event and send
        await server.setOnToolResult { [weak self] result in
            guard let self else { return }

            let normalized = NormalizedEvent(
                sessionId: result.sessionId,
                eventType: .toolResult,
                data: [
                    "toolName": result.toolName,
                    "toolUseId": result.toolUseId,
                    "source": "hook_http"
                ],
                content: [
                    "toolResponse": String(result.toolResponse.prefix(4096)),
                    "toolInputSummary": result.toolInput.map { "\($0.key): \($0.value.prefix(200))" }.joined(separator: "\n")
                ]
            )
            let providerEvent = ProviderEvent(
                event: normalized,
                cwd: result.cwd,
                gitBranch: "",
                privacyMode: await self.config.defaultPrivacyMode
            )
            let batch = ProviderSessionBatch(
                sessionId: result.sessionId,
                projectPath: result.cwd,
                provider: "claude_code",
                dataPath: "",
                events: [providerEvent],
                rawUserPrompt: nil
            )
            await self.handleProviderBatch(batch)
        }

        do {
            try await server.start()
            AppLogger.hook.info("Hook HTTP server started on port \(self.config.hookServerPort)")
        } catch {
            AppLogger.hook.error("Failed to start hook server: \(error.localizedDescription)")
        }
    }
}
