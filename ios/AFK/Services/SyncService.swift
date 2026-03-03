import Foundation
import OSLog

@MainActor
final class SyncService {
    private let apiClient: APIClient
    private let localStore: LocalStore

    init(apiClient: APIClient, localStore: LocalStore) {
        self.apiClient = apiClient
        self.localStore = localStore
    }

    /// Sync sessions from API and merge with local cache.
    /// Returns merged sessions (local-first, updated with remote).
    func syncSessions() async -> [Session] {
        do {
            let remote = try await apiClient.listSessions()
            let filtered = remote.filter {
                !$0.projectPath.isEmpty || $0.status == .running || $0.status == .idle || $0.status == .waitingPermission
            }
            localStore.saveSessions(filtered)
            return filtered
        } catch {
            AppLogger.sync.error("Failed to sync sessions: \(error, privacy: .public)")
            // Return cached data on failure
            return localStore.cachedSessions()
        }
    }

    /// Sync events for a session from API.
    func syncEvents(for sessionId: String) async -> (events: [SessionEvent], hasMore: Bool) {
        do {
            let (remote, hasMore) = try await apiClient.getSessionEvents(sessionId: sessionId)
            localStore.saveEvents(remote, for: sessionId)
            return (remote, hasMore)
        } catch {
            AppLogger.sync.error("Failed to sync events for \(sessionId.prefix(8), privacy: .public): \(error, privacy: .public)")
            return (localStore.cachedEvents(for: sessionId), false)
        }
    }

    /// Periodic cleanup of old cached data.
    func performMaintenance() {
        localStore.deleteOldEvents(olderThan: 30)
        localStore.deleteCompletedSessions(olderThan: 14)
    }
}
