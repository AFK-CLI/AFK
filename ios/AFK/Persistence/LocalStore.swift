import Foundation
import SwiftData

@MainActor
final class LocalStore {
    let container: ModelContainer
    let context: ModelContext

    static let shared: LocalStore = {
        do {
            return try LocalStore()
        } catch {
            fatalError("Failed to create LocalStore: \(error)")
        }
    }()

    init() throws {
        let schema = Schema([
            CachedSession.self,
            CachedEvent.self,
            CachedCommand.self,
            CachedTask.self,
        ])
        let config = ModelConfiguration(
            BuildEnvironment.swiftDataName,
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )
        container = try ModelContainer(for: schema, configurations: [config])
        context = container.mainContext
        context.autosaveEnabled = true
    }

    // MARK: - Sessions

    func cachedSessions() -> [Session] {
        let descriptor = FetchDescriptor<CachedSession>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let cached = (try? context.fetch(descriptor)) ?? []
        return cached.map { $0.toSession() }
    }

    func saveSessions(_ sessions: [Session]) {
        for session in sessions {
            let id = session.id
            let predicate = #Predicate<CachedSession> { $0.id == id }
            let descriptor = FetchDescriptor<CachedSession>(predicate: predicate)
            if let existing = try? context.fetch(descriptor).first {
                existing.update(from: session)
            } else {
                context.insert(CachedSession(from: session))
            }
        }
        try? context.save()
    }

    func saveSession(_ session: Session) {
        saveSessions([session])
    }

    // MARK: - Events

    func cachedEvents(for sessionId: String) -> [SessionEvent] {
        let predicate = #Predicate<CachedEvent> { $0.sessionId == sessionId }
        let descriptor = FetchDescriptor<CachedEvent>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.seq)]
        )
        let cached = (try? context.fetch(descriptor)) ?? []
        return cached.map { $0.toSessionEvent() }
    }

    func saveEvents(_ events: [SessionEvent], for sessionId: String) {
        for event in events {
            let eventId = event.id
            let predicate = #Predicate<CachedEvent> { $0.id == eventId }
            let descriptor = FetchDescriptor<CachedEvent>(predicate: predicate)
            if (try? context.fetch(descriptor).first) == nil {
                context.insert(CachedEvent(from: event))
            }
        }
        try? context.save()
    }

    func saveEvent(_ event: SessionEvent) {
        saveEvents([event], for: event.sessionId)
    }

    // MARK: - Commands

    func cachedCommands(for sessionId: String) -> [CachedCommand] {
        let predicate = #Predicate<CachedCommand> { $0.sessionId == sessionId }
        let descriptor = FetchDescriptor<CachedCommand>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func saveCommand(_ command: CachedCommand) {
        context.insert(command)
        try? context.save()
    }

    func updateCommand(id: String, status: String, output: String? = nil, error: String? = nil) {
        let predicate = #Predicate<CachedCommand> { $0.id == id }
        let descriptor = FetchDescriptor<CachedCommand>(predicate: predicate)
        guard let cmd = try? context.fetch(descriptor).first else { return }
        cmd.statusRaw = status
        if let output { cmd.output = output }
        if let error { cmd.error = error }
        cmd.completedAt = Date()
        try? context.save()
    }

    // MARK: - Tasks

    func cachedTasks() -> [AFKTask] {
        let descriptor = FetchDescriptor<CachedTask>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let cached = (try? context.fetch(descriptor)) ?? []
        return cached.map { $0.toAFKTask() }
    }

    func saveTasks(_ tasks: [AFKTask]) {
        for task in tasks {
            let taskId = task.id
            let predicate = #Predicate<CachedTask> { $0.id == taskId }
            let descriptor = FetchDescriptor<CachedTask>(predicate: predicate)
            if let existing = try? context.fetch(descriptor).first {
                existing.update(from: task)
            } else {
                context.insert(CachedTask(from: task))
            }
        }
        try? context.save()
    }

    func saveTask(_ task: AFKTask) {
        saveTasks([task])
    }

    func deleteTask(id: String) {
        let predicate = #Predicate<CachedTask> { $0.id == id }
        let descriptor = FetchDescriptor<CachedTask>(predicate: predicate)
        guard let cached = try? context.fetch(descriptor).first else { return }
        context.delete(cached)
        try? context.save()
    }

    // MARK: - Cleanup

    func deleteOldEvents(olderThan days: Int = 30) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let predicate = #Predicate<CachedEvent> { $0.cachedAt < cutoff }
        let descriptor = FetchDescriptor<CachedEvent>(predicate: predicate)
        guard let old = try? context.fetch(descriptor) else { return }
        for event in old { context.delete(event) }
        try? context.save()
    }

    func deleteCompletedSessions(olderThan days: Int = 14) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let status = SessionStatus.completed.rawValue
        let predicate = #Predicate<CachedSession> {
            $0.statusRaw == status && $0.lastSyncedAt < cutoff
        }
        let descriptor = FetchDescriptor<CachedSession>(predicate: predicate)
        guard let old = try? context.fetch(descriptor) else { return }
        for session in old { context.delete(session) }
        try? context.save()
    }

    /// Clear all cached data (used on sign-out / account switch).
    func clearAll() {
        let sessions = (try? context.fetch(FetchDescriptor<CachedSession>())) ?? []
        for s in sessions { context.delete(s) }
        let events = (try? context.fetch(FetchDescriptor<CachedEvent>())) ?? []
        for e in events { context.delete(e) }
        let commands = (try? context.fetch(FetchDescriptor<CachedCommand>())) ?? []
        for c in commands { context.delete(c) }
        let tasks = (try? context.fetch(FetchDescriptor<CachedTask>())) ?? []
        for t in tasks { context.delete(t) }
        try? context.save()
    }
}
