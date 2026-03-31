//
//  Agent+Commands.swift
//  AFK-Agent
//

import Foundation
import CryptoKit
import OSLog

extension Agent {

    func handleCommandContinue(_ msg: WSMessage) async {
        guard let executor = commandExecutor, let client = wsClient else {
            AppLogger.command.error("Command executor not configured")
            return
        }

        let decoder = JSONDecoder()
        guard let request = try? decoder.decode(
            CommandExecutor.CommandRequest.self,
            from: msg.payloadJSON
        ) else {
            AppLogger.command.error("Failed to parse command request")
            return
        }

        // Look up project path from session index
        let projectPath = await sessionIndex.projectPath(for: request.sessionId) ?? ""

        let keyCache = sessionKeyCache
        // Look up the provider for this session
        let sessionProvider: (any CodingToolProvider)?
        if let providerName = sessionProviders[request.sessionId],
           let registry = providerRegistry {
            sessionProvider = await registry.provider(for: providerName)
        } else {
            sessionProvider = nil
        }
        Task {
            await executor.execute(
                request: request,
                verifier: commandVerifier,
                nonceStore: commandNonceStore,
                projectPath: projectPath,
                wsClient: client,
                keyCache: keyCache,
                provider: sessionProvider
            )
        }
    }

    func handleCommandNew(_ msg: WSMessage) async {
        guard let executor = commandExecutor, let client = wsClient else {
            AppLogger.command.error("Command executor not configured")
            return
        }

        let decoder = JSONDecoder()
        guard let request = try? decoder.decode(
            CommandExecutor.NewChatRequest.self,
            from: msg.payloadJSON
        ) else {
            AppLogger.command.error("Failed to parse new chat request")
            return
        }

        // Mark todo as in-progress before execution
        if let todoText = request.todoText, !todoText.isEmpty {
            updateTodoStatus(projectPath: request.projectPath, todoText: todoText, from: "- [ ] ", to: "- [*] ")
        }

        let requestProjectPath = request.projectPath
        let todoText = request.todoText
        let sbc = statusBarController
        Task { [sessionIndex, weak self] in
            let newSessionId = await executor.executeNewChat(
                request: request,
                verifier: commandVerifier,
                nonceStore: commandNonceStore,
                wsClient: client
            )

            // Mark todo as done after successful execution
            if let todoText, !todoText.isEmpty, newSessionId != nil {
                self?.updateTodoStatus(projectPath: requestProjectPath, todoText: todoText, from: "- [*] ", to: "- [x] ")
            }

            // Register the new session in SessionIndex so continue commands can find its project path.
            if let newSessionId {
                // Try each provider to find the session file
                var registered = false
                if let registry = await self?.providerRegistry {
                    for provider in await registry.enabledProviders {
                        if let dataPath = await provider.findSessionFile(sessionId: newSessionId) {
                            await sessionIndex.registerDirect(sessionId: newSessionId, projectPath: requestProjectPath)
                            await self?.setSessionProvider(sessionId: newSessionId, provider: provider.identifier)
                            AppLogger.command.info("Registered new chat session \(newSessionId.prefix(8), privacy: .public) → \(requestProjectPath, privacy: .public) [\(provider.identifier, privacy: .public)]")
                            registered = true
                            break
                        }
                    }
                }
                if !registered {
                    AppLogger.command.warning("Could not find data file for new session \(newSessionId.prefix(8), privacy: .public)")
                }

                // Register in menu bar for easy resume
                if let sbc {
                    DispatchQueue.main.async {
                        sbc.addRemoteSession(sessionId: newSessionId, projectPath: requestProjectPath)
                    }
                }
            }
        }
    }

    // MARK: - Session Stop

    func handleSessionStop(_ msg: WSMessage) async {
        struct StopPayload: Codable {
            let sessionId: String
        }
        guard let payload = try? JSONDecoder().decode(StopPayload.self, from: msg.payloadJSON) else {
            AppLogger.command.error("Failed to parse session stop payload")
            return
        }

        let sessionId = payload.sessionId
        AppLogger.command.info("Session stop requested: \(sessionId.prefix(8), privacy: .public)")

        // First, try cancelling any active command from CommandExecutor
        if let executor = commandExecutor {
            await executor.cancel(commandId: sessionId)
        }

        // Find claude processes with this session ID in their arguments and send SIGINT.
        // Claude Code processes use --resume <sessionId> or write to session JSONL files.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", sessionId]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let pids = output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }

            if pids.isEmpty {
                AppLogger.command.warning("No claude process found for session \(sessionId.prefix(8), privacy: .public)")
            }

            for pid in pids {
                kill(pid, SIGINT)
                AppLogger.command.info("Sent SIGINT to pid \(pid, privacy: .public) for session \(sessionId.prefix(8), privacy: .public)")
            }
        } catch {
            AppLogger.command.error("Failed to find processes for session stop: \(error.localizedDescription, privacy: .public)")
        }
    }

    func handleCommandCancel(_ msg: WSMessage) async {
        struct CancelPayload: Codable {
            let commandId: String
        }
        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(CancelPayload.self, from: msg.payloadJSON),
              let executor = commandExecutor else { return }
        await executor.cancel(commandId: payload.commandId)
    }

    // MARK: - Plan Restart Command

    func handlePlanRestart(_ msg: WSMessage) async {
        guard let executor = commandExecutor, let client = wsClient else {
            AppLogger.command.error("Command executor not configured for plan restart")
            return
        }

        struct PlanRestartPayload: Codable {
            let sessionId: String
            let permissionMode: String
            let feedback: String?
        }

        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(PlanRestartPayload.self, from: msg.payloadJSON) else {
            AppLogger.command.error("Failed to parse plan restart payload")
            return
        }

        let sessionId = payload.sessionId
        let mode = payload.permissionMode.isEmpty ? "acceptEdits" : payload.permissionMode

        // Read the saved plan file
        let planPath = BuildEnvironment.configDirectoryPath + "/plans/\(sessionId).md"

        guard FileManager.default.fileExists(atPath: planPath) else {
            AppLogger.command.error("No plan file found at \(planPath, privacy: .public)")
            if let failMsg = try? MessageEncoder.commandFailed(
                commandId: "plan-restart-\(sessionId)",
                sessionId: sessionId,
                error: "No saved plan found for session"
            ) {
                try? await client.send(failMsg)
            }
            return
        }

        // Look up project path from SessionIndex
        let projectPath = await sessionIndex.projectPath(for: sessionId) ?? ""
        guard !projectPath.isEmpty else {
            AppLogger.command.error("No project path found for session \(sessionId.prefix(8), privacy: .public)")
            if let failMsg = try? MessageEncoder.commandFailed(
                commandId: "plan-restart-\(sessionId)",
                sessionId: sessionId,
                error: "No project path found for session"
            ) {
                try? await client.send(failMsg)
            }
            return
        }

        // Build the prompt
        var prompt = "Read and implement the plan at \(planPath)"
        if let feedback = payload.feedback, !feedback.isEmpty {
            prompt += "\n\nUser feedback: \(feedback)"
        }

        // Build a synthetic NewChatRequest to leverage existing executor
        let nonce = UUID().uuidString
        let expiresAt = Int64(Date().timeIntervalSince1970) + 300
        let promptHash = prompt.data(using: .utf8).map {
            SHA256.hash(data: $0).compactMap { String(format: "%02x", $0) }.joined()
        } ?? ""

        let request = CommandExecutor.NewChatRequest(
            commandId: "plan-restart-\(sessionId)",
            projectPath: projectPath,
            prompt: prompt,
            promptHash: promptHash,
            useWorktree: false,
            worktreeName: nil,
            permissionMode: mode,
            todoText: nil,
            nonce: nonce,
            expiresAt: expiresAt,
            signature: ""  // No verifier needed for plan restart
        )

        AppLogger.command.info("Plan restart for session \(sessionId.prefix(8), privacy: .public) with mode=\(mode, privacy: .public)")

        let sbc = statusBarController
        Task { [sessionIndex, weak self] in
            let newSessionId = await executor.executeNewChat(
                request: request,
                verifier: nil,  // Skip verification for plan restart
                nonceStore: commandNonceStore,
                wsClient: client
            )

            if let newSessionId {
                // Try each provider to find the session file
                if let registry = await self?.providerRegistry {
                    for provider in await registry.enabledProviders {
                        if await provider.findSessionFile(sessionId: newSessionId) != nil {
                            await sessionIndex.registerDirect(sessionId: newSessionId, projectPath: projectPath)
                            await self?.setSessionProvider(sessionId: newSessionId, provider: provider.identifier)
                            AppLogger.command.info("Plan restart session \(newSessionId.prefix(8), privacy: .public) → \(projectPath, privacy: .public)")
                            break
                        }
                    }
                }

                // Register in menu bar for easy resume
                if let sbc {
                    DispatchQueue.main.async {
                        sbc.addRemoteSession(sessionId: newSessionId, projectPath: projectPath)
                    }
                }
            }
        }
    }

    // MARK: - Todo Append

    func handleTodoAppend(_ msg: WSMessage) async {
        struct TodoAppendPayload: Codable {
            let projectPath: String
            let text: String
        }
        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(TodoAppendPayload.self, from: msg.payloadJSON) else {
            AppLogger.agent.error("Failed to parse todo append payload")
            return
        }
        appendToTodoFile(projectPath: payload.projectPath, text: payload.text)
    }

    nonisolated func appendToTodoFile(projectPath: String, text: String) {
        let todoPath = (projectPath as NSString).appendingPathComponent("todo.md")
        let fm = FileManager.default
        let line = "\n- [ ] \(text)\n"

        if fm.fileExists(atPath: todoPath) {
            guard let handle = FileHandle(forWritingAtPath: todoPath) else {
                AppLogger.session.error("Failed to open \(todoPath, privacy: .public) for writing")
                return
            }
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        } else {
            let content = "- [ ] \(text)\n"
            fm.createFile(atPath: todoPath, contents: content.data(using: .utf8))
        }
        AppLogger.session.debug("Appended item to \(todoPath, privacy: .public): \(text, privacy: .public)")
    }

    // MARK: - Todo Toggle

    func handleTodoToggle(_ msg: WSMessage) async {
        struct TodoTogglePayload: Codable {
            let projectPath: String
            let line: Int
            let checked: Bool
        }
        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(TodoTogglePayload.self, from: msg.payloadJSON) else {
            AppLogger.agent.error("Failed to parse todo toggle payload")
            return
        }
        toggleTodoLine(projectPath: payload.projectPath, line: payload.line, checked: payload.checked)
    }

    /// Updates a todo item's checkbox prefix by matching text content.
    /// Used to transition todos between states (e.g. `- [ ] ` → `- [*] ` for in-progress).
    nonisolated func updateTodoStatus(projectPath: String, todoText: String, from: String, to: String) {
        let todoPath = (projectPath as NSString).appendingPathComponent("todo.md")
        let fm = FileManager.default

        guard fm.fileExists(atPath: todoPath),
              let data = fm.contents(atPath: todoPath),
              let content = String(data: data, encoding: .utf8) else {
            AppLogger.session.warning("Cannot read \(todoPath, privacy: .public) for todo status update")
            return
        }

        var lines = content.components(separatedBy: "\n")
        var matched = false

        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Match: line contains the `from` prefix followed by the todo text
            if trimmed.hasPrefix(from) {
                let afterPrefix = String(trimmed.dropFirst(from.count))
                if afterPrefix == todoText {
                    lines[idx] = line.replacingOccurrences(of: from, with: to)
                    matched = true
                    AppLogger.session.debug("Updated todo line \(idx + 1, privacy: .public): \(from.trimmingCharacters(in: .whitespaces), privacy: .public) → \(to.trimmingCharacters(in: .whitespaces), privacy: .public)")
                    break
                }
            }
        }

        if matched {
            let updated = lines.joined(separator: "\n")
            try? updated.write(toFile: todoPath, atomically: true, encoding: .utf8)
        } else {
            AppLogger.session.warning("Could not find matching todo item for status update in \(todoPath, privacy: .public)")
        }
    }

    nonisolated func toggleTodoLine(projectPath: String, line: Int, checked: Bool) {
        let todoPath = (projectPath as NSString).appendingPathComponent("todo.md")
        let fm = FileManager.default

        guard fm.fileExists(atPath: todoPath),
              let data = fm.contents(atPath: todoPath),
              let content = String(data: data, encoding: .utf8) else {
            AppLogger.session.error("Cannot read \(todoPath, privacy: .public) for toggle")
            return
        }

        var lines = content.components(separatedBy: "\n")
        let idx = line - 1 // line is 1-based
        guard idx >= 0, idx < lines.count else {
            AppLogger.session.warning("Line \(line, privacy: .public) out of range in \(todoPath, privacy: .public)")
            return
        }

        let currentLine = lines[idx]
        let newLine: String
        if checked {
            // Mark as checked: replace "- [ ]" or "- [*]" with "- [x]"
            newLine = currentLine
                .replacingOccurrences(of: "- [ ] ", with: "- [x] ")
                .replacingOccurrences(of: "- [*] ", with: "- [x] ")
        } else {
            // Mark as unchecked: replace "- [x]", "- [X]", or "- [*]" with "- [ ]"
            newLine = currentLine
                .replacingOccurrences(of: "- [x] ", with: "- [ ] ")
                .replacingOccurrences(of: "- [X] ", with: "- [ ] ")
                .replacingOccurrences(of: "- [*] ", with: "- [ ] ")
        }

        lines[idx] = newLine
        let updated = lines.joined(separator: "\n")
        try? updated.write(toFile: todoPath, atomically: true, encoding: .utf8)
        AppLogger.session.debug("Toggled line \(line, privacy: .public) in \(todoPath, privacy: .public): checked=\(checked, privacy: .public)")
    }
}
