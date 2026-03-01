import Foundation

struct ToolInputField: Codable, Identifiable {
    let label: String
    let value: String
    let style: String

    var id: String { "\(label)-\(value.prefix(20))" }
}
