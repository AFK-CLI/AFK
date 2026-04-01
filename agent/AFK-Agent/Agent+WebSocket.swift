//
//  Agent+WebSocket.swift
//  AFK-Agent
//

import Foundation
import OSLog

extension Agent {

    /// Create WS client, fetch ticket, connect, and return whether connection succeeded.
    /// Disconnects any existing client first to prevent stale reconnect loops.
    func setupWebSocket(token: String, deviceId: String, keychain: KeychainStore) async -> Bool {
        // Disconnect existing client to stop its reconnect loop
        if let existingClient = wsClient {
            await existingClient.disconnect()
            self.wsClient = nil
        }
        let baseURL = config.serverURL
        let wsURLString: String
        if baseURL.hasPrefix("ws") {
            wsURLString = "\(baseURL)/v1/ws/agent"
        } else {
            wsURLString = "ws://\(baseURL)/v1/ws/agent"
        }

        guard let wsURL = URL(string: wsURLString) else { return false }

        let client = WebSocketClient(url: wsURL, token: token, deviceId: deviceId, diskQueue: diskQueue!)
        self.wsClient = client
        await client.startNetworkMonitor()

        let httpBaseURL = config.httpBaseURL

        await client.setTicketProvider { [weak self, deviceId] in
            guard let self else { return nil }

            // Read current token from keychain (may have been refreshed)
            guard let currentToken = try? keychain.loadToken(forKey: "auth-token") else {
                AppLogger.auth.warning("No auth token in keychain for ticket fetch")
                return nil
            }

            let api = APIClient(baseURL: httpBaseURL, token: currentToken)
            do {
                let ticket = try await api.getWSTicket(deviceId: deviceId)
                AppLogger.ws.info("Obtained WS ticket")
                return ticket
            } catch {
                let code = (error as NSError).code
                if code == 401 {
                    AppLogger.auth.warning("WS ticket auth expired, refreshing token...")
                    if let newToken = await self.tryRefreshToken(keychain: keychain) {
                        await self.wsClient?.updateToken(newToken)
                        let freshApi = APIClient(baseURL: httpBaseURL, token: newToken)
                        if let ticket = try? await freshApi.getWSTicket(deviceId: deviceId) {
                            AppLogger.ws.info("Obtained WS ticket after token refresh")
                            return ticket
                        }
                    }

                    // Both tokens expired — trigger re-authentication
                    return await self.reauthAndFetchTicket(
                        deviceId: deviceId,
                        keychain: keychain,
                        httpBaseURL: httpBaseURL
                    )
                }
                AppLogger.ws.error("WS ticket fetch failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        let api = APIClient(baseURL: httpBaseURL, token: token)

        await client.onMessage { [weak self] msg in
            guard let self else { return }
            await self.handleWSMessage(msg)
        }

        // Fetch initial ticket, then connect
        var initialTicket: String?
        do {
            initialTicket = try await api.getWSTicket(deviceId: deviceId)
            AppLogger.ws.info("Obtained initial WS ticket")
        } catch {
            AppLogger.ws.error("Initial WS ticket fetch failed: \(error.localizedDescription, privacy: .public)")
        }

        AppLogger.ws.info("Connecting to \(wsURLString, privacy: .public)...")
        Task { await client.connect(ticket: initialTicket) }
        return await client.waitForConnection()
    }

    /// Re-authenticate when both access and refresh tokens have expired.
    /// Shows the sign-in window, saves new credentials, and returns a fresh WS ticket.
    /// Disconnects the WebSocket client if the user dismisses the sign-in window.
    private func reauthAndFetchTicket(deviceId: String, keychain: KeychainStore, httpBaseURL: String) async -> String? {
        // Clear stale tokens
        try? keychain.deleteToken(forKey: "auth-token")
        try? keychain.deleteToken(forKey: "refresh-token")

        AppLogger.auth.warning("Both tokens expired — showing sign-in window...")
        guard let result = await showSignInWindow(existingDeviceId: deviceId) else {
            AppLogger.auth.warning("Re-auth dismissed — disconnecting")
            await wsClient?.disconnect()
            return nil
        }

        // Update the WS client's fallback token
        await wsClient?.updateToken(result.token)
        self.enrolledDeviceId = result.deviceId

        // Refresh log collector with new token
        let logApiClient = APIClient(baseURL: httpBaseURL, token: result.token)
        await logCollector.configure(apiClient: logApiClient, deviceId: result.deviceId)

        // Fetch a ticket with the new token
        let freshApi = APIClient(baseURL: httpBaseURL, token: result.token)
        if let ticket = try? await freshApi.getWSTicket(deviceId: result.deviceId) {
            AppLogger.ws.info("Obtained WS ticket after re-authentication")
            return ticket
        }

        return nil
    }

    private func handleSkillsSync(_ msg: WSMessage) async {
        struct SkillsSyncPayload: Codable {
            let sharedCommands: [SharedSkillInstaller.SharedCommand]
        }
        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(SkillsSyncPayload.self, from: msg.payloadJSON) else {
            AppLogger.agent.error("Failed to parse skills sync payload")
            return
        }
        guard let installer = sharedSkillInstaller else { return }
        await installer.installSharedCommands(payload.sharedCommands)
        AppLogger.agent.info("Installed \(payload.sharedCommands.count, privacy: .public) shared commands from peers")
    }

    private func handleInstallSkill(_ msg: WSMessage) async {
        struct EncryptedInstallPayload: Codable {
            let id: String?
            let senderDeviceId: String
            let encryptedPayload: String
        }
        struct DecryptedSkill: Codable {
            let name: String
            let content: String
            let sourceDeviceName: String?
        }

        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(EncryptedInstallPayload.self, from: msg.payloadJSON) else {
            AppLogger.agent.error("Failed to parse install skill envelope")
            return
        }
        guard let installer = sharedSkillInstaller else { return }
        guard let deviceId = enrolledDeviceId else { return }

        // Decrypt using E2EE key cache (uses own deviceId as HKDF salt, tries all peer keys)
        var decryptedJSON: String?
        if let cache = sessionKeyCache {
            decryptedJSON = cache.decryptString(envelope.encryptedPayload, sessionId: deviceId)
        }

        guard let json = decryptedJSON,
              let data = json.data(using: .utf8),
              let skill = try? decoder.decode(DecryptedSkill.self, from: data) else {
            AppLogger.agent.error("Failed to decrypt install skill payload from \(envelope.senderDeviceId, privacy: .public)")
            return
        }

        await installer.installSingleCommand(
            name: skill.name,
            content: skill.content,
            sourceDeviceName: skill.sourceDeviceName ?? "Unknown"
        )
        AppLogger.agent.info("Installed skill from iOS: /\(skill.name, privacy: .public)")
    }

    func handleWSMessage(_ msg: WSMessage) async {
        switch msg.type {
        case "permission.response":
            guard let socket = permissionSocket else { return }
            let decoder = JSONDecoder()
            guard let response = try? decoder.decode(
                PermissionSocket.PermissionResponsePayload.self,
                from: msg.payloadJSON
            ) else {
                AppLogger.permission.error("Failed to parse permission response")
                return
            }
            await socket.handleResponse(response)

            // Also resolve HTTP hook server pending permissions
            if let hookServer = hookServer {
                let hookResponse = HookPermissionResponse(
                    behavior: response.action == "allow" ? "allow" : "deny",
                    updatedInput: nil
                )
                await hookServer.resolvePermission(nonce: response.nonce, response: hookResponse)
            }

            // Also route to non-CC providers (OpenCode uses HTTP API, not hook socket)
            if let entry = pendingProviderPermissions.removeValue(forKey: response.nonce),
               let registry = providerRegistry,
               let provider = await registry.provider(for: entry.provider) {
                // Pass the raw action — could be "allow", "deny", or "answer:<label>" for questions
                await provider.handlePermissionResponse(nonce: response.nonce, action: response.action, message: nil)
            }
        case "permission_mode":
            struct ModePayload: Codable { let mode: String }
            let decoder = JSONDecoder()
            guard let socket = permissionSocket,
                  let payload = try? decoder.decode(ModePayload.self, from: msg.payloadJSON),
                  let mode = PermissionSocket.PermissionMode(rawValue: payload.mode) else {
                AppLogger.permission.error("Failed to parse permission mode")
                return
            }
            await socket.setMode(mode)
            AppLogger.permission.info("Permission mode changed to: \(payload.mode, privacy: .public)")
        case "server.privacy_mode":
            struct PrivacyModePayload: Codable { let mode: String }
            let decoder = JSONDecoder()
            if let payload = try? decoder.decode(PrivacyModePayload.self, from: msg.payloadJSON) {
                config.defaultPrivacyMode = payload.mode
                AppLogger.agent.info("Privacy mode updated to: \(payload.mode, privacy: .public)")
            } else {
                AppLogger.agent.error("Failed to parse privacy mode update")
            }
        case "server.command.continue":
            await handleCommandContinue(msg)
        case "server.command.new":
            await handleCommandNew(msg)
        case "server.command.cancel":
            await handleCommandCancel(msg)
        case "server.session.stop":
            await handleSessionStop(msg)
        case "server.plan.restart":
            await handlePlanRestart(msg)
        case "device.key_rotated":
            await handleDeviceKeyRotated(msg)
        case "server.skills.sync":
            await handleSkillsSync(msg)
        case "server.install.skill":
            await handleInstallSkill(msg)
        case "server.todo.append":
            await handleTodoAppend(msg)
        case "server.todo.toggle":
            await handleTodoToggle(msg)
        case "server.wwud.override":
            struct WWUDOverridePayload: Codable {
                let decisionId: String
                let correctedAction: String
            }
            let decoder = JSONDecoder()
            guard let payload = try? decoder.decode(WWUDOverridePayload.self, from: msg.payloadJSON),
                  let socket = permissionSocket else {
                AppLogger.wwud.error("Failed to parse WWUD override")
                return
            }
            // Validate correctedAction — only "allow" or "deny" are valid
            guard payload.correctedAction == "allow" || payload.correctedAction == "deny" else {
                AppLogger.wwud.warning("Invalid WWUD override action: \(payload.correctedAction, privacy: .public)")
                return
            }
            await socket.handleWWUDOverride(decisionId: payload.decisionId, correctedAction: payload.correctedAction)
            AppLogger.wwud.info("WWUD override: \(payload.decisionId.prefix(8), privacy: .public) → \(payload.correctedAction, privacy: .public)")
        case "agent_control":
            struct ControlPayload: Codable {
                let remoteApproval: Bool?
                let autoPlanExit: Bool?
            }
            let decoder = JSONDecoder()
            guard let payload = try? decoder.decode(ControlPayload.self, from: msg.payloadJSON) else {
                AppLogger.agent.error("Failed to parse agent control")
                return
            }
            if let sbc = statusBarController {
                DispatchQueue.main.async {
                    if let ra = payload.remoteApproval { sbc.setRemoteApproval(ra) }
                }
            }
            // Small delay to let main-thread UI updates complete before reading state
            try? await Task.sleep(for: .milliseconds(50))
            await broadcastControlState()
        default:
            break
        }
    }
}
