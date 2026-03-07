import Foundation

enum ScreenshotMode {
    static let isActive = ProcessInfo.processInfo.arguments.contains("-screenshotMode")
}
