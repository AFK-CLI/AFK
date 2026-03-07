import Foundation

struct TodoItem: Codable, Identifiable, Sendable {
    let text: String
    let checked: Bool
    let inProgress: Bool
    let line: Int

    var id: String { "\(line):\(text)" }

    init(text: String, checked: Bool, inProgress: Bool = false, line: Int) {
        self.text = text
        self.checked = checked
        self.inProgress = inProgress
        self.line = line
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        checked = try container.decode(Bool.self, forKey: .checked)
        inProgress = try container.decodeIfPresent(Bool.self, forKey: .inProgress) ?? false
        line = try container.decode(Int.self, forKey: .line)
    }
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
