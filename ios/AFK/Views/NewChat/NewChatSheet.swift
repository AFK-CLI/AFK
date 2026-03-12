import SwiftUI
import CryptoKit

struct NewChatSheet: View {
    let apiClient: APIClient
    let commandStore: CommandStore
    let sessionStore: SessionStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("biometricGateEnabled", store: BuildEnvironment.userDefaults) private var biometricGateEnabled = false

    @State private var prompt = ""
    @State private var selectedDeviceId: String?
    @State private var selectedProjectPath = ""
    @State private var useWorktree = true
    @State private var worktreeName = ""
    @State private var permissionMode = "default"
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var devices: [Device] = []
    @State private var projects: [Project] = []
    @State private var deviceProjects: [String] = []
    @State private var isLoadingDevices = true
    @State private var isLoadingProjects = false

    private var myDeviceId: String? {
        BuildEnvironment.userDefaults.string(forKey: "afk_ios_device_id")
    }

    /// Mac devices that are online (excluding this iOS device).
    private var onlineMacs: [Device] {
        devices.filter { $0.isOnline && $0.id != myDeviceId }
    }

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && selectedDeviceId != nil
        && !selectedProjectPath.isEmpty
        && !isSending
    }

    var body: some View {
        NavigationStack {
            Form {
                deviceSection
                projectSection
                worktreeSection
                permissionModeSection
                promptSection

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task { await send() }
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSend)
                }
            }
            .task {
                await loadData()
            }
            .onChange(of: selectedDeviceId) { _, newDeviceId in
                selectedProjectPath = ""
                deviceProjects = []
                guard let deviceId = newDeviceId else { return }
                Task { await loadDeviceProjects(deviceId: deviceId) }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var deviceSection: some View {
        Section {
            if isLoadingDevices {
                HStack {
                    SymbolSpinner()
                    Text("Loading devices...")
                        .foregroundStyle(.secondary)
                }
            } else if onlineMacs.isEmpty {
                Label("No Macs online", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Device", selection: $selectedDeviceId) {
                    Text("Select a Mac").tag(nil as String?)
                    ForEach(onlineMacs) { device in
                        HStack {
                            Text(device.name)
                            if let info = device.systemInfo, !info.isEmpty {
                                Text(info)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(device.id as String?)
                    }
                }
            }
        } header: {
            Text("Device")
        } footer: {
            Text("The Mac where Claude Code will run.")
        }
    }

    @ViewBuilder
    private var projectSection: some View {
        Section {
            if selectedDeviceId == nil {
                Text("Select a device first")
                    .foregroundStyle(.secondary)
            } else if isLoadingProjects {
                HStack {
                    SymbolSpinner()
                    Text("Loading projects...")
                        .foregroundStyle(.secondary)
                }
            } else if deviceProjects.isEmpty && projects.isEmpty {
                TextField("Project path (e.g. /Users/you/project)", text: $selectedProjectPath)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } else {
                let availableProjects = mergedProjects
                Picker("Project", selection: $selectedProjectPath) {
                    Text("Select a project").tag("")
                    ForEach(availableProjects, id: \.path) { proj in
                        Text(proj.name)
                            .tag(proj.path)
                    }
                }
            }
        } header: {
            Text("Project")
        } footer: {
            Text("Projects detected on this Mac.")
        }
    }

    /// Merge inventory project paths with known projects from the DB, preferring inventory.
    private var mergedProjects: [(path: String, name: String)] {
        var seen = Set<String>()
        var result: [(path: String, name: String)] = []
        for path in deviceProjects {
            let name = path.components(separatedBy: "/").last ?? path
            result.append((path: path, name: name))
            seen.insert(path)
        }
        for project in projects {
            if !seen.contains(project.path) {
                result.append((path: project.path, name: project.name))
            }
        }
        return result
    }

    @ViewBuilder
    private var worktreeSection: some View {
        Section {
            Toggle("Use worktree", isOn: $useWorktree)
            if useWorktree {
                TextField("Worktree name (optional)", text: $worktreeName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        } footer: {
            Text("Creates an isolated git worktree so the new chat doesn't affect your working branch.")
        }
    }

    @ViewBuilder
    private var permissionModeSection: some View {
        Section {
            Picker("Permission Mode", selection: $permissionMode) {
                Text("Default").tag("default")
                Text("Plan (read-only, then approve)").tag("plan")
                Text("Accept Edits (auto-approve writes)").tag("acceptEdits")
                Text("Don't Ask (auto-approve all)").tag("dontAsk")
            }
        } footer: {
            Text("Controls how Claude handles permissions. \"Plan\" starts in plan mode — Claude proposes changes before writing.")
        }
    }

    @ViewBuilder
    private var promptSection: some View {
        Section("Prompt") {
            TextEditor(text: $prompt)
                .frame(minHeight: 100, maxHeight: 200)
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("What would you like Claude to do?")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    // MARK: - Actions

    private func loadData() async {
        isLoadingDevices = true
        defer { isLoadingDevices = false }

        async let devicesResult = apiClient.listDevices()
        async let projectsResult = apiClient.listProjects()

        devices = (try? await devicesResult) ?? []
        projects = (try? await projectsResult) ?? []

        // Auto-select if only one Mac online
        if onlineMacs.count == 1 {
            selectedDeviceId = onlineMacs.first?.id
        }
    }

    private func loadDeviceProjects(deviceId: String) async {
        isLoadingProjects = true
        defer { isLoadingProjects = false }

        do {
            var inv = try await apiClient.getDeviceInventory(deviceId: deviceId)

            // Decrypt E2EE inventory if needed
            if inv.isEncrypted, let ciphertext = inv.inventory.encrypted {
                let device = devices.first(where: { $0.id == deviceId })
                if let peerKey = device?.keyAgreementPublicKey, !peerKey.isEmpty {
                    let e2ee = E2EEService()
                    if let decrypted = decryptInventory(ciphertext: ciphertext, deviceId: deviceId, peerKey: peerKey, e2ee: e2ee) {
                        inv.inventory = decrypted
                    }
                }
            }

            var paths: [String] = []
            if let projectCommands = inv.inventory.projectCommands {
                for proj in projectCommands {
                    paths.append(proj.projectPath)
                }
            }
            deviceProjects = paths

            // Auto-select if only one project
            if paths.count == 1 {
                selectedProjectPath = paths[0]
            }
        } catch {
            deviceProjects = []
        }
    }

    private func decryptInventory(ciphertext: String, deviceId: String, peerKey: String, e2ee: E2EEService) -> InventoryReport? {
        do {
            let key = try e2ee.sessionKey(peerPublicKeyBase64: peerKey, sessionId: deviceId)
            let plaintext = try E2EEService.decryptValue(ciphertext, key: key)
            guard let data = plaintext.data(using: .utf8) else { return nil }
            return try JSONDecoder().decode(InventoryReport.self, from: data)
        } catch {
            return nil
        }
    }

    private func send() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let deviceId = selectedDeviceId else { return }

        // Biometric gate if enabled
        if biometricGateEnabled {
            let biometric = BiometricService()
            do {
                try await biometric.authenticate(reason: "Authenticate to start new chat")
            } catch {
                errorMessage = "Authentication required"
                return
            }
        }

        isSending = true
        errorMessage = nil
        defer { isSending = false }

        do {
            let trimmedName = worktreeName.trimmingCharacters(in: .whitespacesAndNewlines)
            let modeParam = permissionMode == "default" ? nil : permissionMode
            let response = try await apiClient.newChat(
                prompt: text,
                projectPath: selectedProjectPath,
                deviceId: deviceId,
                useWorktree: useWorktree,
                worktreeName: trimmedName.isEmpty ? nil : trimmedName,
                permissionMode: modeParam
            )
            // Track in command store — use empty sessionId since we don't have one yet.
            // The command will complete with a newSessionId via WS.
            commandStore.startCommand(id: response.commandId, sessionId: "", prompt: text)
            dismiss()
        } catch {
            errorMessage = "Failed to send: \(error.localizedDescription)"
        }
    }
}
