//
//  MessageEncoder.swift
//  AFK-Agent
//

import Foundation

struct MessageEncoder {
    static func heartbeat(deviceID: String, activeSessions: [String]) throws -> WSMessage {
        let payload = AgentHeartbeat(
            deviceId: deviceID,
            uptime: Int64(ProcessInfo.processInfo.systemUptime),
            activeSessions: activeSessions
        )
        return try WSMessage(type: "agent.heartbeat", payload: payload)
    }

    static func sessionUpdate(
        sessionId: String,
        projectPath: String,
        gitBranch: String,
        cwd: String,
        status: String,
        tokensIn: Int64,
        tokensOut: Int64,
        turnCount: Int,
        description: String,
        ephemeralPublicKey: String? = nil
    ) throws -> WSMessage {
        let payload = AgentSessionUpdate(
            sessionId: sessionId,
            projectPath: projectPath,
            gitBranch: gitBranch,
            cwd: cwd,
            status: status,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            turnCount: turnCount,
            description: description,
            ephemeralPublicKey: ephemeralPublicKey
        )
        return try WSMessage(type: "agent.session.update", payload: payload)
    }

    static func sessionEvent(sessionId: String, event: NormalizedEvent, seq: Int = 0) throws -> WSMessage {
        let payload = AgentSessionEvent(
            sessionId: sessionId,
            eventType: event.eventType.rawValue,
            data: event.data,
            content: event.content,
            seq: seq
        )
        return try WSMessage(type: "agent.session.event", payload: payload)
    }

    static func sessionCompleted(sessionId: String) throws -> WSMessage {
        let payload = AgentSessionCompleted(sessionId: sessionId)
        return try WSMessage(type: "agent.session.completed", payload: payload)
    }

    static func permissionRequest(event: PermissionSocket.PermissionRequestEvent) throws -> WSMessage {
        return try WSMessage(type: "agent.permission_request", payload: event)
    }

    static func commandAck(commandId: String, sessionId: String) throws -> WSMessage {
        let payload = CommandAckPayload(commandId: commandId, sessionId: sessionId)
        return try WSMessage(type: "agent.command.ack", payload: payload)
    }

    static func commandChunk(commandId: String, sessionId: String, text: String, seq: Int) throws -> WSMessage {
        let payload = CommandChunkPayload(commandId: commandId, sessionId: sessionId, text: text, seq: seq)
        return try WSMessage(type: "agent.command.chunk", payload: payload)
    }

    static func commandDone(commandId: String, sessionId: String, durationMs: Int? = nil, costUsd: Double? = nil, newSessionId: String? = nil) throws -> WSMessage {
        let payload = CommandDonePayload(commandId: commandId, sessionId: sessionId, durationMs: durationMs, costUsd: costUsd, newSessionId: newSessionId)
        return try WSMessage(type: "agent.command.done", payload: payload)
    }

    static func commandFailed(commandId: String, sessionId: String, error: String) throws -> WSMessage {
        let payload = CommandFailedPayload(commandId: commandId, sessionId: sessionId, error: error)
        return try WSMessage(type: "agent.command.failed", payload: payload)
    }

    static func commandCancelled(commandId: String, sessionId: String) throws -> WSMessage {
        let payload = CommandCancelledPayload(commandId: commandId, sessionId: sessionId)
        return try WSMessage(type: "agent.command.cancelled", payload: payload)
    }

    static func controlState(deviceID: String, remoteApproval: Bool, autoPlanExit: Bool) throws -> WSMessage {
        let payload = AgentControlStatePayload(deviceId: deviceID, remoteApproval: remoteApproval, autoPlanExit: autoPlanExit)
        return try WSMessage(type: "agent.control_state", payload: payload)
    }

    static func todoSync(
        projectPath: String,
        contentHash: String,
        rawContent: String,
        items: [(text: String, checked: Bool, line: Int)]
    ) throws -> WSMessage {
        let wireItems = items.map { AgentTodoItem(text: $0.text, checked: $0.checked, line: $0.line) }
        let payload = AgentTodoSyncPayload(
            projectPath: projectPath,
            contentHash: contentHash,
            rawContent: rawContent,
            items: wireItems
        )
        return try WSMessage(type: "agent.todo.sync", payload: payload)
    }
}

struct AgentHeartbeat: Codable, Sendable {
    let deviceId: String
    let uptime: Int64
    let activeSessions: [String]
}

struct AgentSessionUpdate: Codable, Sendable {
    let sessionId: String
    let projectPath: String
    let gitBranch: String
    let cwd: String
    let status: String
    let tokensIn: Int64
    let tokensOut: Int64
    let turnCount: Int
    let description: String
    let ephemeralPublicKey: String?
}

struct AgentSessionEvent: Codable, Sendable {
    let sessionId: String
    let eventType: String
    let data: [String: String]
    let content: [String: String]?
    let seq: Int
}

struct AgentSessionCompleted: Codable, Sendable {
    let sessionId: String
}

struct CommandAckPayload: Codable, Sendable {
    let commandId: String
    let sessionId: String
}

struct CommandChunkPayload: Codable, Sendable {
    let commandId: String
    let sessionId: String
    let text: String
    let seq: Int
}

struct CommandDonePayload: Codable, Sendable {
    let commandId: String
    let sessionId: String
    let durationMs: Int?
    let costUsd: Double?
    let newSessionId: String?
}

struct CommandFailedPayload: Codable, Sendable {
    let commandId: String
    let sessionId: String
    let error: String
}

struct CommandCancelledPayload: Codable, Sendable {
    let commandId: String
    let sessionId: String
}

struct AgentControlStatePayload: Codable, Sendable {
    let deviceId: String
    let remoteApproval: Bool
    let autoPlanExit: Bool
}

struct AgentTodoItem: Codable, Sendable {
    let text: String
    let checked: Bool
    let line: Int
}

struct AgentTodoSyncPayload: Codable, Sendable {
    let projectPath: String
    let contentHash: String
    let rawContent: String
    let items: [AgentTodoItem]
}
