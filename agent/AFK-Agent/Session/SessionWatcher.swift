//
//  SessionWatcher.swift
//  AFK-Agent
//

import Foundation
import CoreServices
import OSLog

actor SessionWatcher {
    private let projectsPath: String
    private var knownModDates: [String: Date] = [:]
    private let onChange: @Sendable (String) async -> Void
    private var isRunning = false
    private var streamWrapper: FSEventStreamWrapper?
    private var debounceTask: Task<Void, Never>?

    init(projectsPath: String, onChange: @escaping @Sendable (String) async -> Void) {
        self.projectsPath = projectsPath
        self.onChange = onChange
    }

    /// Seed known mod dates for all existing files so the first scan doesn't replay history.
    func seedExistingFiles() -> [String] {
        let discovered = Self.discoverJSONLFiles(in: projectsPath)
        for (path, modDate) in discovered {
            knownModDates[path] = modDate
        }
        return discovered.map(\.0)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        AppLogger.session.info("Watching \(self.projectsPath, privacy: .public)")

        let wrapper = FSEventStreamWrapper(path: projectsPath) { [weak self] in
            guard let self else { return }
            Task { await self.debouncedScan() }
        }

        if wrapper.start() {
            streamWrapper = wrapper
            AppLogger.session.info("FSEvents watcher started for \(self.projectsPath, privacy: .public)")
        } else {
            AppLogger.session.warning("FSEvents setup failed, falling back to 10s polling")
            startFallbackPolling()
        }
    }

    func stop() {
        isRunning = false
        streamWrapper?.stop()
        streamWrapper = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    // MARK: - Debounced Scan

    private func debouncedScan() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await self.scan()
        }
    }

    // MARK: - Fallback Polling

    private func startFallbackPolling() {
        Task { [weak self] in
            while let self, await self.isRunning {
                await self.scan()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    // MARK: - Scan

    private func scan() async {
        let discovered = Self.discoverJSONLFiles(in: projectsPath)

        for (path, modDate) in discovered {
            let previousDate = knownModDates[path]
            if previousDate != modDate {
                knownModDates[path] = modDate
                await onChange(path)
            }
        }
    }

    private nonisolated static func discoverJSONLFiles(in projectsPath: String) -> [(String, Date)] {
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

// MARK: - FSEvents Wrapper

/// Bridges the C-based FSEvents API to a Swift callback, running on the main RunLoop.
private final class FSEventStreamWrapper: @unchecked Sendable {
    private let path: String
    private let callback: @Sendable () -> Void
    private var stream: FSEventStreamRef?

    init(path: String, callback: @escaping @Sendable () -> Void) {
        self.path = path
        self.callback = callback
    }

    func start() -> Bool {
        let pathCF = path as CFString
        let pathsToWatch = [pathCF] as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let wrapper = Unmanaged<FSEventStreamWrapper>.fromOpaque(info).takeUnretainedValue()
                wrapper.callback()
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        ) else { return false }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }

        self.stream = stream
        return true
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
