import Foundation

/// A parsed segment of assistant message content.
/// Regular markdown text is interleaved with special XML-tagged blocks.
enum AssistantContentBlock: Identifiable {
    case text(String)
    case taskNotification(TaskNotificationData)
    case teammateMessage(TeammateMessageData)

    var id: String {
        switch self {
        case .text(let s): return "text-\(s.hashValue)"
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

    var shouldHide: Bool {
        messageType == "idle_notification"
    }
}
