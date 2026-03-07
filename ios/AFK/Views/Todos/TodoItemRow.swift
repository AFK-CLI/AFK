import SwiftUI

struct TodoItemRow: View {
    let item: TodoItem
    var onToggle: (() -> Void)?
    var onStartSession: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onToggle?()
            } label: {
                if item.inProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: item.checked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.checked ? .green : .secondary)
                        .font(.title3)
                }
            }
            .buttonStyle(.plain)

            Text(item.text)
                .font(.body)
                .strikethrough(item.checked)
                .foregroundStyle(item.inProgress ? .orange : (item.checked ? .secondary : .primary))
                .lineLimit(3)

            Spacer()

            if !item.checked && !item.inProgress, let onStartSession {
                Button {
                    onStartSession()
                } label: {
                    Image(systemName: "play.circle")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }
}
