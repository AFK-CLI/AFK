//
//  CommandValidator.swift
//  AFK-Agent
//

import Foundation

struct CommandValidator: Sendable {
    enum ValidationError: Error, CustomStringConvertible {
        case invalidBinary(String)
        case deniedFlag(String)
        case shellMetacharacter(String)
        case pathTraversal

        var description: String {
            switch self {
            case .invalidBinary(let b): return "Invalid binary: \(b)"
            case .deniedFlag(let f): return "Denied flag: \(f)"
            case .shellMetacharacter(let c): return "Shell metacharacter: \(c)"
            case .pathTraversal: return "Path traversal detected"
            }
        }
    }

    // Allowed flags for claude CLI
    private static let allowedFlags: Set<String> = [
        "--resume", "--continue", "-p", "--print", "--output-format", "--verbose",
        "--fork-session", "--worktree", "-w", "--permission-mode"
    ]

    // Explicitly denied flags
    private static let deniedFlags: Set<String> = [
        "--model", "--max-turns", "--allowedTools", "--dangerouslySkipPermissions"
    ]

    // Shell metacharacters
    private static let shellMetachars = CharacterSet(charactersIn: ";|&$`(){}<>")

    /// Validate command arguments before execution
    static func validate(args: [String]) throws {
        guard !args.isEmpty else { throw ValidationError.invalidBinary("empty") }

        // First arg must be the resolved claude path
        let binary = args[0]
        let home = NSHomeDirectory()
        let allowedPrefixes = ["/usr/local/", "/opt/homebrew/", "/usr/bin/", home + "/.claude/"]
        guard allowedPrefixes.contains(where: { binary.hasPrefix($0) }) else {
            throw ValidationError.invalidBinary(binary)
        }

        // Check each argument (skip values that follow -p/--print since prompt
        // text is user content that may legitimately contain metacharacters and
        // is passed directly to Process, not through a shell)
        var skipMetacharCheck = false
        for arg in args.dropFirst() {
            // Check for path traversal
            if arg.contains("..") {
                throw ValidationError.pathTraversal
            }

            // Check for shell metacharacters (skip prompt values)
            if !skipMetacharCheck {
                if arg.unicodeScalars.contains(where: { Self.shellMetachars.contains($0) }) {
                    throw ValidationError.shellMetacharacter(arg)
                }
            }
            skipMetacharCheck = (arg == "-p" || arg == "--print")

            // Check flags
            if arg.hasPrefix("-") {
                // Allow known flags
                let flagName = arg.contains("=") ? String(arg.prefix(while: { $0 != "=" })) : arg
                if Self.deniedFlags.contains(flagName) {
                    throw ValidationError.deniedFlag(flagName)
                }
                // Deny-by-default: reject unknown flags
                if !Self.allowedFlags.contains(flagName) {
                    throw ValidationError.deniedFlag(flagName)
                }
            }
        }
    }

    /// Resolve the path to the `claude` binary.
    /// Searches known install locations first (Xcode processes have a minimal PATH),
    /// then falls back to `which`.
    static func resolveClaudePath() throws -> String {
        // Common install locations for claude CLI
        let knownPaths = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            NSHomeDirectory() + "/.claude/local/bin/claude",
        ]

        for path in knownPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fallback: try `which` with an expanded PATH
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["claude"]
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ValidationError.invalidBinary("claude not found in PATH or known locations")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else {
            throw ValidationError.invalidBinary("empty claude path")
        }
        return path
    }
}
