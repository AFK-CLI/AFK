//
//  WWUDStore.swift
//  AFK-Agent
//
//  JSON-based persistence for WWUD decision history.
//  Stores per-project decision files at ~/.afk-agent/wwud/<hash>/decisions.json.
//  Uses atomic writes (write-to-tmp + rename) for crash safety.
//

import Foundation
import CryptoKit
import OSLog

struct WWUDStore {

    /// Base directory for WWUD data.
    static var baseDirectory: String {
        BuildEnvironment.configDirectoryPath + "/wwud"
    }

    // MARK: - Load

    /// Load decisions for a specific project, pruning expired entries.
    static func load(projectPath: String) -> [WWUDDecision] {
        let path = decisionsFilePath(for: projectPath)
        guard let data = FileManager.default.contents(atPath: path) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decisions = try? decoder.decode([WWUDDecision].self, from: data) else {
            AppLogger.wwud.warning("Failed to decode WWUD decisions at \(path, privacy: .public)")
            return []
        }

        // Prune expired decisions (>90 days)
        let now = Date()
        let active = decisions.filter { !$0.isExpired(relativeTo: now) }

        // If we pruned any, save the cleaned list
        if active.count < decisions.count {
            AppLogger.wwud.info("Pruned \(decisions.count - active.count, privacy: .public) expired WWUD decisions for \(projectHash(projectPath).prefix(8), privacy: .public)")
            save(decisions: active, projectPath: projectPath)
        }

        return active
    }

    // MARK: - Save

    /// Atomically save decisions for a specific project.
    static func save(decisions: [WWUDDecision], projectPath: String) {
        let dir = projectDirectory(for: projectPath)
        let finalURL = URL(fileURLWithPath: dir + "/decisions.json")
        let tmpURL = URL(fileURLWithPath: dir + "/decisions.json.tmp")

        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(decisions)

            try data.write(to: tmpURL)
            // Atomic replace (no window where file is missing)
            _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: tmpURL)
        } catch {
            AppLogger.wwud.error("Failed to save WWUD decisions: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: tmpURL)
        }
    }

    // MARK: - Pruning

    /// Prune all project directories, removing expired decisions.
    static func pruneAll() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: baseDirectory) else { return }

        for dir in contents {
            let dirPath = baseDirectory + "/" + dir
            let filePath = dirPath + "/decisions.json"
            guard fm.fileExists(atPath: filePath),
                  let data = fm.contents(atPath: filePath) else { continue }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let decisions = try? decoder.decode([WWUDDecision].self, from: data) else { continue }

            let now = Date()
            let active = decisions.filter { !$0.isExpired(relativeTo: now) }

            if active.isEmpty {
                // Remove empty project directory
                try? fm.removeItem(atPath: dirPath)
                AppLogger.wwud.info("Removed empty WWUD project dir: \(dir.prefix(8), privacy: .public)")
            } else if active.count < decisions.count {
                let finalURL = URL(fileURLWithPath: filePath)
                let tmpURL = URL(fileURLWithPath: filePath + ".tmp")
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(active) {
                    do {
                        try data.write(to: tmpURL)
                        _ = try fm.replaceItemAt(finalURL, withItemAt: tmpURL)
                    } catch {
                        try? fm.removeItem(at: tmpURL)
                    }
                }
                AppLogger.wwud.info("Pruned \(decisions.count - active.count, privacy: .public) decisions from \(dir.prefix(8), privacy: .public)")
            }
        }
    }

    // MARK: - Search

    /// Search all project directories for a decision by ID.
    /// Returns the decision and its project path if found.
    static func findDecision(id: String) -> (decision: WWUDDecision, projectPath: String)? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: baseDirectory) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for dir in contents {
            let filePath = baseDirectory + "/" + dir + "/decisions.json"
            guard let data = fm.contents(atPath: filePath),
                  let decisions = try? decoder.decode([WWUDDecision].self, from: data),
                  let match = decisions.first(where: { $0.id == id }) else { continue }
            return (match, match.projectPath)
        }
        return nil
    }

    // MARK: - Helpers

    /// SHA256 hash of the project path (used as directory name).
    static func projectHash(_ projectPath: String) -> String {
        let digest = SHA256.hash(data: Data(projectPath.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Directory for a specific project's WWUD data.
    static func projectDirectory(for projectPath: String) -> String {
        baseDirectory + "/" + projectHash(projectPath)
    }

    /// Full path to the decisions JSON file for a project.
    static func decisionsFilePath(for projectPath: String) -> String {
        projectDirectory(for: projectPath) + "/decisions.json"
    }
}
