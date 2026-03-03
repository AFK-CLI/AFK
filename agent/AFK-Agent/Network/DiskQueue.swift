//
//  DiskQueue.swift
//  AFK-Agent
//

import Foundation
import OSLog

/// Disk-backed FIFO queue for offline WebSocket messages.
///
/// Binary format: length-prefixed records — `[UInt32 big-endian length][N bytes Data]` per message.
/// Append-only writes are crash-safe on APFS.
final class DiskQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let filePath: URL
    private var fileHandle: FileHandle?
    private var _count: Int = 0
    private var _fileSize: UInt64 = 0

    static let maxMessages = 100_000
    static let maxFileSize: UInt64 = 500 * 1024 * 1024  // 500 MB
    static let flushBatchSize = 50

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _count
    }

    init(directory: URL) {
        self.directory = directory
        self.filePath = directory.appendingPathComponent("queue.bin")

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Open or create queue file and recover state
        if FileManager.default.fileExists(atPath: filePath.path) {
            let recovered = Self.recoverFile(at: filePath)
            _count = recovered.count
            _fileSize = recovered.fileSize
            if recovered.truncated {
                AppLogger.queue.warning("Truncated partial trailing record during recovery")
            }
        } else {
            FileManager.default.createFile(atPath: filePath.path, contents: nil)
            _count = 0
            _fileSize = 0
        }

        fileHandle = FileHandle(forUpdatingAtPath: filePath.path)
        fileHandle?.seekToEndOfFile()

        if _count > 0 {
            AppLogger.queue.info("Recovered \(self._count, privacy: .public) pending messages (\(ByteCountFormatter.string(fromByteCount: Int64(self._fileSize), countStyle: .file), privacy: .public))")
        }
    }

    /// Append a message to the queue file.
    func enqueue(_ data: Data) {
        // Overflow protection: drop oldest if at capacity (before acquiring lock for write)
        let needsDrop: Bool = {
            lock.lock(); defer { lock.unlock() }
            return _count >= Self.maxMessages || _fileSize >= Self.maxFileSize
        }()

        if needsDrop {
            let dropCount = max(1, count / 10)  // drop 10% to avoid repeated rewrite
            dropOldest(dropCount)
        }

        lock.lock(); defer { lock.unlock() }
        guard let handle = fileHandle else { return }

        // Write length prefix (UInt32 big-endian) + data
        var length = UInt32(data.count).bigEndian
        let header = Data(bytes: &length, count: 4)
        handle.write(header)
        handle.write(data)

        _count += 1
        _fileSize += UInt64(4 + data.count)
    }

    /// Read all records, send in batches via the closure, then compact the file.
    /// Returns the number of successfully sent messages.
    @discardableResult
    func flushAll(send: (Data) async throws -> Void) async -> Int {
        // Read all records synchronously, then release lock before async sending
        let records = readAllSynchronized()
        guard !records.isEmpty else { return 0 }

        let total = records.count
        AppLogger.queue.info("Flushing \(total, privacy: .public) queued messages from disk...")

        var sent = 0
        for (index, record) in records.enumerated() {
            do {
                try await send(record)
                sent += 1
            } catch {
                AppLogger.queue.error("Flush interrupted after \(sent, privacy: .public)/\(total, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // Rewrite file with remaining unsent records
                let remaining = Array(records[index...])
                rewriteFile(with: remaining)
                return sent
            }

            // Yield between batches to avoid actor starvation
            if sent % Self.flushBatchSize == 0 {
                await Task.yield()
            }
        }

        // All sent — compact (delete and recreate empty file)
        compact()
        AppLogger.queue.info("Flushed all \(sent, privacy: .public) queued messages")
        return sent
    }

    /// Delete the queue file and reset state.
    func purge() {
        lock.lock(); defer { lock.unlock() }
        fileHandle?.closeFile()
        fileHandle = nil
        try? FileManager.default.removeItem(at: filePath)
        FileManager.default.createFile(atPath: filePath.path, contents: nil)
        fileHandle = FileHandle(forUpdatingAtPath: filePath.path)
        _count = 0
        _fileSize = 0
        AppLogger.queue.info("Purged")
    }

    /// Close the file handle (call on shutdown).
    func close() {
        lock.lock(); defer { lock.unlock() }
        fileHandle?.closeFile()
        fileHandle = nil
    }

    // MARK: - Private

    /// Thread-safe read of all records (for use before async work).
    private func readAllSynchronized() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        guard _count > 0 else { return [] }
        return (try? Self.readAllRecords(at: filePath)) ?? []
    }

    /// Rewrite the file with only the given records, updating state.
    private func rewriteFile(with records: [Data]) {
        lock.lock(); defer { lock.unlock() }

        fileHandle?.closeFile()
        fileHandle = nil

        // Write all records to a temp file, then atomic-move
        let tmpPath = filePath.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmpPath.path, contents: nil)
        guard let tmpHandle = FileHandle(forWritingAtPath: tmpPath.path) else { return }

        var newSize: UInt64 = 0
        for record in records {
            var length = UInt32(record.count).bigEndian
            let header = Data(bytes: &length, count: 4)
            tmpHandle.write(header)
            tmpHandle.write(record)
            newSize += UInt64(4 + record.count)
        }
        tmpHandle.closeFile()

        do {
            _ = try FileManager.default.replaceItemAt(filePath, withItemAt: tmpPath)
        } catch {
            // Fallback: remove original and rename
            try? FileManager.default.removeItem(at: filePath)
            try? FileManager.default.moveItem(at: tmpPath, to: filePath)
        }

        fileHandle = FileHandle(forUpdatingAtPath: filePath.path)
        fileHandle?.seekToEndOfFile()
        _count = records.count
        _fileSize = newSize
    }

    /// Delete file and recreate empty.
    private func compact() {
        lock.lock(); defer { lock.unlock() }

        fileHandle?.closeFile()
        fileHandle = nil
        try? FileManager.default.removeItem(at: filePath)
        FileManager.default.createFile(atPath: filePath.path, contents: nil)
        fileHandle = FileHandle(forUpdatingAtPath: filePath.path)
        _count = 0
        _fileSize = 0
    }

    /// Drop the oldest N records by rewriting the file.
    private func dropOldest(_ n: Int) {
        // Read records under lock
        let records: [Data] = {
            lock.lock(); defer { lock.unlock() }
            guard _count > 0 else { return [] }
            return (try? Self.readAllRecords(at: filePath)) ?? []
        }()
        guard !records.isEmpty else { return }

        let dropCount = min(n, records.count)
        let remaining = Array(records.dropFirst(dropCount))
        AppLogger.queue.warning("Overflow: dropping \(dropCount, privacy: .public) oldest messages")
        rewriteFile(with: remaining)
    }

    // MARK: - Static helpers

    /// Scan the file, count valid records, and truncate any partial trailing record.
    private static func recoverFile(at path: URL) -> (count: Int, fileSize: UInt64, truncated: Bool) {
        guard let data = try? Data(contentsOf: path) else {
            return (0, 0, false)
        }

        var offset = 0
        var count = 0
        var lastValidOffset = 0

        while offset + 4 <= data.count {
            let length = data[offset..<offset+4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            let recordEnd = offset + 4 + Int(length)

            if recordEnd > data.count {
                // Partial record — truncate here
                break
            }

            count += 1
            lastValidOffset = recordEnd
            offset = recordEnd
        }

        let truncated = lastValidOffset < data.count
        if truncated {
            // Truncate file to last valid record boundary
            if let handle = FileHandle(forWritingAtPath: path.path) {
                handle.truncateFile(atOffset: UInt64(lastValidOffset))
                handle.closeFile()
            }
        }

        return (count, UInt64(lastValidOffset), truncated)
    }

    /// Read all valid records from the file.
    private static func readAllRecords(at path: URL) throws -> [Data] {
        let data = try Data(contentsOf: path)
        var records: [Data] = []
        var offset = 0

        while offset + 4 <= data.count {
            let length = data[offset..<offset+4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            let recordEnd = offset + 4 + Int(length)
            guard recordEnd <= data.count else { break }

            records.append(data[offset+4..<recordEnd])
            offset = recordEnd
        }

        return records
    }
}
