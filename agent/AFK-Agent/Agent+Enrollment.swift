//
//  Agent+Enrollment.swift
//  AFK-Agent
//

import Foundation
import OSLog

extension Agent {

    struct EnrollResult {
        let token: String
        let deviceId: String
    }

    /// Show the sign-in window and enroll the device after successful authentication.
    func showSignInWindow(existingDeviceId: String? = nil) async -> EnrollResult? {
        // Prevent duplicate sign-in windows
        if signInController != nil { return nil }

        let serverURL = config.serverURL
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let controller = SignInWindowController()
                controller.showSignInWindow(
                    serverURL: serverURL,
                    onCancel: {
                        Task { await self.setSignInController(nil) }
                        continuation.resume(returning: nil)
                    },
                    completion: { token, refreshToken, userId, email in
                        Task {
                            let result = await self.emailEnroll(
                                token: token,
                                refreshToken: refreshToken,
                                email: email,
                                existingDeviceId: existingDeviceId
                            )
                            continuation.resume(returning: result)
                        }
                    }
                )
                // Store the controller reference to keep it alive
                Task {
                    await self.setSignInController(controller)
                }
            }
        }
    }

    /// Store the sign-in controller reference (actor-isolated helper).
    func setSignInController(_ controller: SignInWindowController?) {
        self.signInController = controller
    }

    /// Manually trigger sign-in from the menu bar.
    func signIn() async {
        if let result = await showSignInWindow() {
            let keychain = KeychainStore()
            let connected = await setupWebSocket(token: result.token, deviceId: result.deviceId, keychain: keychain)
            self.enrolledDeviceId = result.deviceId
            if connected {
                AppLogger.agent.info("Connected after manual sign-in")
            }
        }
    }

    /// Sign out: clear credentials, disconnect, update UI.
    func signOut() async {
        let keychain = KeychainStore()
        try? keychain.deleteToken(forKey: "auth-token")
        try? keychain.deleteToken(forKey: "refresh-token")
        try? keychain.deleteToken(forKey: "device-id")
        try? keychain.deleteToken(forKey: "user-email")
        if let existingClient = wsClient {
            await existingClient.disconnect()
            self.wsClient = nil
        }
        self.enrolledDeviceId = nil
        self.sessionKeyCache = nil
        diskQueue?.purge()
        onAccountChanged?(nil)
        AppLogger.agent.info("Signed out — credentials cleared")
    }

    /// Enroll a device after email/password authentication (already have tokens).
    func emailEnroll(token: String, refreshToken: String, email: String, existingDeviceId: String? = nil) async -> EnrollResult? {
        let httpBase = config.httpBaseURL
        do {
            // 1. Load existing KA key pair, or generate if none exists
            let keychain = KeychainStore()
            let kaIdentity: KeyAgreementIdentity
            if let existing = try? KeyAgreementIdentity.load(from: keychain) {
                kaIdentity = existing
                AppLogger.agent.info("Reusing existing KeyAgreement key pair")
            } else {
                kaIdentity = KeyAgreementIdentity.generate()
                try kaIdentity.save(to: keychain)
                AppLogger.agent.info("KeyAgreement key pair generated")
            }

            // 2. Enroll this device
            let deviceName = config.deviceName
            let systemInfo = "\(ProcessInfo.processInfo.operatingSystemVersionString)"
            let api = APIClient(baseURL: httpBase, token: token)
            let device = try await api.enrollDevice(
                name: deviceName,
                publicKey: "email-\(deviceName)",
                systemInfo: systemInfo,
                keyAgreementPublicKey: kaIdentity.publicKeyBase64,
                deviceId: existingDeviceId
            )
            AppLogger.agent.info("Device enrolled: \(device.name, privacy: .public) (id: \(device.id.prefix(8), privacy: .public))")

            // Track registered KA fingerprint
            let enrolledFingerprint = Self.keyFingerprint(kaIdentity.publicKeyBase64)
            try? keychain.saveToken(enrolledFingerprint, forKey: "last-registered-ka-fingerprint")

            // 3. If re-enrolled with existing device, re-register KA key if changed
            if existingDeviceId != nil {
                let currentFingerprint = Self.keyFingerprint(kaIdentity.publicKeyBase64)
                let lastRegistered = try? keychain.loadToken(forKey: "last-registered-ka-fingerprint")
                if lastRegistered != currentFingerprint {
                    try? await api.registerKeyAgreement(deviceId: device.id, publicKey: kaIdentity.publicKeyBase64)
                    try? keychain.saveToken(currentFingerprint, forKey: "last-registered-ka-fingerprint")
                    AppLogger.agent.info("Re-registered KA key for existing device")
                }
            }

            // 4. Persist tokens + device ID + email to keychain
            try keychain.saveToken(token, forKey: "auth-token")
            try keychain.saveToken(refreshToken, forKey: "refresh-token")
            try keychain.saveToken(device.id, forKey: "device-id")
            try keychain.saveToken(email, forKey: "user-email")
            AppLogger.agent.info("Credentials saved to keychain")

            onAccountChanged?(email)

            // Clear the sign-in controller reference
            self.signInController = nil

            return EnrollResult(token: token, deviceId: device.id)
        } catch {
            AppLogger.agent.error("Email enrollment failed: \(error.localizedDescription, privacy: .public)")
            self.signInController = nil
            return nil
        }
    }

    /// Attempt to refresh an expired access token using the stored refresh token.
    /// Returns a new access token on success, or nil if refresh fails.
    func tryRefreshToken(keychain: KeychainStore) async -> String? {
        guard let refreshToken = try? keychain.loadToken(forKey: "refresh-token") else {
            AppLogger.auth.warning("No refresh token in keychain")
            return nil
        }
        do {
            let resp = try await APIClient.refreshToken(baseURL: config.httpBaseURL, refreshToken: refreshToken)
            try keychain.saveToken(resp.accessToken, forKey: "auth-token")
            try keychain.saveToken(resp.refreshToken, forKey: "refresh-token")
            AppLogger.auth.info("Token refreshed successfully")
            return resp.accessToken
        } catch {
            AppLogger.auth.error("Token refresh failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
