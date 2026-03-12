import SwiftUI
import CryptoKit
import os

struct DeviceDetailView: View {
    let device: Device
    let apiClient: APIClient
    var e2eeService: E2EEService?

    @State private var inventory: DeviceInventory?
    @State private var sharedSkills: [SharedSkill] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var tier: String = "free"
    @State private var displayName: String = ""
    @State private var showRenameAlert = false
    @State private var renameText = ""

    var body: some View {
        List {
            // Device header section
            Section {
                HStack(spacing: 16) {
                    Image(systemName: DeviceListView.sfSymbol(for: device))
                        .font(.largeTitle)
                        .foregroundStyle(device.isOnline ? .green : .secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName)
                            .font(.title3.bold())
                        if let systemInfo = device.systemInfo, !systemInfo.isEmpty {
                            Text(systemInfo)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 4) {
                            Circle()
                                .fill(device.isOnline ? .green : .secondary)
                                .frame(width: 8, height: 8)
                            Text(device.isOnline ? "Online" : "Offline")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.secondary)
                }
            } else if let inv = inventory?.inventory {
                // Global Commands (tappable)
                if let commands = inv.globalCommands, !commands.isEmpty {
                    Section("Slash Commands") {
                        ForEach(commands) { cmd in
                            NavigationLink(value: cmd) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("/\(cmd.name)")
                                            .font(.body.monospaced().bold())
                                        Spacer()
                                        Text("global")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.blue.opacity(0.15), in: .capsule)
                                            .foregroundStyle(.blue)
                                    }
                                    if !cmd.description.isEmpty {
                                        Text(cmd.description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                }

                // Global Skills (tappable)
                if let skills = inv.globalSkills, !skills.isEmpty {
                    Section("Skills") {
                        ForEach(skills) { skill in
                            NavigationLink(value: skill) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("/\(skill.name)")
                                            .font(.body.monospaced().bold())
                                        Spacer()
                                        Text("global")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.green.opacity(0.15), in: .capsule)
                                            .foregroundStyle(.green)
                                    }
                                    if !skill.description.isEmpty {
                                        Text(skill.description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                }

                // Project Commands (tappable)
                if let projects = inv.projectCommands, !projects.isEmpty {
                    ForEach(projects) { project in
                        if let commands = project.commands, !commands.isEmpty {
                            Section("Commands \u{2014} \(projectName(project.projectPath))") {
                                ForEach(commands) { cmd in
                                    NavigationLink(value: cmd) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("/\(cmd.name)")
                                                .font(.body.monospaced().bold())
                                            if !cmd.description.isEmpty {
                                                Text(cmd.description)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(2)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if let skills = project.skills, !skills.isEmpty {
                            Section("Skills \u{2014} \(projectName(project.projectPath))") {
                                ForEach(skills) { skill in
                                    NavigationLink(value: skill) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("/\(skill.name)")
                                                .font(.body.monospaced().bold())
                                            if !skill.description.isEmpty {
                                                Text(skill.description)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(2)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // MCP Servers
                if let servers = inv.mcpServers, !servers.isEmpty {
                    Section("MCP Servers") {
                        ForEach(servers) { server in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(server.name)
                                    .font(.body.bold())
                                Text("\(server.command) \((server.args ?? []).joined(separator: " "))")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                // Project MCP Servers
                if let projects = inv.projectCommands, !projects.isEmpty {
                    ForEach(projects) { project in
                        if let servers = project.mcpServers, !servers.isEmpty {
                            Section("MCP Servers \u{2014} \(projectName(project.projectPath))") {
                                ForEach(servers) { server in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(server.name)
                                            .font(.body.bold())
                                        Text("\(server.command) \((server.args ?? []).joined(separator: " "))")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }

                // Hooks
                if let hooks = inv.hooks, !hooks.isEmpty {
                    Section("Hooks") {
                        ForEach(hooks) { hook in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(hook.eventType)
                                        .font(.caption.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.purple.opacity(0.15), in: .capsule)
                                        .foregroundStyle(.purple)
                                    if hook.matcher != "*" {
                                        Text(hook.matcher)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if hook.isAFK {
                                        Text("AFK")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.orange.opacity(0.15), in: .capsule)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Text(hook.command)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                // Teams
                if let teams = inv.teams, !teams.isEmpty {
                    Section("Teams") {
                        ForEach(teams) { team in
                            HStack {
                                Image(systemName: "person.2")
                                    .foregroundStyle(.cyan)
                                Text(team.name)
                                    .font(.body)
                            }
                        }
                    }
                }

                // Shared Skills (Pro feature)
                Section("Shared Skills") {
                    if tier == "pro" || tier == "contributor" {
                        if sharedSkills.isEmpty {
                            Text("No shared skills from other devices")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        } else {
                            ForEach(sharedSkills) { skill in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("/\(skill.name)")
                                        .font(.body.monospaced().bold())
                                    if let source = skill.sourceDeviceName {
                                        Text("From: \(source)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Pro Feature", systemImage: "lock.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(.orange)
                            Text("Upgrade to Pro to automatically share slash commands across all your Macs.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Empty inventory
                if (inv.globalCommands ?? []).isEmpty &&
                   (inv.globalSkills ?? []).isEmpty &&
                   (inv.projectCommands ?? []).isEmpty &&
                   (inv.mcpServers ?? []).isEmpty &&
                   (inv.hooks ?? []).isEmpty &&
                   (inv.teams ?? []).isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Inventory",
                            systemImage: "tray",
                            description: Text("This device hasn't reported any Claude Code capabilities yet")
                        )
                    }
                }
            }
        }
        .navigationTitle(displayName)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    renameText = displayName
                    showRenameAlert = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
        }
        .alert("Rename Device", isPresented: $showRenameAlert) {
            TextField("Device name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task { await renameDevice() }
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .navigationDestination(for: InventoryCommand.self) { cmd in
            CommandDetailView(command: cmd, sourceDevice: device, apiClient: apiClient, e2eeService: e2eeService, tier: tier)
        }
        .navigationDestination(for: InventorySkill.self) { skill in
            let cmd = InventoryCommand(name: skill.name, description: skill.description, content: skill.content, scope: skill.scope)
            CommandDetailView(command: cmd, sourceDevice: device, apiClient: apiClient, e2eeService: e2eeService, tier: tier)
        }
        .task {
            displayName = device.name
            await loadInventory()
        }
    }

    private func loadInventory() async {
        isLoading = true
        defer { isLoading = false }

        do {
            async let inventoryTask = apiClient.getDeviceInventory(deviceId: device.id)
            async let tierTask = apiClient.getSubscriptionStatus()

            var (inv, status) = try await (inventoryTask, tierTask)
            tier = status.tier

            // Decrypt E2EE-encrypted inventory if possible
            if inv.isEncrypted, let ciphertext = inv.inventory.encrypted, let e2ee = e2eeService {
                if let decrypted = decryptInventory(ciphertext: ciphertext, deviceId: device.id, e2ee: e2ee) {
                    inv.inventory = decrypted
                }
                // errorMessage is set inside decryptInventory if it fails
            }

            inventory = inv

            if tier == "pro" || tier == "contributor" {
                do {
                    sharedSkills = try await apiClient.getSharedSkills()
                } catch {
                    // Non-fatal: just don't show shared skills
                }
            }
        } catch {
            errorMessage = "Could not load inventory"
        }
    }

    /// Decrypt an encrypted inventory blob using the E2EE service.
    /// Uses the device ID as the key derivation salt (matching agent-side encryption).
    private func decryptInventory(ciphertext: String, deviceId: String, e2ee: E2EEService) -> InventoryReport? {
        guard let peerKey = device.keyAgreementPublicKey, !peerKey.isEmpty else {
            errorMessage = "Device has no E2EE key"
            return nil
        }

        // Try all available peer keys: current device key, then cached device keys from SessionStore
        let keysToTry: [(label: String, peerKey: String)] = [
            ("device.kaKey", peerKey)
        ]

        for attempt in keysToTry {
            do {
                let key = try e2ee.sessionKey(peerPublicKeyBase64: attempt.peerKey, sessionId: deviceId)
                let plaintext = try E2EEService.decryptValue(ciphertext, key: key)
                guard let data = plaintext.data(using: .utf8) else { continue }
                return try JSONDecoder().decode(InventoryReport.self, from: data)
            } catch {
                let myFP = E2EEService.fingerprint(of: e2ee.publicKeyBase64)
                let peerFP = E2EEService.fingerprint(of: attempt.peerKey)
                AppLogger.e2ee.warning("Inventory decrypt failed (\(attempt.label, privacy: .public)): myKey=\(myFP, privacy: .public) peerKey=\(peerFP, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
            }
        }

        errorMessage = "Cannot decrypt inventory (key mismatch)"
        return nil
    }

    private func renameDevice() async {
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        do {
            try await apiClient.renameDevice(id: device.id, name: newName)
            displayName = newName
        } catch {
            errorMessage = "Failed to rename device"
        }
    }

    private func projectName(_ path: String) -> String {
        path.components(separatedBy: "/").last ?? path
    }
}
