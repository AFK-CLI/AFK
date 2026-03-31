//
//  OpenCodeSQLiteWatcher.swift
//  AFK-Agent
//

import Foundation
import OSLog
import SQLite3

/// Watches the centralized OpenCode SQLite database for new parts.
/// OpenCode stores everything in a single DB at ~/.local/share/opencode/opencode.db.
/// Parts are in a separate `part` table, joined to `message` for role and `session` for project path.
actor OpenCodeSQLiteWatcher {
    private let dbPath: String
    private let pollInterval: TimeInterval
    private let onChange: @Sendable ([OpenCodePart]) async -> Void

    private var lastRowId: Int64 = 0
    private var isRunning = false
    private var scanTask: Task<Void, Never>?

    /// Session directory cache: sessionId -> projectPath (from session.directory)
    private var sessionDirCache: [String: String] = [:]

    init(
        pollInterval: TimeInterval,
        onChange: @escaping @Sendable ([OpenCodePart]) async -> Void
    ) {
        let home = NSHomeDirectory()
        self.dbPath = home + "/.local/share/opencode/opencode.db"
        self.pollInterval = pollInterval
        self.onChange = onChange
    }

    func start() {
        guard !isRunning else { return }

        guard FileManager.default.fileExists(atPath: dbPath) else {
            AppLogger.agent.info("OpenCode: database not found at \(self.dbPath, privacy: .public)")
            return
        }

        isRunning = true
        AppLogger.agent.info("OpenCode: watching \(self.dbPath, privacy: .public)")

        scanTask = Task { [weak self] in
            while let self, await self.isRunning {
                await self.poll()
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    func stop() {
        isRunning = false
        scanTask?.cancel()
        scanTask = nil
    }

    // MARK: - Discovery

    func discoverExistingSessions() -> [(sessionId: String, projectPath: String)] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT id, directory FROM session WHERE parent_id IS NULL ORDER BY time_created DESC LIMIT 100"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [(String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = columnText(stmt, 0)
            let dir = columnText(stmt, 1)
            sessionDirCache[id] = dir
            results.append((id, dir))
        }
        return results
    }

    func sessionExists(sessionId: String) -> Bool {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else { return false }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM session WHERE id = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // MARK: - Offset Management

    func fastForward() {
        lastRowId = maxPartRowId()
        AppLogger.agent.info("OpenCode: fast-forwarded to rowid \(self.lastRowId, privacy: .public)")
    }

    func setOffset(_ offset: Int64) {
        lastRowId = offset
    }

    func currentOffset() -> Int64 {
        lastRowId
    }

    var databasePath: String { dbPath }

    // MARK: - Polling

    private func poll() async {
        let parts = queryNewParts(afterRowId: lastRowId)
        if !parts.isEmpty {
            if let maxId = parts.map(\.rowId).max() {
                lastRowId = maxId
            }
            await onChange(parts)
        }
    }

    // MARK: - SQLite Queries

    /// Query new parts joined with message (for role) and session (for directory).
    private func queryNewParts(afterRowId: Int64) -> [OpenCodePart] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = """
            SELECT p.rowid, p.id, p.message_id, p.session_id, p.data, p.time_created,
                   m.data, s.directory
            FROM part p
            JOIN message m ON p.message_id = m.id
            JOIN session s ON p.session_id = s.id
            WHERE p.rowid > ?
            ORDER BY p.rowid ASC
            LIMIT 500
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, afterRowId)

        var parts: [OpenCodePart] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowId = sqlite3_column_int64(stmt, 0)
            let partId = columnText(stmt, 1)
            let messageId = columnText(stmt, 2)
            let sessionId = columnText(stmt, 3)
            let partDataJSON = columnText(stmt, 4)
            let createdAtMs = sqlite3_column_int64(stmt, 5)
            let messageDataJSON = columnText(stmt, 6)
            let directory = columnText(stmt, 7)

            // Parse role and model from message.data JSON
            var role = "unknown"
            var model: String?
            if let msgData = messageDataJSON.data(using: .utf8),
               let msgDict = try? JSONSerialization.jsonObject(with: msgData) as? [String: Any] {
                role = msgDict["role"] as? String ?? "unknown"
                model = msgDict["modelID"] as? String
            }

            // Cache directory for this session
            if !directory.isEmpty {
                sessionDirCache[sessionId] = directory
            }

            let content = OpenCodePartParser.parse(partDataJSON)
            let createdAt = Date(timeIntervalSince1970: Double(createdAtMs) / 1000.0)

            parts.append(OpenCodePart(
                rowId: rowId,
                partId: partId,
                messageId: messageId,
                sessionId: sessionId,
                role: role,
                projectPath: directory,
                model: model,
                content: content,
                createdAt: createdAt
            ))
        }

        return parts
    }

    private nonisolated func maxPartRowId() -> Int64 {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT MAX(rowid) FROM part"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
    }

    // MARK: - Helpers

    private nonisolated func columnText(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        if let cstr = sqlite3_column_text(stmt, col) {
            return String(cString: cstr)
        }
        return ""
    }
}
