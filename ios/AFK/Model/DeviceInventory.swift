import Foundation

struct DeviceInventory: Codable, Identifiable, Sendable {
    var id: String { deviceId }
    let deviceId: String
    let deviceName: String?
    let isOnline: Bool?
    var inventory: InventoryReport
    let contentHash: String?
    let updatedAt: String?

    /// True if the inventory is encrypted (backend stores `{"encrypted": "..."}`)
    var isEncrypted: Bool {
        inventory.encrypted != nil
    }
}

/// Wrapper for encrypted inventory stored as `{"encrypted": "<ciphertext>"}`
struct EncryptedInventoryWrapper: Codable, Sendable {
    let encrypted: String
}

struct InventoryReport: Codable, Sendable {
    let globalCommands: [InventoryCommand]?
    let globalSkills: [InventorySkill]?
    let projectCommands: [ProjectInventory]?
    let mcpServers: [InventoryMCPServer]?
    let hooks: [InventoryHook]?
    let plans: [InventoryPlan]?
    let teams: [InventoryTeam]?
    /// Present when inventory is encrypted (E2EE mode). Contains the ciphertext.
    let encrypted: String?
}

struct InventorySkill: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(scope)-\(name)" }
    let name: String
    let description: String
    let content: String
    let scope: String
}

struct InventoryCommand: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(scope)-\(name)" }
    let name: String
    let description: String
    let content: String
    let scope: String
}

struct ProjectInventory: Codable, Identifiable, Sendable {
    var id: String { projectPath }
    let projectPath: String
    let commands: [InventoryCommand]?
    let skills: [InventorySkill]?
    let mcpServers: [InventoryMCPServer]?
}

struct InventoryMCPServer: Codable, Identifiable, Sendable {
    var id: String { "\(scope)-\(name)" }
    let name: String
    let command: String
    let args: [String]?
    let scope: String
}

struct InventoryHook: Codable, Identifiable, Sendable {
    var id: String { "\(eventType)-\(matcher)-\(command)" }
    let eventType: String
    let matcher: String
    let command: String
    let isAFK: Bool
}

struct InventoryPlan: Codable, Identifiable, Sendable {
    var id: String { filename }
    let name: String
    let filename: String
}

struct InventoryTeam: Codable, Identifiable, Sendable {
    var id: String { name }
    let name: String
}

struct SharedSkill: Codable, Identifiable, Sendable {
    var id: String { "\(sourceDeviceId)-\(name)" }
    let name: String
    let description: String?
    let content: String
    let sourceDeviceId: String
    let sourceDeviceName: String?
}

struct InstallSkillResponse: Codable, Sendable {
    let status: String
}
