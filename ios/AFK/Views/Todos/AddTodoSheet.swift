import SwiftUI

struct AddTodoSheet: View {
    let todoStore: TodoStore
    let apiClient: APIClient
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var selectedProjectId: String?
    @State private var allProjects: [Project] = []
    @State private var isLoadingProjects = true

    /// Merge todo-synced projects with all known projects so the user
    /// can create a todo.md for any project, not just ones that already have one.
    private var projectOptions: [(id: String, name: String)] {
        var seen = Set<String>()
        var result: [(id: String, name: String)] = []

        // Projects that already have todos come first
        for todo in todoStore.todos {
            if seen.insert(todo.projectId).inserted {
                result.append((id: todo.projectId, name: todo.projectName))
            }
        }

        // Then add remaining known projects
        for project in allProjects {
            if seen.insert(project.id).inserted {
                result.append((id: project.id, name: project.name))
            }
        }

        return result
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    if isLoadingProjects && projectOptions.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Loading projects...")
                                .foregroundStyle(.secondary)
                        }
                    } else if projectOptions.isEmpty {
                        Text("No projects found. Start a Claude Code session first.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Project", selection: $selectedProjectId) {
                            Text("Select a project").tag(nil as String?)
                            ForEach(projectOptions, id: \.id) { option in
                                Text(option.name).tag(option.id as String?)
                            }
                        }
                    }
                }

                Section("To-do") {
                    TextField("What needs to be done?", text: $text)
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
                        guard let projectId = selectedProjectId else { return }
                        let name = projectOptions.first(where: { $0.id == projectId })?.name
                        Task {
                            await todoStore.appendTodo(projectId: projectId, text: text.trimmingCharacters(in: .whitespaces), projectName: name)
                            dismiss()
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || selectedProjectId == nil)
                }
            }
            .task {
                isLoadingProjects = true
                defer { isLoadingProjects = false }
                allProjects = (try? await apiClient.listProjects()) ?? []
                // Auto-select if only one project available
                if projectOptions.count == 1 {
                    selectedProjectId = projectOptions.first?.id
                }
            }
        }
    }
}
