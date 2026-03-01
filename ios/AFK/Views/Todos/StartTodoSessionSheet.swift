import SwiftUI

struct StartTodoSessionSheet: View {
    let todoText: String
    let projectId: String
    let apiClient: APIClient
    @Environment(\.dismiss) private var dismiss

    @State private var additionalPrompt = ""
    @State private var selectedDeviceId: String?
    @State private var useWorktree = true
    @State private var permissionMode = "default"
    @State private var devices: [Device] = []
    @State private var isLoadingDevices = true
    @State private var isSending = false
    @State private var errorMessage: String?

    private var myDeviceId: String? {
        UserDefaults.standard.string(forKey: "afk_ios_device_id")
    }

    private var onlineMacs: [Device] {
        devices.filter { $0.isOnline && $0.id != myDeviceId }
    }

    private var canStart: Bool {
        selectedDeviceId != nil && !isSending
    }

    /// Combine the todo item text with any additional instructions.
    private var fullPrompt: String {
        if additionalPrompt.trimmingCharacters(in: .whitespaces).isEmpty {
            return todoText
        }
        return "\(todoText)\n\nAdditional details: \(additionalPrompt.trimmingCharacters(in: .whitespaces))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("To-do") {
                    Text(todoText)
                        .foregroundStyle(.primary)
                }

                Section {
                    TextField("Add details or instructions...", text: $additionalPrompt, axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    Text("Additional Prompt")
                } footer: {
                    Text("Optional extra context appended to the todo when starting the session.")
                }

                Section {
                    if isLoadingDevices {
                        HStack {
                            ProgressView()
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
                                Text(device.name).tag(device.id as String?)
                            }
                        }
                    }
                } header: {
                    Text("Device")
                }

                Section {
                    Toggle("Use worktree", isOn: $useWorktree)
                } footer: {
                    Text("Creates an isolated git worktree so the session doesn't affect your working branch.")
                }

                Section {
                    Picker("Permission Mode", selection: $permissionMode) {
                        Text("Default").tag("default")
                        Text("Plan").tag("plan")
                        Text("Accept Edits").tag("acceptEdits")
                        Text("Don't Ask").tag("dontAsk")
                    }
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("Start Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        Task { await start() }
                    }
                    .fontWeight(.semibold)
                    .disabled(!canStart)
                }
            }
            .task {
                isLoadingDevices = true
                defer { isLoadingDevices = false }
                devices = (try? await apiClient.listDevices()) ?? []
                if onlineMacs.count == 1 {
                    selectedDeviceId = onlineMacs.first?.id
                }
            }
        }
    }

    private func start() async {
        guard let deviceId = selectedDeviceId else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }

        do {
            _ = try await apiClient.startTodoSession(
                projectId: projectId,
                deviceId: deviceId,
                todoText: fullPrompt,
                useWorktree: useWorktree,
                permissionMode: permissionMode
            )
            dismiss()
        } catch {
            errorMessage = "Failed to start: \(error.localizedDescription)"
        }
    }
}
