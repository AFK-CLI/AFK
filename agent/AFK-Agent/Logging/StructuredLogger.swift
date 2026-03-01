import Foundation

enum LogLevel: String, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

struct StructuredLogger: Sendable {
    let subsystem: String
    let minLevel: LogLevel

    init(subsystem: String, minLevel: LogLevel = .info) {
        self.subsystem = subsystem
        self.minLevel = minLevel
    }

    func debug(_ message: String, fields: [String: String] = [:]) {
        log(.debug, message, fields: fields)
    }

    func info(_ message: String, fields: [String: String] = [:]) {
        log(.info, message, fields: fields)
    }

    func warn(_ message: String, fields: [String: String] = [:]) {
        log(.warn, message, fields: fields)
    }

    func error(_ message: String, fields: [String: String] = [:]) {
        log(.error, message, fields: fields)
    }

    private func log(_ level: LogLevel, _ message: String, fields: [String: String]) {
        guard levelValue(level) >= levelValue(minLevel) else { return }

        var entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "level": level.rawValue,
            "subsystem": subsystem,
            "msg": message,
        ]

        for (key, value) in fields {
            entry[key] = value
        }

        if let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        } else {
            print("[\(subsystem)] [\(level.rawValue)] \(message)")
        }
    }

    private func levelValue(_ level: LogLevel) -> Int {
        switch level {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }
}
