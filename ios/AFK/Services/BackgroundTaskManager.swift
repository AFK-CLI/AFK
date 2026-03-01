import Foundation
import BackgroundTasks
import UIKit

@MainActor
final class BackgroundTaskManager {
    static let sessionRefreshIdentifier = (Bundle.main.bundleIdentifier ?? "com.afk.app") + ".session-refresh"

    private let syncService: SyncService
    private var onSessionsRefreshed: (([Session]) -> Void)?

    init(syncService: SyncService) {
        self.syncService = syncService
    }

    func registerTasks(onSessionsRefreshed: @escaping ([Session]) -> Void) {
        self.onSessionsRefreshed = onSessionsRefreshed
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.sessionRefreshIdentifier,
            using: .main
        ) { [weak self] task in
            guard let bgTask = task as? BGAppRefreshTask else { return }
            Task { @MainActor [weak self] in
                await self?.handleRefresh(bgTask)
            }
        }
    }

    func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.sessionRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[BGTask] Scheduled session refresh")
        } catch {
            print("[BGTask] Failed to schedule refresh: \(error)")
        }
    }

    func cancelPendingTasks() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.sessionRefreshIdentifier)
    }

    private func handleRefresh(_ task: BGAppRefreshTask) async {
        // Schedule next refresh before starting work
        scheduleRefresh()

        task.expirationHandler = {
            print("[BGTask] Refresh task expired")
        }

        let sessions = await syncService.syncSessions()
        onSessionsRefreshed?(sessions)
        syncService.performMaintenance()
        task.setTaskCompleted(success: true)
        print("[BGTask] Refresh completed with \(sessions.count) sessions")
    }
}
