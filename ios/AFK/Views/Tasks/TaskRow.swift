import SwiftUI

struct TaskRow: View {
    let task: AFKTask
    let taskStore: TaskStore

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Task { await taskStore.toggleTask(task) }
            } label: {
                Image(systemName: task.status.iconName)
                    .foregroundStyle(task.status.color)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(task.source == .claudeCode)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.subject)
                    .font(.body)
                    .strikethrough(task.status == .completed)
                    .foregroundStyle(task.status == .completed ? .secondary : .primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Label(task.source.displayName, systemImage: task.source.iconName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let project = task.projectName, !project.isEmpty {
                        Text(project)
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }

                    if task.status == .inProgress {
                        Text(task.activeForm ?? "In Progress")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.12), in: Capsule())
                    }
                }
            }

            Spacer()

            if let updatedAt = task.updatedAt {
                RelativeTimeText(date: updatedAt)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            if task.source == .user {
                Button("Delete", role: .destructive) {
                    Task { await taskStore.deleteTask(task) }
                }
            }
        }
        .swipeActions(edge: .leading) {
            if task.source == .user {
                Button {
                    Task { await taskStore.toggleTask(task) }
                } label: {
                    Label(
                        task.status == .completed ? "Reopen" : "Complete",
                        systemImage: task.status == .completed ? "arrow.uturn.backward" : "checkmark"
                    )
                }
                .tint(task.status == .completed ? .orange : .green)
            }
        }
    }
}
