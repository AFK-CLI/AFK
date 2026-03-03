import Foundation
import OSLog

@Observable
final class LogUploader {
    static let shared = LogUploader()

    private var apiClient: APIClient?
    private var deviceId: String = ""
    private(set) var isUploading = false
    private(set) var lastShareCount = 0
    private(set) var bufferedCount = 0
    /// Timestamp of last successful share so we only upload new entries next time.
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
        guard !entries.isEmpty else {
            lastShareCount = 0
            return 0
        }

        var uploaded = 0
        for batchStart in stride(from: 0, to: entries.count, by: 100) {
            let batch = Array(entries[batchStart..<min(batchStart + 100, entries.count)])
            do {
                try await apiClient.uploadLogs(batch)
                uploaded += batch.count
            } catch {
                AppLogger.app.error("Log share failed: \(error.localizedDescription)")
                break
            }
        }

        if uploaded > 0 {
            lastShareDate = Date()
        }
        lastShareCount = uploaded
        bufferedCount = 0
        return uploaded
    }

    /// Refresh the buffered log count off the main thread.
    func refreshBufferedCount() async {
        let count = collectFromOSLog().count
        bufferedCount = count
    }

    private func collectFromOSLog() -> [AppLogUploadEntry] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = lastShareDate ?? Date().addingTimeInterval(-3600)
            let position = store.position(date: since)
            let predicate = NSPredicate(format: "subsystem == %@", AppLogger.subsystem)
            let osEntries = try store.getEntries(at: position, matching: predicate)

            var result: [AppLogUploadEntry] = []
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
                result.append(AppLogUploadEntry(
                    deviceId: deviceId,
                    source: "ios",
                    level: level,
                    subsystem: logEntry.category,
                    message: String(logEntry.composedMessage.prefix(4096)),
                    metadata: nil
                ))
            }
            return result
        } catch {
            AppLogger.app.error("Failed to read OSLogStore: \(error.localizedDescription)")
            return []
        }
    }
}
