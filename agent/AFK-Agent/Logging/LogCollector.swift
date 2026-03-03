import Foundation
import OSLog

actor LogCollector {
    private var apiClient: APIClient?
    private var deviceId: String = ""
    private(set) var isUploading = false
    private(set) var bufferedCount = 0
    private var lastShareDate: Date?

    func configure(apiClient: APIClient, deviceId: String) {
        self.apiClient = apiClient
        self.deviceId = deviceId
    }

    /// Collect recent logs from OSLogStore and upload to backend.
    /// Returns the number of entries uploaded.
    @discardableResult
    func shareAll() async -> Int {
        guard let apiClient else { return 0 }
        isUploading = true
        defer { isUploading = false }

        let entries = collectFromOSLog()
        guard !entries.isEmpty else { return 0 }

        var uploaded = 0
        for batchStart in stride(from: 0, to: entries.count, by: 100) {
            let batch = Array(entries[batchStart..<min(batchStart + 100, entries.count)])
            do {
                try await apiClient.uploadLogs(batch)
                uploaded += batch.count
            } catch {
                AppLogger.agent.error("Log share failed: \(error.localizedDescription)")
                break
            }
        }

        if uploaded > 0 {
            lastShareDate = Date()
        }
        bufferedCount = 0
        return uploaded
    }

    func refreshBufferedCount() {
        bufferedCount = collectFromOSLog().count
    }

    private func collectFromOSLog() -> [LogUploadEntry] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = lastShareDate ?? Date().addingTimeInterval(-3600)
            let position = store.position(date: since)
            let predicate = NSPredicate(format: "subsystem == %@", AppLogger.subsystem)
            let osEntries = try store.getEntries(at: position, matching: predicate)

            var result: [LogUploadEntry] = []
            for entry in osEntries {
                guard let logEntry = entry as? OSLogEntryLog else { continue }
                let level: String
                switch logEntry.level {
                case .debug: level = "debug"
                case .error: level = "error"
                case .fault: level = "error"
                case .info: level = "info"
                case .notice: level = "info"
                default: level = "info"
                }
                result.append(LogUploadEntry(
                    deviceId: deviceId,
                    source: "agent",
                    level: level,
                    subsystem: logEntry.category,
                    message: String(logEntry.composedMessage.prefix(4096)),
                    metadata: nil
                ))
            }
            return result
        } catch {
            AppLogger.agent.error("Failed to read OSLogStore: \(error.localizedDescription)")
            return []
        }
    }
}
