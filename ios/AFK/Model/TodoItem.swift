import Foundation

struct TodoItem: Codable, Identifiable, Sendable {
    let text: String
    let checked: Bool
    let line: Int

    var id: String { "\(line):\(text)" }
}

struct ProjectTodos: Codable, Identifiable, Sendable {
    let projectId: String
    let projectPath: String
    let projectName: String
    let rawContent: String
    let items: [TodoItem]
    var updatedAt: Date?

    var id: String { projectId }

    var uncheckedCount: Int { items.filter { !$0.checked }.count }
}
