import Foundation
import SwiftData

@Model
final class CachedSession {
    @Attribute(.unique) var id: String
    var deviceId: String
    var userId: String
    var projectPath: String
    var gitBranch: String
    var cwd: String
    var statusRaw: String
    var startedAt: Date?
    var updatedAt: Date?
    var tokensIn: Int64
    var tokensOut: Int64
    var turnCount: Int
    var deviceName: String?
    var projectId: String?
    var sessionDescription: String = ""
    var ephemeralPublicKey: String?
    var costUsd: Double = 0
    var lastModel: String?
    var otlpCacheReadTokens: Int64 = 0
    var otlpCacheCreationTokens: Int64 = 0
    var lastSyncedAt: Date

    init(from session: Session) {
        self.id = session.id
        self.deviceId = session.deviceId
        self.userId = session.userId
        self.projectPath = session.projectPath
        self.gitBranch = session.gitBranch
        self.cwd = session.cwd
        self.statusRaw = session.status.rawValue
        self.startedAt = session.startedAt
        self.updatedAt = session.updatedAt
        self.tokensIn = session.tokensIn
        self.tokensOut = session.tokensOut
        self.turnCount = session.turnCount
        self.deviceName = session.deviceName
        self.projectId = session.projectId
        self.sessionDescription = session.description
        self.ephemeralPublicKey = session.ephemeralPublicKey
        self.costUsd = session.costUsd
        self.lastModel = session.lastModel
        self.otlpCacheReadTokens = session.otlpCacheReadTokens
        self.otlpCacheCreationTokens = session.otlpCacheCreationTokens
        self.lastSyncedAt = Date()
    }

    func toSession() -> Session {
        Session(
            id: id,
            deviceId: deviceId,
            userId: userId,
            projectPath: projectPath,
            gitBranch: gitBranch,
            cwd: cwd,
            status: SessionStatus(rawValue: statusRaw) ?? .idle,
            startedAt: startedAt,
            updatedAt: updatedAt,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            turnCount: turnCount,
            deviceName: deviceName,
            projectId: projectId,
            description: sessionDescription,
            ephemeralPublicKey: ephemeralPublicKey,
            costUsd: costUsd,
            lastModel: lastModel,
            otlpCacheReadTokens: otlpCacheReadTokens,
            otlpCacheCreationTokens: otlpCacheCreationTokens
        )
    }

    func update(from session: Session) {
        deviceId = session.deviceId
        userId = session.userId
        projectPath = session.projectPath
        gitBranch = session.gitBranch
        cwd = session.cwd
        statusRaw = session.status.rawValue
        startedAt = session.startedAt
        updatedAt = session.updatedAt
        tokensIn = session.tokensIn
        tokensOut = session.tokensOut
        turnCount = session.turnCount
        deviceName = session.deviceName
        projectId = session.projectId
        sessionDescription = session.description
        ephemeralPublicKey = session.ephemeralPublicKey
        costUsd = session.costUsd
        lastModel = session.lastModel
        otlpCacheReadTokens = session.otlpCacheReadTokens
        otlpCacheCreationTokens = session.otlpCacheCreationTokens
        lastSyncedAt = Date()
    }
}
