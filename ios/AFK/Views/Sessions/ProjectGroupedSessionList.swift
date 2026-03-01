import SwiftUI

struct ProjectGroupedSessionList: View {
    let sessionStore: SessionStore
    let commandStore: CommandStore
    let apiClient: APIClient
    var taskStore: TaskStore?
    @Binding var selectedStatus: SessionStatus?
    @Binding var searchText: String

    private var groupedSessions: [(project: String, sessions: [Session])] {
        var groups = sessionStore.sessionsByProject
        if let status = selectedStatus {
            groups = groups.compactMap { group in
                let filtered = group.sessions.filter { $0.status == status }
                return filtered.isEmpty ? nil : (project: group.project, sessions: filtered)
            }
        }
        if !searchText.isEmpty {
            groups = groups.compactMap { group in
                let filtered = group.sessions.filter {
                    $0.projectPath.localizedCaseInsensitiveContains(searchText) ||
                    $0.gitBranch.localizedCaseInsensitiveContains(searchText)
                }
                return filtered.isEmpty ? nil : (project: group.project, sessions: filtered)
            }
        }
        return groups
    }

    var body: some View {
        List {
            ForEach(groupedSessions, id: \.project) { group in
                Section {
                    ForEach(group.sessions) { session in
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

                    // Show project task summary row if tasks exist for this project.
                    if let taskStore, !projectTasks(for: group.project, from: taskStore).isEmpty {
                        let tasks = projectTasks(for: group.project, from: taskStore)
                        let pending = tasks.filter { $0.status != .completed }.count
                        NavigationLink(value: "tasks:\(group.project)") {
                            HStack(spacing: 8) {
                                Image(systemName: "checklist")
                                    .foregroundStyle(.blue)
                                    .frame(width: 24)
                                Text("\(pending) active task\(pending == 1 ? "" : "s")")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(tasks.count) total")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    ProjectSectionHeader(
                        projectName: group.project,
                        sessions: group.sessions,
                        taskCount: taskStore.map { projectTasks(for: group.project, from: $0).filter { $0.status != .completed }.count } ?? 0
                    )
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search projects")
    }

    private func projectTasks(for projectName: String, from store: TaskStore) -> [AFKTask] {
        store.tasks.filter { $0.projectName == projectName }
    }
}

struct ProjectSectionHeader: View {
    let projectName: String
    let sessions: [Session]
    var taskCount: Int = 0

    private var activeCount: Int {
        sessions.filter { $0.status == .running || $0.status == .waitingPermission }.count
    }

    var body: some View {
        HStack {
            Image(systemName: "folder.fill")
                .foregroundStyle(activeCount > 0 ? .green : .secondary)
                .font(.caption)
            Text(projectName)
                .font(.subheadline.weight(.semibold))
            Spacer()
            if taskCount > 0 {
                Label("\(taskCount)", systemImage: "checklist")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.12), in: Capsule())
            }
            if activeCount > 0 {
                Text("\(activeCount) active")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.green.opacity(0.15), in: Capsule())
            }
            Text("\(sessions.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
