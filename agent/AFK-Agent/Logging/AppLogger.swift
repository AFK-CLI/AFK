import OSLog

enum AppLogger {
    static let subsystem = Bundle.main.bundleIdentifier ?? "ahmetbirinci.AFK-Agent"

    static let agent = Logger(subsystem: subsystem, category: "Agent")
    static let ws = Logger(subsystem: subsystem, category: "WebSocket")
    static let auth = Logger(subsystem: subsystem, category: "Auth")
    static let e2ee = Logger(subsystem: subsystem, category: "E2EE")
    static let permission = Logger(subsystem: subsystem, category: "Permission")
    static let command = Logger(subsystem: subsystem, category: "Command")
    static let session = Logger(subsystem: subsystem, category: "Session")
    static let parser = Logger(subsystem: subsystem, category: "Parser")
    static let state = Logger(subsystem: subsystem, category: "State")
    static let network = Logger(subsystem: subsystem, category: "Network")
    static let hook = Logger(subsystem: subsystem, category: "Hook")
    static let queue = Logger(subsystem: subsystem, category: "Queue")
    static let statusBar = Logger(subsystem: subsystem, category: "StatusBar")
    static let usage = Logger(subsystem: subsystem, category: "Usage")
    static let wwud = Logger(subsystem: subsystem, category: "WWUD")
}
