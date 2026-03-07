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
        case "server.plan.restart":
            await handlePlanRestart(msg)
        case "device.key_rotated":
            await handleDeviceKeyRotated(msg)
        case "server.todo.append":
            await handleTodoAppend(msg)
        case "server.todo.toggle":
            await handleTodoToggle(msg)
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
