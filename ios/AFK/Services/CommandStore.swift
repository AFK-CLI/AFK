import Foundation

@Observable
final class CommandStore {
    struct CommandState {
        let id: String
        let sessionId: String
        let prompt: String?
        var chunks: [String] = []
        var isComplete: Bool = false
        var isCancelled: Bool = false
        var isCompact: Bool = false
        var error: String?
        var durationMs: Int?
        var costUsd: Double?
        var newSessionId: String?
        let startedAt: Date = Date()
    }

    var activeCommands: [String: CommandState] = [:]  // sessionId -> state
    var commandHistory: [String: [CommandState]] = [:]  // sessionId -> past commands
    var compactCompletedSessionId: String?  // set when a compact command finishes
    var compactStartEventCount: Int?  // event array count when compact was initiated

    func startCommand(id: String, sessionId: String, prompt: String? = nil) {
        activeCommands[sessionId] = CommandState(id: id, sessionId: sessionId, prompt: prompt)
    }

    func appendChunk(sessionId: String, text: String) {
        activeCommands[sessionId]?.chunks.append(text)
    }

    func completeCommand(sessionId: String, durationMs: Int? = nil, costUsd: Double? = nil, newSessionId: String? = nil) {
        activeCommands[sessionId]?.durationMs = durationMs
        activeCommands[sessionId]?.costUsd = costUsd
        activeCommands[sessionId]?.newSessionId = newSessionId
        activeCommands[sessionId]?.isComplete = true
        if activeCommands[sessionId]?.isCompact == true {
            compactCompletedSessionId = sessionId
        }
        archiveCommand(sessionId: sessionId)
    }

    func failCommand(sessionId: String, error: String) {
        activeCommands[sessionId]?.error = error
        activeCommands[sessionId]?.isComplete = true
        archiveCommand(sessionId: sessionId)
    }

    func cancelCommand(sessionId: String) {
        activeCommands[sessionId]?.isCancelled = true
        activeCommands[sessionId]?.isComplete = true
        archiveCommand(sessionId: sessionId)
    }

    func clearCommand(sessionId: String) {
        activeCommands.removeValue(forKey: sessionId)
    }

    func activeCommand(for sessionId: String) -> CommandState? {
        guard let cmd = activeCommands[sessionId], !cmd.isComplete else { return nil }
        return cmd
    }

    func completedCommand(for sessionId: String) -> CommandState? {
        guard let cmd = activeCommands[sessionId], cmd.isComplete else { return nil }
        return cmd
    }

    func history(for sessionId: String) -> [CommandState] {
        commandHistory[sessionId] ?? []
    }

    private func archiveCommand(sessionId: String) {
        guard let cmd = activeCommands[sessionId] else { return }
        var history = commandHistory[sessionId] ?? []
        history.insert(cmd, at: 0)
        // Keep last 50 commands per session
        if history.count > 50 { history = Array(history.prefix(50)) }
        commandHistory[sessionId] = history
    }
}
