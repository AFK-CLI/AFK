import Foundation

struct ToolInputField: Codable, Identifiable {
    let label: String
    let value: String
    let style: String

    var id: String { "\(label)-\(value.prefix(20))" }
}

struct ToolResultImage: Codable, Identifiable {
    let mediaType: String
    let data: String

    var id: String { String(data.prefix(32)) }
}
