import OSLog

enum AppLogger {
    static let subsystem = Bundle.main.bundleIdentifier ?? "dev.ahmetbirinci.AFK"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let auth = Logger(subsystem: subsystem, category: "Auth")
    static let ws = Logger(subsystem: subsystem, category: "WebSocket")
    static let api = Logger(subsystem: subsystem, category: "API")
    static let session = Logger(subsystem: subsystem, category: "Session")
    static let e2ee = Logger(subsystem: subsystem, category: "E2EE")
    static let push = Logger(subsystem: subsystem, category: "Push")
    static let sync = Logger(subsystem: subsystem, category: "Sync")
    static let bg = Logger(subsystem: subsystem, category: "Background")
    static let store = Logger(subsystem: subsystem, category: "Store")
    static let keychain = Logger(subsystem: subsystem, category: "Keychain")
    static let liveActivity = Logger(subsystem: subsystem, category: "LiveActivity")
    static let subscription = Logger(subsystem: subsystem, category: "Subscription")
    static let feedback = Logger(subsystem: subsystem, category: "Feedback")
    static let ui = Logger(subsystem: subsystem, category: "UI")
}
