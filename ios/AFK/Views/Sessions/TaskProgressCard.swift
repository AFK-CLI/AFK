import SwiftUI

/// Aggregates multiple TaskCreate/TaskUpdate tool pairs across the session into a single
/// checklist card, similar to TodoWriteCard but for the newer TaskCreate/TaskUpdate tools.
struct TaskProgressCard: View {
    let pairs: [ToolCallPair]
    @State private var isExpanded = true

    private var taskItems: [TaskFieldItem] {
        // Build task list: TaskCreate adds items, TaskUpdate modifies status.
        // Process pairs in order so cumulative state is correct.
        var items: [TaskFieldItem] = []
        var nextInternalId = 1

        for pair in pairs {
            if pair.toolName == "TaskCreate" {
                let fields = pair.toolInputFields ?? []
                let fieldMap = Dictionary(fields.map { ($0.label, $0.value) }, uniquingKeysWith: { _, last in last })
                let subject = fieldMap["Subject"] ?? "Task"
                let activeForm = fieldMap["ActiveForm"]

                // Extract actual task ID from result (e.g. "Task #6 created successfully: ...")
                let taskId: String
                if let result = pair.toolResultSummary,
                   let range = result.range(of: "#(\\d+)", options: .regularExpression),
                   let numRange = result[range].dropFirst().isEmpty == false ? result[range].dropFirst() : nil {
                    taskId = String(numRange)
                } else {
                    taskId = "\(nextInternalId)"
                }
                nextInternalId += 1

                items.append(TaskFieldItem(id: taskId, subject: subject, status: "pending", activeForm: activeForm))

            } else if pair.toolName == "TaskUpdate" {
                let fields = pair.toolInputFields ?? []
                let fieldMap = Dictionary(fields.map { ($0.label, $0.value) }, uniquingKeysWith: { _, last in last })
                let taskId = fieldMap["TaskID"] ?? ""
                let status = fieldMap["Status"] ?? ""
                let activeForm = fieldMap["ActiveForm"]

                // Skip deletes and empty updates
                guard !taskId.isEmpty, status != "deleted" else { continue }

                if let idx = items.firstIndex(where: { $0.id == taskId }) {
                    if !status.isEmpty { items[idx].status = status }
                    if let af = activeForm { items[idx].activeForm = af }
                }
            }
            // TaskList and TaskGet are silently absorbed (no visual output needed)
        }

        // Filter out items that were deleted
        return items
    }

    private var completedCount: Int {
        taskItems.filter { $0.status == "completed" }.count
    }

    private var allComplete: Bool {
        pairs.allSatisfy(\.isComplete)
    }

    var body: some View {
        if !taskItems.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checklist")
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                            .frame(width: 24)

                        Text("Tasks (\(completedCount)/\(taskItems.count) done)")
                            .font(.subheadline)
                            .lineLimit(1)

                        Spacer()

                        // Progress pill
                        Text("\(completedCount)/\(taskItems.count)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(completedCount == taskItems.count ? .green : .blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                (completedCount == taskItems.count ? Color.green : Color.blue).opacity(0.12),
                                in: Capsule()
                            )

                        if !allComplete {
                            SymbolSpinner()
                        }

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)

                // Task items list
                if isExpanded {
                    Divider()
                        .padding(.horizontal, 12)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(taskItems) { item in
                            taskRow(item)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func taskRow(_ item: TaskFieldItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.iconName)
                .font(.subheadline)
                .foregroundStyle(item.iconColor)
                .frame(width: 20)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.subject)
                    .font(.subheadline)
                    .strikethrough(item.status == "completed")
                    .foregroundStyle(item.status == "completed" ? .secondary : .primary)
                    .lineLimit(3)

                if item.status == "in_progress", let activeForm = item.activeForm {
                    Text(activeForm)
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct TaskFieldItem: Identifiable {
    let id: String
    let subject: String
    var status: String
    var activeForm: String?

    var iconName: String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "in_progress": "circle.dotted.circle"
        default: "circle"
        }
    }

    var iconColor: Color {
        switch status {
        case "completed": .green
        case "in_progress": .blue
        default: .secondary
        }
    }
}
