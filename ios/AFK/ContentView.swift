import SwiftUI

struct ContentView: View {
    let authService: AuthService
    let apiClient: APIClient
    let wsService: WebSocketService
    let sessionStore: SessionStore
    let commandStore: CommandStore
    @Binding var deepLinkSessionId: String?
    let subscriptionManager: SubscriptionManager
    let taskStore: TaskStore
    let todoStore: TodoStore
    let logUploader: LogUploader
    @State private var selectedTab = "now"
    @State private var serverConfigured = AppConfig.isConfigured

    var body: some View {
        if !serverConfigured {
            ServerSetupView {
                serverConfigured = true
            }
        } else if authService.isAuthenticated {
            TabView(selection: $selectedTab) {
                Tab("Now", systemImage: "bolt.fill", value: "now") {
                    HomeView(
                        sessionStore: sessionStore,
                        commandStore: commandStore,
                        apiClient: apiClient,
                        deepLinkSessionId: $deepLinkSessionId,
                        taskStore: taskStore,
                        todoStore: todoStore
                    )
                }

                Tab("Sessions", systemImage: "list.bullet", value: "sessions") {
                    SessionListView(sessionStore: sessionStore, commandStore: commandStore, apiClient: apiClient, taskStore: taskStore, todoStore: todoStore)
                }

                Tab("Todos", systemImage: "checklist", value: "todos") {
                    TodoListView(todoStore: todoStore, apiClient: apiClient, commandStore: commandStore)
                }
                .badge(todoStore.todos.reduce(0) { $0 + $1.uncheckedCount })

                Tab("Devices", systemImage: "laptopcomputer", value: "devices") {
                    DeviceListView(apiClient: apiClient)
                }

                Tab("Settings", systemImage: "gear", value: "settings") {
                    SettingsView(authService: authService, apiClient: apiClient, sessionStore: sessionStore, wsService: wsService, subscriptionManager: subscriptionManager, logUploader: logUploader)
                }
            }
            .onChange(of: deepLinkSessionId) {
                if deepLinkSessionId != nil {
                    selectedTab = "now"
                }
            }
        } else {
            SignInView(authService: authService)
        }
    }
}
