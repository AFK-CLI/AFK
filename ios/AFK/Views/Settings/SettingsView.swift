import SwiftUI

struct SettingsView: View {
    let authService: AuthService
    let apiClient: APIClient
    let sessionStore: SessionStore
    let wsService: WebSocketService
    let subscriptionManager: SubscriptionManager
    let logUploader: LogUploader
    @AppStorage("timelineNewestFirst", store: BuildEnvironment.userDefaults) private
        var timelineNewestFirst = true
    @AppStorage("biometricGateEnabled", store: BuildEnvironment.userDefaults) private
        var biometricEnabled = false
    @State private var isSharingLogs = false
    @State private var showShareLogsResult = false
    @State private var shareLogsCount = 0
    @State private var isRegisteringPasskey = false
    @State private var passkeyResultMessage = ""
    @State private var showPasskeyResult = false

    var body: some View {
        NavigationStack {
            List {
                if let user = authService.currentUser {
                    Section("Account") {
                        LabeledContent("Email", value: user.email)
                        LabeledContent("Name", value: user.displayName)
                    }
                }

                Section("Subscription") {
                    SubscriptionStatusView(
                        subscriptionManager: subscriptionManager, apiClient: apiClient)
                }

                Section("Server") {
                    LabeledContent("URL", value: AppConfig.apiBaseURL)
                    Button("Change Server", role: .destructive) {
                        AppConfig.reset()
                        authService.signOut()
                    }
                }

                Section("Notifications") {
                    NavigationLink("Notification Settings") {
                        NotificationSettingsView(apiClient: apiClient)
                    }
                }

                Section("Security") {
                    Button {
                        Task {
                            isRegisteringPasskey = true
                            do {
                                try await authService.registerPasskey()
                                passkeyResultMessage = "Passkey registered successfully."
                            } catch {
                                passkeyResultMessage = error.localizedDescription
                            }
                            isRegisteringPasskey = false
                            showPasskeyResult = true
                        }
                    } label: {
                        HStack {
                            Label("Register a Passkey", systemImage: "person.badge.key.fill")
                            Spacer()
                            if isRegisteringPasskey {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isRegisteringPasskey)

                    if BiometricService.isAvailable {
                        Toggle(
                            "\(BiometricService.biometricType) for Commands",
                            isOn: $biometricEnabled)
                    }
                    NavigationLink("Audit Log") {
                        AuditLogView(apiClient: apiClient)
                    }
                }

                Section("Developer") {
                    NavigationLink("Diagnostics") {
                        DiagnosticsView(sessionStore: sessionStore, wsService: wsService)
                    }
                    NavigationLink("Logs") {
                        LogsView(apiClient: apiClient)
                    }
                }

                Section("Support") {
                    NavigationLink("Send Feedback") {
                        FeedbackView(apiClient: apiClient, deviceId: sessionStore.myDeviceId ?? "")
                    }
                    Button {
                        Task {
                            isSharingLogs = true
                            let count = await logUploader.shareAll()
                            shareLogsCount = count
                            isSharingLogs = false
                            showShareLogsResult = true
                        }
                    } label: {
                        HStack {
                            Text("Share Logs")
                            Spacer()
                            if isSharingLogs {
                                ProgressView()
                            } else if logUploader.bufferedCount > 0 {
                                Text("\(logUploader.bufferedCount)")
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }
                        }
                    }
                    .disabled(isSharingLogs)
                }

                Section("Display") {
                    Toggle("Newest events first", isOn: $timelineNewestFirst)
                }

                Section {
                    Button("Sign Out", role: .destructive) {
                        authService.signOut()
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear { logUploader.refreshBufferedCount() }
            .alert("Logs Shared", isPresented: $showShareLogsResult) {
                Button("OK", role: .cancel) {}
            } message: {
                if shareLogsCount > 0 {
                    Text("Uploaded \(shareLogsCount) log entries.")
                } else {
                    Text("No logs to share.")
                }
            }
            .alert("Passkey", isPresented: $showPasskeyResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(passkeyResultMessage)
            }
        }
    }
}
