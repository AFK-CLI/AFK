import SwiftUI

struct CreateTaskSheet: View {
    let taskStore: TaskStore
    let apiClient: APIClient
    @Environment(\.dismiss) private var dismiss
    @State private var subject = ""
    @State private var description = ""
    @State private var selectedProjectId: String?
    @State private var projects: [Project] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("What needs to be done?", text: $subject)
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(3...6)
                }
                if !projects.isEmpty {
                    Section("Project (optional)") {
                        Picker("Project", selection: $selectedProjectId) {
                            Text("None").tag(nil as String?)
                            ForEach(projects) { project in
                                Text(project.name).tag(project.id as String?)
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            await taskStore.createTask(
                                subject: subject.trimmingCharacters(in: .whitespaces),
                                description: description.trimmingCharacters(in: .whitespaces),
                                projectId: selectedProjectId
                            )
                            dismiss()
                        }
                    }
                    .disabled(subject.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task {
                projects = (try? await apiClient.listProjects()) ?? []
            }
        }
    }
}
