import SwiftUI

enum TaskSource: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude_code"
    case user

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .user: "Personal"
        }
    }

    var iconName: String {
        switch self {
        case .claudeCode: "terminal"
        case .user: "person.fill"
        }
    }
}

enum AFKTaskStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed

    var displayName: String {
        switch self {
        case .pending: "To Do"
        case .inProgress: "In Progress"
        case .completed: "Done"
        }
    }

    var iconName: String {
        switch self {
        case .pending: "circle"
        case .inProgress: "circle.dotted.circle"
        case .completed: "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .pending: .secondary
        case .inProgress: .blue
        case .completed: .green
        }
    }
}

struct AFKTask: Codable, Identifiable, Sendable {
    let id: String
    var sessionId: String?
    var projectId: String?
    let source: TaskSource
    var sessionLocalId: String?
    var subject: String
    var description: String
    var status: AFKTaskStatus
    var activeForm: String?
    let createdAt: Date?
    var updatedAt: Date?
    var projectName: String?

    init(id: String, sessionId: String? = nil, projectId: String? = nil,
         source: TaskSource, sessionLocalId: String? = nil,
         subject: String, description: String = "",
         status: AFKTaskStatus = .pending, activeForm: String? = nil,
         createdAt: Date? = nil, updatedAt: Date? = nil,
         projectName: String? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.projectId = projectId
        self.source = source
        self.sessionLocalId = sessionLocalId
        self.subject = subject
        self.description = description
        self.status = status
        self.activeForm = activeForm
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.projectName = projectName
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        projectId = try container.decodeIfPresent(String.self, forKey: .projectId)
        source = try container.decode(TaskSource.self, forKey: .source)
        sessionLocalId = try container.decodeIfPresent(String.self, forKey: .sessionLocalId)
        subject = try container.decode(String.self, forKey: .subject)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        status = try container.decode(AFKTaskStatus.self, forKey: .status)
        activeForm = try container.decodeIfPresent(String.self, forKey: .activeForm)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
    }
}
