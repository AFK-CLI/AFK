import SwiftUI

struct FloatingTaskButton: View {
    let sessionId: String
    let taskStore: TaskStore
    @State private var showPopover = false

    private var sessionTasks: [AFKTask] {
        taskStore.tasks.filter { $0.sessionId == sessionId && $0.source == .claudeCode }
    }

    private var activeCount: Int {
        sessionTasks.filter { $0.status != .completed }.count
    }

    var body: some View {
        if !sessionTasks.isEmpty {
            Button {
                showPopover.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checklist.unchecked")
                        .font(.subheadline.weight(.medium))
                    if activeCount > 0 {
                        Text("\(activeCount)")
                            .font(.caption.weight(.bold))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPopover) {
                SessionTasksPopover(tasks: sessionTasks)
            }
            .transition(.scale.combined(with: .opacity))
        }
    }
}

struct SessionTasksPopover: View {
    let tasks: [AFKTask]

    var body: some View {
        NavigationStack {
            List(tasks) { task in
                HStack(spacing: 10) {
                    Circle()
                        .fill(task.status.color)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.subject)
                            .font(.subheadline)
                            .lineLimit(2)

                        if task.status == .inProgress, let activeForm = task.activeForm {
                            Text(activeForm)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Text(task.status.displayName)
                        .font(.caption2)
                        .foregroundStyle(task.status.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(task.status.color.opacity(0.12), in: Capsule())
                }
            }
            .navigationTitle("Session Tasks")
            .navigationBarTitleDisplayMode(.inline)
        }
        .frame(minWidth: 300, minHeight: 200)
        .background(.ultraThinMaterial)
    }
}
