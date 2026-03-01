import SwiftUI

struct TodoListView: View {
    let todoStore: TodoStore
    let apiClient: APIClient
    let commandStore: CommandStore
    @State private var showAddSheet = false

    var body: some View {
        NavigationStack {
            List {
                if todoStore.todos.isEmpty && !todoStore.isLoading {
                    ContentUnavailableView(
                        "No Todos",
                        systemImage: "checklist",
                        description: Text("Todo items from your project todo.md files will appear here.")
                    )
                }

                ForEach(todoStore.todos) { project in
                    NavigationLink(value: project.projectId) {
                        ProjectFolderRow(project: project)
                    }
                }
            }
            .navigationTitle("Todos")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddTodoSheet(todoStore: todoStore, apiClient: apiClient)
            }
            .navigationDestination(for: String.self) { projectId in
                ProjectTodoDetailView(
                    projectId: projectId,
                    todoStore: todoStore,
                    apiClient: apiClient
                )
            }
            .task {
                await todoStore.loadTodos()
            }
            .refreshable {
                await todoStore.loadTodos()
            }
        }
    }
}

// MARK: - Project Folder Row

private struct ProjectFolderRow: View {
    let project: ProjectTodos

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 3) {
                Text(project.projectName)
                    .font(.body.weight(.medium))

                HStack(spacing: 8) {
                    if project.uncheckedCount > 0 {
                        Text("\(project.uncheckedCount) remaining")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    let done = project.items.count - project.uncheckedCount
                    if done > 0 {
                        Text("\(done) done")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }

            Spacer()

            if project.uncheckedCount > 0 {
                Text("\(project.uncheckedCount)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(.blue, in: Circle())
            }
        }
        .padding(.vertical, 4)
    }
}
