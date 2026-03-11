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

    /// Install shared commands from peer devices. Cleans up stale files first.
    func installSharedCommands(_ commands: [SharedCommand]) {
        let fm = FileManager.default

        // Ensure commands directory exists
        try? fm.createDirectory(atPath: commandsDir, withIntermediateDirectories: true)

        // Clean up ALL existing afk-shared-* files first
        cleanupSharedFiles()

        // Write new shared command files
        for command in commands {
            let devicePrefix = String(command.sourceDeviceId.prefix(8))
            let safeName = command.name.replacingOccurrences(of: "/", with: "-")
            let filename = "afk-shared-\(devicePrefix)-\(safeName).md"
            let filePath = "\(commandsDir)/\(filename)"

            let header = "<!-- Shared from: \(command.sourceDeviceName) via AFK -->\n"
            let content = header + command.content

            // Only write if content differs (minimize disk writes)
            if let existing = fm.contents(atPath: filePath),
               let existingStr = String(data: existing, encoding: .utf8),
               existingStr == content {
                continue
            }

            fm.createFile(atPath: filePath, contents: content.data(using: .utf8))
            AppLogger.agent.info("Installed shared command: \(filename, privacy: .public)")
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

    /// Remove all afk-shared-* command files.
    func cleanupSharedFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: commandsDir) else { return }
        for file in files where file.hasPrefix("afk-shared-") {
            try? fm.removeItem(atPath: "\(commandsDir)/\(file)")
        }
    }
}
