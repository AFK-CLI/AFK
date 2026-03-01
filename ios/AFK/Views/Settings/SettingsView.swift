import SwiftUI

struct SettingsView: View {
    let authService: AuthService
    let apiClient: APIClient
    let sessionStore: SessionStore
    let wsService: WebSocketService
    let subscriptionManager: SubscriptionManager
    @AppStorage("timelineNewestFirst", store: BuildEnvironment.userDefaults) private var timelineNewestFirst = true
    @AppStorage("biometricGateEnabled", store: BuildEnvironment.userDefaults) private var biometricEnabled = false

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
                    SubscriptionStatusView(subscriptionManager: subscriptionManager, apiClient: apiClient)
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
                    if BiometricService.isAvailable {
                        Toggle("\(BiometricService.biometricType) for Commands", isOn: $biometricEnabled)
                    }
                    NavigationLink("Audit Log") {
                        AuditLogView(apiClient: apiClient)
                    }
                }

                Section("Developer") {
                    NavigationLink("Diagnostics") {
                        DiagnosticsView(sessionStore: sessionStore, wsService: wsService)
                    }
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
        }
    }
}
