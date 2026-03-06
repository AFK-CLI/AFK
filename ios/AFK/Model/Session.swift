import SwiftUI

enum SessionStatus: String, Codable, Sendable {
    case running
    case idle
    case waitingInput = "waiting_input"
    case waitingPermission = "waiting_permission"
    case error
    case completed

    var displayName: String {
        switch self {
        case .running: "Running"
        case .idle: "Idle"
        case .waitingInput: "Waiting for Input"
        case .waitingPermission: "Waiting for Permission"
        case .error: "Error"
        case .completed: "Completed"
        }
    }

    var iconName: String {
        switch self {
        case .running: "play.circle.fill"
        case .idle: "pause.circle.fill"
        case .waitingInput: "keyboard"
        case .waitingPermission: "lock.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .completed: "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .running: .green
        case .idle: .yellow
        case .waitingInput: .orange
        case .waitingPermission: .orange
        case .error: .red
        case .completed: .gray
        }
    }

    /// Sort priority for the Now tab (lower = higher priority).
    var nowTabPriority: Int {
        switch self {
        case .running: 0
        case .waitingPermission: 1
        case .waitingInput: 2
        case .idle: 3
        case .error: 4
        case .completed: 5
        }
    }
}

struct Session: Codable, Identifiable, Sendable {
    let id: String
    let deviceId: String
    let userId: String
    var projectPath: String
    var gitBranch: String
    var cwd: String
    var status: SessionStatus
    let startedAt: Date?
    var updatedAt: Date?
    var tokensIn: Int64
    var tokensOut: Int64
    var turnCount: Int
    var deviceName: String?
    var projectId: String?
    var description: String = ""
    var ephemeralPublicKey: String?
    var costUsd: Double = 0
    var lastModel: String?
    var otlpCacheReadTokens: Int64 = 0
    var otlpCacheCreationTokens: Int64 = 0

    /// Resolves worktree paths to their parent project path.
    /// e.g. `/path/to/AFK/.claude/worktrees/xyz` → `/path/to/AFK`
    var resolvedProjectPath: String {
        if let range = projectPath.range(of: "/.claude/worktrees/") {
            return String(projectPath[projectPath.startIndex..<range.lowerBound])
        }
        return projectPath
    }

    var projectName: String {
        if projectPath.isEmpty { return "Untitled Session" }
        return URL(fileURLWithPath: resolvedProjectPath).lastPathComponent
    }

    init(id: String, deviceId: String, userId: String, projectPath: String, gitBranch: String,
         cwd: String, status: SessionStatus, startedAt: Date?, updatedAt: Date?,
         tokensIn: Int64, tokensOut: Int64, turnCount: Int,
         deviceName: String? = nil, projectId: String? = nil, description: String = "",
         ephemeralPublicKey: String? = nil, costUsd: Double = 0,
         lastModel: String? = nil, otlpCacheReadTokens: Int64 = 0, otlpCacheCreationTokens: Int64 = 0) {
        self.id = id
        self.deviceId = deviceId
        self.userId = userId
        self.projectPath = projectPath
        self.gitBranch = gitBranch
        self.cwd = cwd
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.turnCount = turnCount
        self.deviceName = deviceName
        self.projectId = projectId
        self.description = description
        self.ephemeralPublicKey = ephemeralPublicKey
        self.costUsd = costUsd
        self.lastModel = lastModel
        self.otlpCacheReadTokens = otlpCacheReadTokens
        self.otlpCacheCreationTokens = otlpCacheCreationTokens
    }

    /// Preserves locally-accumulated OTLP fields (cost, model, cache tokens)
    /// from an existing session when the incoming data has zero/nil values.
    mutating func preserveOTLPFields(from existing: Session) {
        if costUsd == 0 && existing.costUsd > 0 { costUsd = existing.costUsd }
        if lastModel == nil, let m = existing.lastModel { lastModel = m }
        if otlpCacheReadTokens == 0 { otlpCacheReadTokens = existing.otlpCacheReadTokens }
        if otlpCacheCreationTokens == 0 { otlpCacheCreationTokens = existing.otlpCacheCreationTokens }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        userId = try container.decode(String.self, forKey: .userId)
        projectPath = try container.decode(String.self, forKey: .projectPath)
        gitBranch = try container.decode(String.self, forKey: .gitBranch)
        cwd = try container.decode(String.self, forKey: .cwd)
        status = try container.decode(SessionStatus.self, forKey: .status)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        tokensIn = try container.decode(Int64.self, forKey: .tokensIn)
        tokensOut = try container.decode(Int64.self, forKey: .tokensOut)
        turnCount = try container.decode(Int.self, forKey: .turnCount)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        projectId = try container.decodeIfPresent(String.self, forKey: .projectId)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        ephemeralPublicKey = try container.decodeIfPresent(String.self, forKey: .ephemeralPublicKey)
        costUsd = try container.decodeIfPresent(Double.self, forKey: .costUsd) ?? 0
        lastModel = try container.decodeIfPresent(String.self, forKey: .lastModel)
        otlpCacheReadTokens = try container.decodeIfPresent(Int64.self, forKey: .otlpCacheReadTokens) ?? 0
        otlpCacheCreationTokens = try container.decodeIfPresent(Int64.self, forKey: .otlpCacheCreationTokens) ?? 0
    }
}
