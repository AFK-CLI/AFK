//
//  InventoryScanner.swift
//  AFK-Agent
//

import Foundation
import CryptoKit
import OSLog

actor InventoryScanner {
    // MARK: - Data Models

    struct InventoryReport: Codable, Sendable {
        let globalCommands: [InventoryCommand]
        let globalSkills: [InventorySkill]
        let projectCommands: [ProjectInventory]
        let mcpServers: [InventoryMCPServer]
        let hooks: [InventoryHook]
    }

    struct InventoryCommand: Codable, Sendable {
        let name: String
        let description: String
        let content: String
        let scope: String
    }

    struct InventorySkill: Codable, Sendable {
        let name: String
        let description: String
        let content: String
        let scope: String
    }

    struct ProjectInventory: Codable, Sendable {
        let projectPath: String
        let commands: [InventoryCommand]
        let skills: [InventorySkill]
        let mcpServers: [InventoryMCPServer]
    }

    struct InventoryMCPServer: Codable, Sendable {
        let name: String
        let command: String
        let args: [String]
        let scope: String
    }

    struct InventoryHook: Codable, Sendable {
        let eventType: String
        let matcher: String
        let command: String
        let isAFK: Bool
    }

    // MARK: - State

    private var lastHash: String = ""
    private var knownProjectPaths: Set<String> = []

    init() {
        lastHash = UserDefaults.standard.string(forKey: "lastInventoryHash") ?? ""
    }

    // MARK: - Public API

    /// Perform a full scan and return the report if content changed (or force=true).
    func scan(projectPaths: Set<String> = [], force: Bool = false) -> InventoryReport? {
        let report = buildReport(projectPaths: projectPaths)
        let hash = computeHash(report)

        if !force && hash == lastHash {
            return nil
        }

        lastHash = hash
        UserDefaults.standard.set(hash, forKey: "lastInventoryHash")
        return report
    }

    /// Check if a new project path was added that wasn't in the last scan.
    func hasNewProject(_ path: String) -> Bool {
        if knownProjectPaths.contains(path) { return false }
        knownProjectPaths.insert(path)
        return true
    }

    // MARK: - Report Building

    private func buildReport(projectPaths: Set<String>) -> InventoryReport {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path

        // 1. Scan global commands: ~/.claude/commands/*.md
        let globalCommandsDir = "\(home)/.claude/commands"
        let globalCommands = scanCommands(directory: globalCommandsDir, scope: "global")

        // 2. Scan global skills: ~/.claude/skills/<name>/SKILL.md
        let globalSkillsDir = "\(home)/.claude/skills"
        let globalSkills = scanSkills(directory: globalSkillsDir, scope: "global")

        // 3. Scan global MCP servers + hooks from ~/.claude/settings.json
        let globalSettingsPath = "\(home)/.claude/settings.json"
        let (globalMCPServers, hooks) = scanSettings(path: globalSettingsPath, scope: "global")

        // 4. Scan per-project commands, skills, and MCP servers
        var projectInventories: [ProjectInventory] = []
        let allProjectPaths = knownProjectPaths.union(projectPaths)
        for projectPath in allProjectPaths {
            let projCommandsDir = "\(projectPath)/.claude/commands"
            let projCommands = scanCommands(directory: projCommandsDir, scope: projectPath)
            let projSkillsDir = "\(projectPath)/.claude/skills"
            let projSkills = scanSkills(directory: projSkillsDir, scope: projectPath)
            let projSettingsPath = "\(projectPath)/.claude/settings.json"
            let (projMCPServers, _) = scanSettings(path: projSettingsPath, scope: projectPath)
            if !projCommands.isEmpty || !projSkills.isEmpty || !projMCPServers.isEmpty {
                projectInventories.append(ProjectInventory(
                    projectPath: projectPath,
                    commands: projCommands,
                    skills: projSkills,
                    mcpServers: projMCPServers
                ))
            }
        }

        // Enforce limits
        let limitedGlobalCommands = Array(globalCommands.prefix(100))
        let limitedGlobalSkills = Array(globalSkills.prefix(50))
        let limitedMCPServers = Array(globalMCPServers.prefix(20))
        let limitedHooks = Array(hooks.prefix(50))

        return InventoryReport(
            globalCommands: limitedGlobalCommands,
            globalSkills: limitedGlobalSkills,
            projectCommands: projectInventories,
            mcpServers: limitedMCPServers,
            hooks: limitedHooks
        )
    }

    private func scanCommands(directory: String, scope: String) -> [InventoryCommand] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory) else { return [] }
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return [] }

        var commands: [InventoryCommand] = []
        for file in files where file.hasSuffix(".md") {
            let filePath = "\(directory)/\(file)"
            guard let data = fm.contents(atPath: filePath),
                  var content = String(data: data, encoding: .utf8) else { continue }

            // Enforce 32KB limit per command
            if content.count > 32_768 {
                content = String(content.prefix(32_768))
            }

            let name = String(file.dropLast(3)) // remove .md
            let description = content.components(separatedBy: .newlines).first ?? ""

            commands.append(InventoryCommand(
                name: name,
                description: description,
                content: content,
                scope: scope
            ))
        }
        return commands
    }

    private func scanSkills(directory: String, scope: String) -> [InventorySkill] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory) else { return [] }
        guard let subdirs = try? fm.contentsOfDirectory(atPath: directory) else { return [] }

        var skills: [InventorySkill] = []
        for subdir in subdirs {
            let skillFile = "\(directory)/\(subdir)/SKILL.md"
            guard let data = fm.contents(atPath: skillFile),
                  var content = String(data: data, encoding: .utf8) else { continue }

            // Enforce 32KB limit
            if content.count > 32_768 {
                content = String(content.prefix(32_768))
            }

            // Parse YAML frontmatter for name and description
            var name = subdir
            var description = ""
            if content.hasPrefix("---") {
                let parts = content.components(separatedBy: "---")
                if parts.count >= 3 {
                    let frontmatter = parts[1]
                    for line in frontmatter.components(separatedBy: .newlines) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("name:") {
                            name = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        } else if trimmed.hasPrefix("description:") {
                            description = trimmed.dropFirst(12).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        }
                    }
                }
            }

            skills.append(InventorySkill(
                name: name,
                description: description,
                content: content,
                scope: scope
            ))
        }
        return skills
    }

    private func scanSettings(path: String, scope: String) -> ([InventoryMCPServer], [InventoryHook]) {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], [])
        }

        // Parse MCP servers
        var servers: [InventoryMCPServer] = []
        if let mcpServers = json["mcpServers"] as? [String: Any] {
            for (name, value) in mcpServers {
                guard let config = value as? [String: Any] else { continue }
                let command = config["command"] as? String ?? ""
                let args = config["args"] as? [String] ?? []
                // Redact env values to prevent leaking API keys
                servers.append(InventoryMCPServer(
                    name: name,
                    command: command,
                    args: args,
                    scope: scope
                ))
            }
        }

        // Parse hooks (global only)
        var hooks: [InventoryHook] = []
        if scope == "global", let hooksDict = json["hooks"] as? [String: Any] {
            for (eventType, value) in hooksDict {
                guard let hookArray = value as? [[String: Any]] else { continue }
                for hookConfig in hookArray {
                    let matcher = hookConfig["matcher"] as? String ?? "*"
                    let command = hookConfig["command"] as? String ?? ""
                    let isAFK = command.contains("afk-")
                    hooks.append(InventoryHook(
                        eventType: eventType,
                        matcher: matcher,
                        command: command,
                        isAFK: isAFK
                    ))
                }
            }
        }

        return (servers, hooks)
    }

    // MARK: - Privacy Mode Redaction

    /// Return a redacted copy of the report suitable for telemetry_only mode.
    /// Strips command content (keeps only first line as description), redacts hook commands, and redacts MCP args.
    func redacted(_ report: InventoryReport) -> InventoryReport {
        InventoryReport(
            globalCommands: report.globalCommands.map { redactCommand($0) },
            globalSkills: report.globalSkills.map { redactSkill($0) },
            projectCommands: report.projectCommands.map { proj in
                ProjectInventory(
                    projectPath: proj.projectPath,
                    commands: proj.commands.map { redactCommand($0) },
                    skills: proj.skills.map { redactSkill($0) },
                    mcpServers: proj.mcpServers.map { redactMCPServer($0) }
                )
            },
            mcpServers: report.mcpServers.map { redactMCPServer($0) },
            hooks: report.hooks.map { redactHook($0) }
        )
    }

    private func redactCommand(_ cmd: InventoryCommand) -> InventoryCommand {
        InventoryCommand(
            name: cmd.name,
            description: cmd.description,
            content: "[redacted]",
            scope: cmd.scope
        )
    }

    private func redactSkill(_ skill: InventorySkill) -> InventorySkill {
        InventorySkill(
            name: skill.name,
            description: skill.description,
            content: "[redacted]",
            scope: skill.scope
        )
    }

    private func redactMCPServer(_ srv: InventoryMCPServer) -> InventoryMCPServer {
        InventoryMCPServer(
            name: srv.name,
            command: srv.command,
            args: srv.args.map { _ in "***" },
            scope: srv.scope
        )
    }

    private func redactHook(_ hook: InventoryHook) -> InventoryHook {
        InventoryHook(
            eventType: hook.eventType,
            matcher: hook.matcher,
            command: "[redacted]",
            isAFK: hook.isAFK
        )
    }

    private func computeHash(_ report: InventoryReport) -> String {
        guard let data = try? JSONEncoder().encode(report) else { return "" }
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
