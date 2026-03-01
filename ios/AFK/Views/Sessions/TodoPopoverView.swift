import SwiftUI

struct TodoPopoverView: View {
    let projectId: String?
    let todoStore: TodoStore

    private var projectTodos: ProjectTodos? {
        guard let projectId else { return nil }
        return todoStore.todos(for: projectId)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let projectTodos, !projectTodos.items.isEmpty {
                    List(projectTodos.items) { item in
                        HStack(spacing: 10) {
                            Image(systemName: item.checked ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.checked ? .green : .secondary)

                            Text(item.text)
                                .font(.subheadline)
                                .strikethrough(item.checked)
                                .foregroundStyle(item.checked ? .secondary : .primary)
                                .lineLimit(3)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Todos",
                        systemImage: "checklist",
                        description: Text("No todo items for this project.")
                    )
                }
            }
            .navigationTitle("Project Todos")
            .navigationBarTitleDisplayMode(.inline)
        }
        .frame(minWidth: 300, minHeight: 200)
        .background(.ultraThinMaterial)
    }
}
