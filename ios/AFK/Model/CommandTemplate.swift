import Foundation

struct CommandTemplate: Codable, Identifiable, Sendable {
    let id: String
    var name: String
    var prompt: String
    var icon: String
    var projectPath: String?  // nil = available for all projects

    static let builtIn: [CommandTemplate] = [
        CommandTemplate(id: "status", name: "Status", prompt: "What is the current status of this session?", icon: "info.circle"),
        CommandTemplate(id: "cost", name: "Cost", prompt: "What is the token usage and cost so far?", icon: "dollarsign.circle"),
        CommandTemplate(id: "compact", name: "Compact", prompt: "Please compact the conversation", icon: "arrow.down.right.and.arrow.up.left"),
        CommandTemplate(id: "summary", name: "Summary", prompt: "Give me a brief summary of what has been accomplished so far", icon: "doc.text"),
        CommandTemplate(id: "tests", name: "Run Tests", prompt: "Run the test suite and report results", icon: "checkmark.diamond"),
        CommandTemplate(id: "lint", name: "Lint", prompt: "Check for linting issues and fix them", icon: "exclamationmark.triangle"),
    ]
}
