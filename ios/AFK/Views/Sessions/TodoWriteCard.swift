import SwiftUI

/// Renders a TodoWrite tool call as a checklist card showing each todo item with status.
struct TodoWriteCard: View {
    let pair: ToolCallPair
    @State private var isExpanded = true

    private var todoItems: [TodoFieldItem] {
        guard let fields = pair.toolInputFields else { return [] }
        return fields.compactMap { field -> TodoFieldItem? in
            guard field.style.hasPrefix("todo_") else { return nil }
            let status = String(field.style.dropFirst(5)) // "pending", "in_progress", "completed"
            let parts = field.value.split(separator: "\n", maxSplits: 1)
            let content = String(parts.first ?? "")
            let activeForm = parts.count > 1 ? String(parts[1]) : nil
            return TodoFieldItem(content: content, status: status, activeForm: activeForm)
        }
    }

    private var completedCount: Int {
        todoItems.filter { $0.status == "completed" }.count
    }

    var body: some View {
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

                    Text(pair.toolDescription ?? "Tasks")
                        .font(.subheadline)
                        .lineLimit(1)

                    Spacer()

                    // Progress pill
                    Text("\(completedCount)/\(todoItems.count)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(completedCount == todoItems.count ? .green : .blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            (completedCount == todoItems.count ? Color.green : Color.blue).opacity(0.12),
                            in: Capsule()
                        )

                    if !pair.isComplete {
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

            // Todo items list
            if isExpanded && !todoItems.isEmpty {
                Divider()
                    .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(todoItems.enumerated()), id: \.offset) { _, item in
                        todoRow(item)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func todoRow(_ item: TodoFieldItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.iconName)
                .font(.subheadline)
                .foregroundStyle(item.iconColor)
                .frame(width: 20)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.content)
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

private struct TodoFieldItem {
    let content: String
    let status: String
    let activeForm: String?

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
