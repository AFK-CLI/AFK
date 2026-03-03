//
//  SessionWatcher.swift
//  AFK-Agent
//

import Foundation
import OSLog

actor SessionWatcher {
    private let projectsPath: String
    private var knownModDates: [String: Date] = [:]
    private let onChange: @Sendable (String) async -> Void
    private var isRunning = false

    init(projectsPath: String, onChange: @escaping @Sendable (String) async -> Void) {
        self.projectsPath = projectsPath
        self.onChange = onChange
    }

    /// Seed known mod dates for all existing files so the first scan doesn't replay history.
    func seedExistingFiles() -> [String] {
        let discovered = discoverJSONLFiles()
        for (path, modDate) in discovered {
            knownModDates[path] = modDate
        }
        return discovered.map(\.0)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        AppLogger.session.info("Watching \(self.projectsPath, privacy: .public)")

        Task { [weak self] in
            while let self, await self.isRunning {
                await self.scan()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        isRunning = false
    }

    private func scan() async {
        // Collect file info synchronously to avoid async iterator warning
        let discovered = discoverJSONLFiles()

        for (path, modDate) in discovered {
            let previousDate = knownModDates[path]
            if previousDate != modDate {
                knownModDates[path] = modDate
                await onChange(path)
            }
        }
    }

    private nonisolated func discoverJSONLFiles() -> [(String, Date)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: projectsPath),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [(String, Date)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            if let modDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                results.append((fileURL.path, modDate))
            }
        }
        return results
    }
}
