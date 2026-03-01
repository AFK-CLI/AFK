import SwiftUI

struct ProjectTodoDetailView: View {
    let projectId: String
    let todoStore: TodoStore
    let apiClient: APIClient
    @State private var showAddSheet = false
    @State private var startSessionItem: StartSessionInfo?

    private var project: ProjectTodos? {
        todoStore.todos(for: projectId)
    }

    private var uncheckedItems: [TodoItem] {
        project?.items.filter { !$0.checked } ?? []
    }

    private var checkedItems: [TodoItem] {
        project?.items.filter { $0.checked } ?? []
    }

    var body: some View {
        List {
            if let project, project.items.isEmpty {
                ContentUnavailableView(
                    "No Items",
                    systemImage: "checkmark.circle",
                    description: Text("Add a to-do item to get started.")
                )
            }

            if !uncheckedItems.isEmpty {
                Section {
                    ForEach(uncheckedItems) { item in
                        TodoItemRow(
                            item: item,
                            onToggle: {
                                Task { await todoStore.toggleTodo(projectId: projectId, item: item) }
                            },
                            onStartSession: {
                                startSessionItem = StartSessionInfo(
                                    text: item.text,
                                    projectId: projectId
                                )
                            }
                        )
                    }
                }
            }

            if !checkedItems.isEmpty {
                Section("Completed") {
                    ForEach(checkedItems) { item in
                        TodoItemRow(
                            item: item,
                            onToggle: {
                                Task { await todoStore.toggleTodo(projectId: projectId, item: item) }
                            }
                        )
                    }
                }
            }
        }
        .navigationTitle(project?.projectName ?? "Todos")
        .navigationBarTitleDisplayMode(.inline)
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
            QuickAddTodoSheet(projectId: projectId, projectName: project?.projectName ?? "", todoStore: todoStore)
        }
        .sheet(item: $startSessionItem) { info in
            StartTodoSessionSheet(
                todoText: info.text,
                projectId: info.projectId,
                apiClient: apiClient
            )
        }
    }
}

// MARK: - Quick Add (single project, no picker needed)

private struct QuickAddTodoSheet: View {
    let projectId: String
    let projectName: String
    let todoStore: TodoStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What needs to be done?", text: $text, axis: .vertical)
                        .lineLimit(1...5)
                } footer: {
                    Text("Adding to \(projectName)")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add To-do")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            await todoStore.appendTodo(
                                projectId: projectId,
                                text: text.trimmingCharacters(in: .whitespaces),
                                projectName: projectName
                            )
                            dismiss()
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Helpers

private struct StartSessionInfo: Identifiable {
    let text: String
    let projectId: String
    var id: String { "\(projectId):\(text)" }
}
