//
//  SessionIndex.swift
//  AFK-Agent
//

import Foundation

actor SessionIndex {
    // Maps JSONL file path to session ID (extracted from filename)
    private var pathToSession: [String: String] = [:]
    // Maps session ID to project path (derived from directory structure)
    private var sessionToProject: [String: String] = [:]

    func register(filePath: String) -> (sessionId: String, projectPath: String) {
        // Filename is <sessionId>.jsonl
        let url = URL(fileURLWithPath: filePath)
        let sessionId = url.deletingPathExtension().lastPathComponent

        // Parent directories encode the project path
        // ~/.claude/projects/<encoded-path>/<sessionId>.jsonl
        let encodedDir = url.deletingLastPathComponent().lastPathComponent
        let projectPath = Self.decodeProjectPath(encodedDir)

        pathToSession[filePath] = sessionId
        sessionToProject[sessionId] = projectPath
        return (sessionId, projectPath)
    }

    func sessionId(for filePath: String) -> String? {
        pathToSession[filePath]
    }

    func projectPath(for sessionId: String) -> String? {
        sessionToProject[sessionId]
    }

    /// Register a session directly with a known project path (bypasses file path decoding).
    func registerDirect(sessionId: String, projectPath: String) {
        sessionToProject[sessionId] = projectPath
    }

    /// Return all unique project paths that have been registered.
    func allProjectPaths() -> [String] {
        Array(Set(sessionToProject.values))
    }

    /// Decode Claude Code's encoded project directory name back to a filesystem path.
    /// Encoding: both `/` and `.` are replaced with `-`.
    ///   `/Volumes/Foo/Bar`     → `-Volumes-Foo-Bar`
    ///   `/Foo/.claude/worktrees` → `-Foo--claude-worktrees`  (double hyphen = `/` + `.`)
    /// Ambiguity (paths containing `-`) is resolved by checking which path exists on disk.
    static func decodeProjectPath(_ encoded: String) -> String {
        // Strip leading `-` which represents the root `/`
        let stripped = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded

        // Split on `-` and merge empty parts with the next part as hidden dirs.
        // Double hyphens `--` encode `/.` (a hidden directory), so:
        //   "AFK--claude" → split → ["AFK", "", "claude"] → merge → ["AFK", ".claude"]
        let rawParts = stripped.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        var parts: [String] = []
        var idx = 0
        while idx < rawParts.count {
            if rawParts[idx].isEmpty, idx + 1 < rawParts.count {
                parts.append("." + rawParts[idx + 1])
                idx += 2
            } else {
                parts.append(rawParts[idx])
                idx += 1
            }
        }

        guard !parts.isEmpty else { return encoded }

        var resolved = ""
        var i = 0
        let fm = FileManager.default

        while i < parts.count {
            // Try progressively longer hyphenated segments
            var candidate = parts[i]
            var bestMatch = ""
            var bestEnd = i

            for j in i..<parts.count {
                if j > i {
                    candidate += "-" + parts[j]
                }
                let testPath = resolved + "/" + candidate
                if fm.fileExists(atPath: testPath) {
                    bestMatch = testPath
                    bestEnd = j
                }
            }

            if !bestMatch.isEmpty {
                resolved = bestMatch
                i = bestEnd + 1
            } else {
                // No match found — just append with `/` (best effort)
                resolved += "/" + parts[i]
                i += 1
            }
        }

        return resolved.isEmpty ? "/" + stripped.replacingOccurrences(of: "-", with: "/") : resolved
    }
}
