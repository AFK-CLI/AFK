import Foundation
import SwiftData

@Model
final class CachedTask {
    @Attribute(.unique) var id: String
    var sessionId: String?
    var projectId: String?
    var sourceRaw: String
    var sessionLocalId: String?
    var subject: String
    var taskDescription: String
    var statusRaw: String
    var activeForm: String?
    var createdAt: Date?
    var updatedAt: Date?
    var projectName: String?
    var lastSyncedAt: Date

    init(from task: AFKTask) {
        self.id = task.id
        self.sessionId = task.sessionId
        self.projectId = task.projectId
        self.sourceRaw = task.source.rawValue
        self.sessionLocalId = task.sessionLocalId
        self.subject = task.subject
        self.taskDescription = task.description
        self.statusRaw = task.status.rawValue
        self.activeForm = task.activeForm
        self.createdAt = task.createdAt
        self.updatedAt = task.updatedAt
        self.projectName = task.projectName
        self.lastSyncedAt = Date()
    }

    func toAFKTask() -> AFKTask {
        AFKTask(
            id: id,
            sessionId: sessionId,
            projectId: projectId,
            source: TaskSource(rawValue: sourceRaw) ?? .user,
            sessionLocalId: sessionLocalId,
            subject: subject,
            description: taskDescription,
            status: AFKTaskStatus(rawValue: statusRaw) ?? .pending,
            activeForm: activeForm,
            createdAt: createdAt,
            updatedAt: updatedAt,
            projectName: projectName
        )
    }

    func update(from task: AFKTask) {
        sessionId = task.sessionId
        projectId = task.projectId
        sourceRaw = task.source.rawValue
        sessionLocalId = task.sessionLocalId
        subject = task.subject
        taskDescription = task.description
        statusRaw = task.status.rawValue
        activeForm = task.activeForm
        createdAt = task.createdAt
        updatedAt = task.updatedAt
        projectName = task.projectName
        lastSyncedAt = Date()
    }
}
