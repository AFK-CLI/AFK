//
//  Agent+WebSocket.swift
//  AFK-Agent
//

import Foundation

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
                print("[Agent] No auth token in keychain for ticket fetch")
                return nil
            }

            let api = APIClient(baseURL: httpBaseURL, token: currentToken)
            do {
                let ticket = try await api.getWSTicket(deviceId: deviceId)
                print("[Agent] Obtained WS ticket")
                return ticket
            } catch {
                let code = (error as NSError).code
                if code == 401 {
                    print("[Agent] WS ticket auth expired, refreshing token...")
                    if let newToken = await self.tryRefreshToken(keychain: keychain) {
                        await self.wsClient?.updateToken(newToken)
                        let freshApi = APIClient(baseURL: httpBaseURL, token: newToken)
                        if let ticket = try? await freshApi.getWSTicket(deviceId: deviceId) {
                            print("[Agent] Obtained WS ticket after token refresh")
                            return ticket
                        }
                    }
                }
                print("[Agent] WS ticket fetch failed: \(error.localizedDescription)")
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
            print("[Agent] Obtained initial WS ticket")
        } catch {
            print("[Agent] Initial WS ticket fetch failed: \(error.localizedDescription)")
        }

        print("[Agent] Connecting to \(wsURLString)...")
        Task { await client.connect(ticket: initialTicket) }
        return await client.waitForConnection()
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
                print("[Agent] Failed to parse permission response")
                return
            }
            await socket.handleResponse(response)
        case "permission_mode":
            struct ModePayload: Codable { let mode: String }
            let decoder = JSONDecoder()
            guard let socket = permissionSocket,
                  let payload = try? decoder.decode(ModePayload.self, from: msg.payloadJSON),
                  let mode = PermissionSocket.PermissionMode(rawValue: payload.mode) else {
                print("[Agent] Failed to parse permission mode")
                return
            }
            await socket.setMode(mode)
            print("[Agent] Permission mode changed to: \(payload.mode)")
        case "server.privacy_mode":
            struct PrivacyModePayload: Codable { let mode: String }
            let decoder = JSONDecoder()
            if let payload = try? decoder.decode(PrivacyModePayload.self, from: msg.payloadJSON) {
                config.defaultPrivacyMode = payload.mode
                print("[Agent] Privacy mode updated to: \(payload.mode)")
            } else {
                print("[Agent] Failed to parse privacy mode update")
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
                print("[Agent] Failed to parse agent control")
                return
            }
            if let sbc = statusBarController {
                DispatchQueue.main.async {
                    if let ra = payload.remoteApproval { sbc.setRemoteApproval(ra) }
                    if let ape = payload.autoPlanExit { sbc.setAutoPlanExit(ape) }
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
