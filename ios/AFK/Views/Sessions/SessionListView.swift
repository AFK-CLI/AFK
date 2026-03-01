import SwiftUI

struct SessionListView: View {
    let sessionStore: SessionStore
    let commandStore: CommandStore
    let apiClient: APIClient
    var taskStore: TaskStore?
    var todoStore: TodoStore?
    @State private var viewMode: ViewMode = .grouped
    @State private var selectedStatus: SessionStatus?
    @State private var searchText = ""
    @State private var showNewChat = false

    enum ViewMode: String, CaseIterable {
        case grouped = "Projects"
        case flat = "All"
    }

    var filteredSessions: [Session] {
        var result = sessionStore.sessions
        if let status = selectedStatus {
            result = result.filter { $0.status == status }
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.projectPath.localizedCaseInsensitiveContains(searchText) ||
                $0.gitBranch.localizedCaseInsensitiveContains(searchText)
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Group {
                switch viewMode {
                case .grouped:
                    ProjectGroupedSessionList(
                        sessionStore: sessionStore,
                        commandStore: commandStore,
                        apiClient: apiClient,
                        taskStore: taskStore,
                        selectedStatus: $selectedStatus,
                        searchText: $searchText
                    )
                case .flat:
                    List(filteredSessions) { session in
                        NavigationLink(value: session.id) {
                            SessionRow(session: session)
                        }
                        .swipeActions(edge: .trailing) {
                            if session.status == .idle || session.status == .error {
                                Button("Archive") {
                                    withAnimation {
                                        sessionStore.archiveSession(session.id)
                                    }
                                }
                                .tint(.gray)
                            }
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search projects")
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("View", selection: $viewMode) {
                        ForEach(ViewMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            showNewChat = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        Menu {
                            Button("All") { selectedStatus = nil }
                            ForEach(
                                [SessionStatus.running, .idle, .waitingPermission, .error, .completed],
                                id: \.self
                            ) { status in
                                Button(status.displayName) { selectedStatus = status }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
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
            .navigationDestination(for: String.self) { value in
                if value.hasPrefix("tasks:"), let taskStore {
                    let projectName = String(value.dropFirst("tasks:".count))
                    ProjectTasksView(projectName: projectName, taskStore: taskStore)
                } else {
                    SessionDetailView(sessionId: value, sessionStore: sessionStore, commandStore: commandStore, apiClient: apiClient, taskStore: taskStore, todoStore: todoStore)
                }
            }
            .task {
                await sessionStore.loadSessions()
            }
            .refreshable {
                await sessionStore.loadSessions()
            }
        }
    }
}
