import Foundation

/// A parsed segment of assistant message content.
/// Regular markdown text is interleaved with special XML-tagged blocks.
enum AssistantContentBlock: Identifiable {
    case text(String)
    case taskNotification(TaskNotificationData)
    case teammateMessage(TeammateMessageData)

    var id: String {
        switch self {
        case .text(let s): return "text-\(s.prefix(64))-\(s.count)"
        case .taskNotification(let d): return "task-\(d.taskId)"
        case .teammateMessage(let d): return "tm-\(d.teammateId)-\(d.timestamp ?? d.messageType)"
        }
    }
}

struct TaskNotificationData {
    let taskId: String
    let toolUseId: String?
    let status: String
    let summary: String
    let result: String?
}

struct TeammateMessageData {
    let teammateId: String
    let color: String?
    let messageType: String
    let from: String?
    let timestamp: String?
    let displayMessage: String?
    let summary: String?

    init(teammateId: String, color: String?, messageType: String, from: String?, timestamp: String?, displayMessage: String?, summary: String? = nil) {
        self.teammateId = teammateId
        self.color = color
        self.messageType = messageType
        self.from = from
        self.timestamp = timestamp
        self.displayMessage = displayMessage
        self.summary = summary
    }

    var shouldHide: Bool {
        messageType == "idle_notification"
    }
}
