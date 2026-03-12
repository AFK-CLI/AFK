//
//  SharedSkillInstaller.swift
//  AFK-Agent
//

import Foundation
import OSLog

actor SharedSkillInstaller {
    struct SharedCommand: Codable, Sendable {
        let name: String
        let content: String
        let sourceDeviceId: String
        let sourceDeviceName: String
    }

    private let commandsDir: String

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        commandsDir = "\(home)/.claude/commands"
    }

    /// Install shared commands from peer devices (additive).
    func installSharedCommands(_ commands: [SharedCommand]) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: commandsDir, withIntermediateDirectories: true)

        for command in commands {
            let safeName = command.name.replacingOccurrences(of: "/", with: "-")
            let filePath = "\(commandsDir)/\(safeName).md"

            // Only write if content differs (minimize disk writes)
            if let existing = fm.contents(atPath: filePath),
               let existingStr = String(data: existing, encoding: .utf8),
               existingStr == command.content {
                continue
            }

            fm.createFile(atPath: filePath, contents: command.content.data(using: .utf8))
            AppLogger.agent.info("Installed shared command: \(safeName, privacy: .public)")
        }
    }

    /// Install a single command file sent from iOS "Send to Mac" flow.
    func installSingleCommand(name: String, content: String, sourceDeviceName: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: commandsDir, withIntermediateDirectories: true)

        let safeName = name.replacingOccurrences(of: "/", with: "-")
        let filePath = "\(commandsDir)/\(safeName).md"

        // Only write if content differs
        if let existing = fm.contents(atPath: filePath),
           let existingStr = String(data: existing, encoding: .utf8),
           existingStr == content {
            return
        }

        fm.createFile(atPath: filePath, contents: content.data(using: .utf8))
        AppLogger.agent.info("Installed command from \(sourceDeviceName, privacy: .public): \(safeName, privacy: .public)")
    }
}
