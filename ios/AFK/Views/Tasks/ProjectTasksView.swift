import SwiftUI

struct ProjectTasksView: View {
    let projectName: String
    let taskStore: TaskStore

    private var projectTasks: [AFKTask] {
        taskStore.tasks.filter { $0.projectName == projectName }
    }

    private var activeTasks: [AFKTask] {
        projectTasks.filter { $0.status != .completed }
    }

    private var completedTasks: [AFKTask] {
        projectTasks.filter { $0.status == .completed }
    }

    var body: some View {
        List {
            if projectTasks.isEmpty {
                ContentUnavailableView(
                    "No Tasks",
                    systemImage: "checklist",
                    description: Text("No tasks for this project yet.")
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
                Section("Completed") {
                    ForEach(completedTasks) { task in
                        TaskRow(task: task, taskStore: taskStore)
                    }
                }
            }
        }
        .navigationTitle(projectName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
