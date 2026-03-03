import Foundation
import OSLog

@MainActor
@Observable
final class TaskStore {
    var tasks: [AFKTask] = []
    var isLoading = false

    private let apiClient: APIClient
    private let localStore: LocalStore

    init(apiClient: APIClient, localStore: LocalStore) {
        self.apiClient = apiClient
        self.localStore = localStore
    }

    // MARK: - Loading

    func loadTasks() async {
        isLoading = true
        defer { isLoading = false }

        do {
            tasks = try await apiClient.listTasks()
            localStore.saveTasks(tasks)
        } catch {
            AppLogger.store.error("Failed to load tasks: \(error, privacy: .public)")
            tasks = localStore.cachedTasks()
        }
    }

    // MARK: - User Task CRUD

    func createTask(subject: String, description: String = "", projectId: String? = nil) async {
        do {
            let task = try await apiClient.createTask(subject: subject, description: description, projectId: projectId)
            tasks.insert(task, at: 0)
            localStore.saveTask(task)
        } catch {
            AppLogger.store.error("Failed to create task: \(error, privacy: .public)")
        }
    }

    func toggleTask(_ task: AFKTask) async {
        let newStatus: AFKTaskStatus = task.status == .completed ? .pending : .completed
        do {
            let updated = try await apiClient.updateTask(id: task.id, status: newStatus.rawValue)
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = updated
            }
            localStore.saveTask(updated)
        } catch {
            AppLogger.store.error("Failed to toggle task: \(error, privacy: .public)")
        }
    }

    func deleteTask(_ task: AFKTask) async {
        guard task.source == .user else { return }
        do {
            try await apiClient.deleteTask(id: task.id)
            tasks.removeAll { $0.id == task.id }
            localStore.deleteTask(id: task.id)
        } catch {
            AppLogger.store.error("Failed to delete task: \(error, privacy: .public)")
        }
    }

    // MARK: - Real-time Updates

    func handleTaskUpdate(_ task: AFKTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.insert(task, at: 0)
        }
        localStore.saveTask(task)
    }

    // MARK: - Computed

    var pendingCount: Int {
        tasks.filter { $0.status == .pending || $0.status == .inProgress }.count
    }
}
