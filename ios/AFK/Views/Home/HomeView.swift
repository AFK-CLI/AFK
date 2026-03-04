import SwiftUI

struct HomeView: View {
    let sessionStore: SessionStore
    let commandStore: CommandStore
    let apiClient: APIClient
    @Binding var deepLinkSessionId: String?
    var taskStore: TaskStore?
    var todoStore: TodoStore?
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = NavigationPath()
    @State private var showNewChat = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 16) {
                    if sessionStore.activeSessions.isEmpty {
                        ContentUnavailableView(
                            "No Active Sessions",
                            systemImage: "moon.zzz",
                            description: Text("Claude Code sessions will appear here when active")
                        )
                        .padding(.top, 60)
                    } else {
                        ForEach(sessionStore.activeSessions) { session in
                            NavigationLink(value: session.id) {
                                ActiveSessionCard(session: session)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Copy Resume Command", systemImage: "doc.on.doc") {
                                    let command = "cd \(session.projectPath) && claude --resume \(session.id)"
                                    UIPasteboard.general.string = command
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                }
                                if session.status == .idle {
                                    Button("Dismiss", systemImage: "xmark.circle") {
                                        withAnimation {
                                            sessionStore.dismissFromNow(session.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Now")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let deviceId = sessionStore.activeSessions.first?.deviceId {
                        AgentControlMenu(
                            deviceId: deviceId,
                            sessionStore: sessionStore
                        )
                    }
                    Button {
                        showNewChat = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $showNewChat) {
                NewChatSheet(
                    apiClient: apiClient,
                    commandStore: commandStore,
                    sessionStore: sessionStore
                )
            }
            .navigationDestination(for: String.self) { sessionId in
                SessionDetailView(
                    sessionId: sessionId,
                    sessionStore: sessionStore,
                    commandStore: commandStore,
                    apiClient: apiClient,
                    taskStore: taskStore,
                    todoStore: todoStore
                )
            }
            .task {
                await sessionStore.loadSessions()
                // Light polling fallback — WS handles real-time updates,
                // this just catches anything missed (e.g. after long sleep).
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    await sessionStore.loadSessions()
                }
            }
            .refreshable {
                await sessionStore.loadSessions()
            }
            .onChange(of: scenePhase) {
                if scenePhase == .active {
                    Task { await sessionStore.loadSessions() }
                }
            }
            .onChange(of: deepLinkSessionId) {
                if let sessionId = deepLinkSessionId {
                    // Pop to root then push to the target session
                    path = NavigationPath()
                    path.append(sessionId)
                    deepLinkSessionId = nil
                }
            }
        }
    }
}
