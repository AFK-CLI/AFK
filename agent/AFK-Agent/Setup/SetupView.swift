//
//  SetupView.swift
//  AFK-Agent
//

import SwiftUI

struct SetupView: View {
    @State private var serverURL = "https://"
    @State private var deviceName = Host.current().localizedName ?? "Mac"
    @State private var statusMessage = ""
    @State private var isValidating = false
    var onSave: (AgentConfig) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("AFK Agent Setup")
                .font(.title)
                .fontWeight(.bold)

            Text("Connect this Mac to your AFK server to enable remote session monitoring and control.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider()

            Form {
                TextField("Server URL", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                    .help("Your AFK backend URL (e.g. https://afk.example.com)")

                TextField("Device Name", text: $deviceName)
                    .textFieldStyle(.roundedBorder)
                    .help("Display name for this Mac in the iOS app")
            }

            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .foregroundStyle(statusMessage.contains("Error") ? .red : .green)
                    .font(.caption)
            }

            HStack {
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save & Start") {
                    validateAndSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isValidating)
            }
        }
        .padding(30)
        .frame(width: 450)
    }

    private func validateAndSave() {
        guard let parsed = URL(string: serverURL), parsed.host != nil else {
            statusMessage = "Error: Invalid URL format"
            return
        }

        // Derive the WS URL from the HTTP URL
        let wsURL = serverURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")

        isValidating = true
        statusMessage = "Connecting..."

        // Validate by hitting healthz
        let healthURL = serverURL
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")

        guard let healthEndpoint = URL(string: "\(healthURL)/healthz") else {
            statusMessage = "Error: Cannot form health check URL"
            isValidating = false
            return
        }

        let task = URLSession.shared.dataTask(with: healthEndpoint) { _, response, error in
            DispatchQueue.main.async {
                isValidating = false
                if let error {
                    statusMessage = "Error: \(error.localizedDescription)"
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    saveConfig(wsURL: wsURL)
                } else {
                    statusMessage = "Error: Server returned unexpected status"
                }
            }
        }
        task.resume()
    }

    private func saveConfig(wsURL: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let config = AgentConfig(
            serverURL: wsURL,
            deviceID: nil,
            authToken: nil,
            claudeProjectsPath: "\(home)/.claude/projects",
            heartbeatInterval: 30,
            idleTimeout: 120,
            completedTimeout: 300,
            permissionStallTimeout: 10,
            remoteApprovalEnabled: true,
            remoteApprovalTimeout: 120,
            hookInstallPath: "\(home)/.claude/hooks",
            defaultPrivacyMode: "encrypted",
            projectPrivacyOverrides: [:],
            acceptLegacyPermissionFallback: true,
            deviceName: deviceName,
            logLevel: "info",
            hooksEnabled: true,
            planAutoExit: false,
            obeySettingsRules: false,
            preventSleep: false,
            ctrlClickTogglesRemoteAndSleep: false,
            notifyOnIdle: true,
            usagePollingEnabled: true,
            updateCheckInterval: 3600,
            enabledProviders: ["claude_code"],
            openCodePollInterval: 2,
            openCodeServerPort: 0
        )
        config.save()
        onSave(config)
    }
}
