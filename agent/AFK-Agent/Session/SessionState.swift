//
//  SessionState.swift
//  AFK-Agent
//

import Foundation

enum SessionStatus: String, Codable, Sendable {
    case initial, running, idle, waitingPermission, error, completed
}

struct ProcessResult: Sendable {
    let statusChanged: SessionStatus?
    let shouldSendUpdate: Bool
}

actor SessionStateManager {
    struct SessionInfo: Sendable {
        var status: SessionStatus = .initial
        var projectPath: String = ""
        var gitBranch: String = ""
        var cwd: String = ""
        var tokensIn: Int64 = 0
        var tokensOut: Int64 = 0
        var turnCount: Int = 0
        var description: String = ""
        var userPrompt: String = ""       // First external user message (raw, pre-encryption)
        var touchedFiles: [String] = []   // Unique file paths from Edit/Write/NotebookEdit tools
        var lastActivityAt: Date = Date()
    }

    private var sessions: [String: SessionInfo] = [:]

    func processEvent(_ event: NormalizedEvent, projectPath: String = "", cwd: String = "", gitBranch: String = "", privacyMode: String = "telemetry_only") -> ProcessResult {
        let isNew = sessions[event.sessionId] == nil
        var info = sessions[event.sessionId] ?? SessionInfo()
        let oldStatus = info.status
        let oldDescription = info.description
        info.lastActivityAt = Date()

        // Fill in project metadata from best available source
        if info.projectPath.isEmpty {
            if !cwd.isEmpty {
                info.projectPath = cwd
            } else if !projectPath.isEmpty {
                info.projectPath = projectPath
            }
        }
        if info.cwd.isEmpty && !cwd.isEmpty {
            info.cwd = cwd
        }
        if info.gitBranch.isEmpty && !gitBranch.isEmpty {
            info.gitBranch = gitBranch
        }

        switch event.eventType {
        case .sessionStarted:
            info.status = .running
            if let p = event.data["projectPath"], !p.isEmpty { info.projectPath = p }
            if let b = event.data["gitBranch"], !b.isEmpty { info.gitBranch = b }
            if let c = event.data["cwd"], !c.isEmpty { info.cwd = c }
        case .turnStarted:
            info.status = .running
            info.turnCount += 1
        case .assistantResponding:
            info.status = .running
        case .toolStarted:
            info.status = .running
        case .toolFinished:
            if info.status == .waitingPermission {
                info.status = .running
            }
        case .turnCompleted:
            info.status = .idle
        case .permissionNeeded:
            info.status = .waitingPermission
        case .errorRaised:
            info.status = .error
        case .usageUpdate:
            if let inp = event.data["inputTokens"] {
                info.tokensIn += Int64(inp) ?? 0
            }
            if let out = event.data["outputTokens"] {
                info.tokensOut += Int64(out) ?? 0
            }
        case .sessionIdle:
            info.status = .idle
        case .sessionCompleted:
            info.status = .completed
        }

        // Track touched files from write-type tools
        if event.eventType == .toolStarted,
           let toolName = event.data["toolName"],
           ["Edit", "Write", "NotebookEdit"].contains(toolName),
           let filePath = event.data["filePath"], !filePath.isEmpty {
            if !info.touchedFiles.contains(filePath) {
                info.touchedFiles.append(filePath)
            }
        }

        // Compose summary from current state
        var summaryParts: [String] = []
        if !info.userPrompt.isEmpty {
            let prompt = info.userPrompt.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            summaryParts.append(prompt.count > 80 ? String(prompt.prefix(77)) + "..." : prompt)
        }
        if !info.touchedFiles.isEmpty {
            let fileNames = Array(Set(info.touchedFiles.map { ($0 as NSString).lastPathComponent }))
            if fileNames.count <= 3 {
                summaryParts.append(fileNames.joined(separator: ", "))
            } else {
                summaryParts.append("\(fileNames.prefix(3).joined(separator: ", ")), +\(fileNames.count - 3) more")
            }
        }
        info.description = summaryParts.joined(separator: " — ")

        sessions[event.sessionId] = info

        let statusChanged = info.status != oldStatus ? info.status : nil
        let descriptionChanged = info.description != oldDescription
        let shouldSendUpdate = isNew || statusChanged != nil || descriptionChanged ||
            event.eventType == .usageUpdate || event.eventType == .turnStarted ||
            event.eventType == .turnCompleted

        return ProcessResult(statusChanged: statusChanged, shouldSendUpdate: shouldSendUpdate)
    }

    func setUserPrompt(sessionId: String, prompt: String) {
        // Only capture the first user prompt (the session's initial task)
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionInfo()
        }
        guard sessions[sessionId]!.userPrompt.isEmpty else { return }
        // Strip XML/HTML tags (e.g. <local-command-caveat>, <system-reminder>) from prompt
        let cleaned = prompt.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[sessionId]?.userPrompt = cleaned
    }

    func getInfo(_ sessionId: String) -> SessionInfo? {
        sessions[sessionId]
    }

    func allSessions() -> [String: SessionInfo] {
        sessions
    }

    func checkTimeouts(idleTimeout: TimeInterval, completedTimeout: TimeInterval) -> [NormalizedEvent] {
        var events: [NormalizedEvent] = []
        let now = Date()
        for (sessionId, info) in sessions {
            let elapsed = now.timeIntervalSince(info.lastActivityAt)
            if info.status == .running && elapsed > idleTimeout {
                events.append(NormalizedEvent(sessionId: sessionId, eventType: .sessionIdle))
            }
            if info.status == .idle && elapsed > completedTimeout {
                events.append(NormalizedEvent(sessionId: sessionId, eventType: .sessionCompleted))
            }
        }
        return events
    }
}
