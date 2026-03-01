import SwiftUI

struct TaskListView: View {
    let taskStore: TaskStore
    let apiClient: APIClient
    @State private var selectedSource: TaskSource?
    @State private var searchText = ""
    @State private var showCreateSheet = false
    @State private var showCompleted = false

    var filteredTasks: [AFKTask] {
        var result = taskStore.tasks
        if let source = selectedSource {
            result = result.filter { $0.source == source }
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.subject.localizedCaseInsensitiveContains(searchText) ||
                $0.description.localizedCaseInsensitiveContains(searchText)
            }
        }
        return result
    }

    var activeTasks: [AFKTask] {
        filteredTasks.filter { $0.status != .completed }
    }

    var completedTasks: [AFKTask] {
        filteredTasks.filter { $0.status == .completed }
    }

    var body: some View {
        NavigationStack {
            List {
                if activeTasks.isEmpty && completedTasks.isEmpty && !taskStore.isLoading {
                    ContentUnavailableView(
                        "No Tasks",
                        systemImage: "checklist",
                        description: Text("Tasks from Claude Code sessions and your personal to-dos will appear here.")
                    )
                }

                if !activeTasks.isEmpty {
                    Section("Active") {
                        ForEach(activeTasks) { task in
                            TaskRow(task: task, taskStore: taskStore)
                        }
                    }
                }

                if !completedTasks.isEmpty {
                    Section {
                        Button {
                            withAnimation { showCompleted.toggle() }
                        } label: {
                            HStack {
                                Text("Completed")
                                    .foregroundStyle(.secondary)
                                Text("\(completedTasks.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.secondary.opacity(0.15), in: Capsule())
                                Spacer()
                                Image(systemName: showCompleted ? "chevron.up" : "chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)

                        if showCompleted {
                            ForEach(completedTasks) { task in
                                TaskRow(task: task, taskStore: taskStore)
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search tasks")
            .navigationTitle("Tasks")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            selectedSource = nil
                        } label: {
                            if selectedSource == nil {
                                Label("All Sources", systemImage: "checkmark")
                            } else {
                                Text("All Sources")
                            }
                        }
                        ForEach(TaskSource.allCases, id: \.self) { source in
                            Button {
                                selectedSource = source
                            } label: {
                                if selectedSource == source {
                                    Label(source.displayName, systemImage: "checkmark")
                                } else {
                                    Text(source.displayName)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: selectedSource == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreateSheet) {
                CreateTaskSheet(taskStore: taskStore, apiClient: apiClient)
            }
            .task {
                await taskStore.loadTasks()
            }
            .refreshable {
                await taskStore.loadTasks()
            }
        }
    }
}
