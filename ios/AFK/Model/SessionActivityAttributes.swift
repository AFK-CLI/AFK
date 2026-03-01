import ActivityKit
import Foundation

struct SessionActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var status: String          // "running", "waiting_permission", "waiting_input", "error", "completed"
        var currentTool: String?
        var turnCount: Int
        var elapsedSeconds: Int
        var agentCount: Int?
    }

    var sessionId: String
    var projectName: String
    var deviceName: String
}
