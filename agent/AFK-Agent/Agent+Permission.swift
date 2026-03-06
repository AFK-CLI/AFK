//
//  Agent+Permission.swift
//  AFK-Agent
//

import Foundation
import OSLog

extension Agent {

    // MARK: - Remote Permission Approval

    func setupPermissionSocket(deviceId: String, client: WebSocketClient) async {
        let socket = PermissionSocket(
            timeout: config.remoteApprovalTimeout,
            deviceId: deviceId,
            acceptLegacyFallback: config.acceptLegacyPermissionFallback
        )
        self.permissionSocket = socket

        // When hook script sends a permission request, forward it via WS
        await socket.setOnPermissionRequest { [weak self] event in
            guard let self else { return }
            await self.forwardPermissionRequest(event)
        }

        // When async notification hook fires, forward to iOS via WS
        await socket.setOnNotification { [weak self] event in
            guard let self else { return }

            // Local idle notification (icon + optional macOS notification)
            if await self.config.notifyOnIdle {
                // Set menu bar icon to orange attention state
                Task { @MainActor [weak self] in
                    self?.statusBarController?.setAttention(true)
                }

                // Show macOS notification if remote approval is off (user is at their Mac)
                if StatusBarController.isHookBypassed {
                    let title = event.notificationType == "idle_prompt"
                        ? "Claude is waiting for input"
                        : "Action required"
                    let message = event.message ?? event.sessionId
                    await self.showNotification(title: "AFK: \(title)", message: message)
                }
            }

            // Forward to iOS via WS
            guard let client = await self.wsClient else { return }
            do {
                let msg = try MessageEncoder.notification(
                    sessionId: event.sessionId,
                    notificationType: event.notificationType,
                    message: event.message
                )
                try await client.send(msg)
                AppLogger.permission.info("Forwarded notification: \(event.notificationType, privacy: .public)")
            } catch {
                AppLogger.permission.error("Failed to forward notification: \(error.localizedDescription, privacy: .public)")
            }
        }

        // When async stop hook fires, forward to iOS via WS
        await socket.setOnStop { [weak self] event in
            guard let self, let client = await self.wsClient else { return }
            do {
                let msg = try MessageEncoder.sessionStopped(
                    sessionId: event.sessionId,
                    lastAssistantMessage: event.lastAssistantMessage
                )
                try await client.send(msg)
                AppLogger.permission.info("Forwarded session stopped: \(event.sessionId.prefix(8), privacy: .public)")
            } catch {
                AppLogger.permission.error("Failed to forward session stopped: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Configure settings.json rule checking
        await socket.setSettingsRulesEnabled(config.obeySettingsRules)
        await socket.setProjectPathResolver { [weak self] sessionId in
            guard let self else { return nil }
            return await self.sessionIndex.projectPath(for: sessionId)
        }

        // Derive permission signing keys from E2EE key agreement with iOS peers.
        await setupPermissionSigningKeys(socket: socket, deviceId: deviceId)

        do {
            // Install hook first (idempotent, handles missing socket gracefully with retry)
            let installer = HookInstaller(
                hookInstallDir: config.hookInstallPath,
                timeoutSeconds: config.remoteApprovalTimeout
            )
            try installer.install()

            // Start socket (creates /tmp/afk-agent.sock)
            try await socket.start()
        } catch {
            AppLogger.permission.error("Failed to start permission socket: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setupPermissionSigningKeys(socket: PermissionSocket, deviceId: String) async {
        let keychain = KeychainStore()
        guard let kaIdentity = try? KeyAgreementIdentity.load(from: keychain) else {
            AppLogger.permission.warning("No KA identity — permission HMAC verification disabled")
            return
        }
        let token = config.authToken ?? (try? keychain.loadToken(forKey: "auth-token"))
        guard let token else { return }

        let api = APIClient(baseURL: config.httpBaseURL, token: token)
        let e2ee = E2EEncryption(identity: kaIdentity)

        do {
            let devices = try await api.listDevices()
            for device in devices where device.id != deviceId {
                // Skip devices without KA keys (not yet enrolled for E2EE)
                guard let peerKey = device.keyAgreementPublicKey, !peerKey.isEmpty else { continue }
                do {
                    let key = try e2ee.derivePermissionKey(
                        peerPublicKeyBase64: peerKey,
                        deviceId: deviceId
                    )
                    await socket.addPermissionSigningKey(key, for: device.id)
                } catch {
                    AppLogger.permission.error("Failed to derive permission key for peer \(device.id.prefix(8), privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            AppLogger.permission.error("Failed to list devices for permission keys: \(error.localizedDescription, privacy: .public)")
        }
    }

    func forwardPermissionRequest(_ event: PermissionSocket.PermissionRequestEvent) async {
        guard let client = wsClient else { return }
        do {
            let msg = try MessageEncoder.permissionRequest(event: event)
            try await client.send(msg)
            AppLogger.permission.info("Forwarded permission request for \(event.toolName, privacy: .public) (nonce: \(event.nonce.prefix(8), privacy: .public))")
        } catch {
            AppLogger.permission.error("Failed to forward permission request: \(error.localizedDescription, privacy: .public)")
        }
    }
}
