//
//  AgentState.swift
//  AFK-Agent
//
//  Persistent state for Agent restart recovery.
//  Saved to ~/.afk-agent/session-state.json

import Foundation

struct AgentState: Codable {
    struct SessionSnapshot: Codable {
        let sessionId: String
        let jsonlPath: String
        var lastByteOffset: UInt64
        var lastSeq: Int
        let projectPath: String
        let createdAt: Date
    }

    var activeSessions: [String: SessionSnapshot] = [:]
    var lastSavedAt: Date = Date()

    // MARK: - Persistence

    private static var stateDirectoryURL: URL {
        URL(fileURLWithPath: BuildEnvironment.configDirectoryPath)
    }

    private static var stateFileURL: URL {
        stateDirectoryURL.appendingPathComponent("session-state.json")
    }

    static func ensureStateDirectory() {
        try? FileManager.default.createDirectory(
            at: stateDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    func save() {
        Self.ensureStateDirectory()
        var copy = self
        copy.lastSavedAt = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(copy) else { return }

        let url = Self.stateFileURL
        let tmpURL = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmpURL, options: .atomic)
            // Atomic rename
            _ = try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmpURL, to: url)
        } catch {
            print("[State] Failed to save: \(error.localizedDescription)")
        }
    }

    static func load() -> AgentState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: stateFileURL),
              let state = try? decoder.decode(AgentState.self, from: data) else {
            return AgentState()
        }
        return state
    }

    // MARK: - Mutations

    mutating func trackSession(sessionId: String, jsonlPath: String, projectPath: String) {
        guard activeSessions[sessionId] == nil else { return }
        activeSessions[sessionId] = SessionSnapshot(
            sessionId: sessionId,
            jsonlPath: jsonlPath,
            lastByteOffset: 0,
            lastSeq: 0,
            projectPath: projectPath,
            createdAt: Date()
        )
    }

    mutating func updateOffset(sessionId: String, byteOffset: UInt64) {
        activeSessions[sessionId]?.lastByteOffset = byteOffset
    }

    mutating func updateSeq(sessionId: String, seq: Int) {
        activeSessions[sessionId]?.lastSeq = seq
    }

    mutating func removeSession(_ sessionId: String) {
        activeSessions.removeValue(forKey: sessionId)
    }

    /// Returns the next seq number for a session (1-based, monotonically increasing).
    mutating func nextSeq(for sessionId: String) -> Int {
        let current = activeSessions[sessionId]?.lastSeq ?? 0
        let next = current + 1
        activeSessions[sessionId]?.lastSeq = next
        return next
    }
}
