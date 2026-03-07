import Foundation
import OSLog

@MainActor
@Observable
final class TodoStore {
    var todos: [ProjectTodos] = []
    var isLoading = false

    private let apiClient: APIClient

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Loading

    func loadTodos() async {
        guard !ScreenshotMode.isActive else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let raw = try await apiClient.listTodos()
            todos = Self.deduplicateByProject(raw)
        } catch {
            AppLogger.store.error("Failed to load todos: \(error, privacy: .public)")
        }
    }

    // MARK: - Mutations

    func appendTodo(projectId: String, text: String, projectName: String? = nil) async {
        // Optimistic local update
        if let index = todos.firstIndex(where: { $0.projectId == projectId }) {
            let existing = todos[index]
            let nextLine = (existing.items.map(\.line).max() ?? 0) + 1
            let item = TodoItem(text: text, checked: false, line: nextLine)
            let updated = ProjectTodos(
                projectId: existing.projectId,
                projectPath: existing.projectPath,
                projectName: existing.projectName,
                rawContent: existing.rawContent + "\n- [ ] \(text)",
                items: existing.items + [item],
                updatedAt: Date()
            )
            todos[index] = updated
        } else {
            let entry = ProjectTodos(
                projectId: projectId,
                projectPath: "",
                projectName: projectName ?? projectId,
                rawContent: "- [ ] \(text)",
                items: [TodoItem(text: text, checked: false, line: 1)],
                updatedAt: Date()
            )
            todos.append(entry)
        }

        do {
            try await apiClient.appendTodo(projectId: projectId, text: text)
        } catch {
            AppLogger.store.error("Failed to append todo: \(error, privacy: .public)")
            await loadTodos()
        }
    }

    func toggleTodo(projectId: String, item: TodoItem) async {
        let newChecked = !item.checked

        // Optimistic local update
        if let pIdx = todos.firstIndex(where: { $0.projectId == projectId }) {
            let project = todos[pIdx]
            let updatedItems = project.items.map { i in
                i.line == item.line ? TodoItem(text: i.text, checked: newChecked, line: i.line) : i
            }
            todos[pIdx] = ProjectTodos(
                projectId: project.projectId,
                projectPath: project.projectPath,
                projectName: project.projectName,
                rawContent: project.rawContent,
                items: updatedItems,
                updatedAt: Date()
            )
        }

        do {
            try await apiClient.toggleTodo(projectId: projectId, line: item.line, checked: newChecked)
        } catch {
            AppLogger.store.error("Failed to toggle todo: \(error, privacy: .public)")
            await loadTodos()
        }
    }

    // MARK: - Real-time Updates

    func handleTodoUpdate(_ projectTodos: ProjectTodos) {
        let merged = Self.mergeInto(existing: todos, incoming: projectTodos)
        if let index = merged.firstIndex(where: { $0.projectId == projectTodos.projectId }) {
            todos = merged
            _ = index // already placed
        } else {
            todos = merged
        }
    }

    // MARK: - Lookup

    func todos(for projectId: String) -> ProjectTodos? {
        todos.first { $0.projectId == projectId }
    }

    // MARK: - Deduplication

    /// Multiple paths (main project + worktrees) can map to the same projectId.
    /// Merge them by keeping the entry with the most items per projectId.
    private static func deduplicateByProject(_ raw: [ProjectTodos]) -> [ProjectTodos] {
        var best: [String: ProjectTodos] = [:]
        for entry in raw {
            if let existing = best[entry.projectId] {
                // Keep whichever has more items; merge items if both have some
                if entry.items.count > existing.items.count {
                    best[entry.projectId] = entry
                }
            } else {
                best[entry.projectId] = entry
            }
        }
        return Array(best.values).sorted { ($0.projectName) < ($1.projectName) }
    }

    /// Merge an incoming WS update into the existing array, deduplicating by projectId.
    private static func mergeInto(existing: [ProjectTodos], incoming: ProjectTodos) -> [ProjectTodos] {
        var result = existing.filter { $0.projectId != incoming.projectId }
        // Find the best entry: compare incoming with any existing entry for same project
        if let current = existing.first(where: { $0.projectId == incoming.projectId }) {
            // Keep the one with more items
            result.append(incoming.items.count >= current.items.count ? incoming : current)
        } else {
            result.append(incoming)
        }
        return result
    }
}
