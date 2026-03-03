//
//  Agent+Commands.swift
//  AFK-Agent
//

import Foundation
import CryptoKit

extension Agent {

    func handleCommandContinue(_ msg: WSMessage) async {
        guard let executor = commandExecutor, let client = wsClient else {
            print("[Agent] Command executor not configured")
            return
        }

        let decoder = JSONDecoder()
        guard let request = try? decoder.decode(
            CommandExecutor.CommandRequest.self,
            from: msg.payloadJSON
        ) else {
            print("[Agent] Failed to parse command request")
            return
        }

        // Look up project path from session index
        let projectPath = await sessionIndex.projectPath(for: request.sessionId) ?? ""

        Task {
            await executor.execute(
                request: request,
                verifier: commandVerifier,
                nonceStore: commandNonceStore,
                projectPath: projectPath,
                wsClient: client
            )
        }
    }

    func handleCommandNew(_ msg: WSMessage) async {
        guard let executor = commandExecutor, let client = wsClient else {
            print("[Agent] Command executor not configured")
            return
        }

        let decoder = JSONDecoder()
        guard let request = try? decoder.decode(
            CommandExecutor.NewChatRequest.self,
            from: msg.payloadJSON
        ) else {
            print("[Agent] Failed to parse new chat request")
            return
        }

        let projectsPath = config.claudeProjectsPath
        let requestProjectPath = request.projectPath
        let sbc = statusBarController
        Task { [sessionIndex] in
            let newSessionId = await executor.executeNewChat(
                request: request,
                verifier: commandVerifier,
                nonceStore: commandNonceStore,
                wsClient: client
            )

            // Register the new session in SessionIndex so continue commands can find its project path.
            if let newSessionId {
                if let jsonlPath = Self.findJSONLFile(sessionId: newSessionId, under: projectsPath) {
                    let (_, projectPath) = await sessionIndex.register(filePath: jsonlPath)
                    print("[Agent] Registered new chat session \(newSessionId.prefix(8)) → \(projectPath)")
                } else {
                    print("[Agent] WARNING: Could not find JSONL for new session \(newSessionId.prefix(8))")
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
            print("[Agent] Command executor not configured for plan restart")
            return
        }

        struct PlanRestartPayload: Codable {
            let sessionId: String
            let permissionMode: String
            let feedback: String?
        }

        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(PlanRestartPayload.self, from: msg.payloadJSON) else {
            print("[Agent] Failed to parse plan restart payload")
            return
        }

        let sessionId = payload.sessionId
        let mode = payload.permissionMode.isEmpty ? "acceptEdits" : payload.permissionMode

        // Read the saved plan file
        let planPath = BuildEnvironment.configDirectoryPath + "/plans/\(sessionId).md"

        guard FileManager.default.fileExists(atPath: planPath) else {
            print("[Agent] No plan file found at \(planPath)")
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
            print("[Agent] No project path found for session \(sessionId)")
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
            nonce: nonce,
            expiresAt: expiresAt,
            signature: ""  // No verifier needed for plan restart
        )

        print("[Agent] Plan restart for session \(sessionId.prefix(8)) with mode=\(mode)")

        let projectsPath = config.claudeProjectsPath
        let sbc = statusBarController
        Task { [sessionIndex] in
            let newSessionId = await executor.executeNewChat(
                request: request,
                verifier: nil,  // Skip verification for plan restart
                nonceStore: commandNonceStore,
                wsClient: client
            )

            if let newSessionId {
                if let jsonlPath = Self.findJSONLFile(sessionId: newSessionId, under: projectsPath) {
                    let (_, projPath) = await sessionIndex.register(filePath: jsonlPath)
                    print("[Agent] Plan restart session \(newSessionId.prefix(8)) → \(projPath)")
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
            print("[Agent] Failed to parse todo append payload")
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
                print("[TodoWatcher] Failed to open \(todoPath) for writing")
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
        print("[TodoWatcher] Appended item to \(todoPath): \(text)")
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
            print("[Agent] Failed to parse todo toggle payload")
            return
        }
        toggleTodoLine(projectPath: payload.projectPath, line: payload.line, checked: payload.checked)
    }

    nonisolated func toggleTodoLine(projectPath: String, line: Int, checked: Bool) {
        let todoPath = (projectPath as NSString).appendingPathComponent("todo.md")
        let fm = FileManager.default

        guard fm.fileExists(atPath: todoPath),
              let data = fm.contents(atPath: todoPath),
              let content = String(data: data, encoding: .utf8) else {
            print("[TodoWatcher] Cannot read \(todoPath) for toggle")
            return
        }

        var lines = content.components(separatedBy: "\n")
        let idx = line - 1 // line is 1-based
        guard idx >= 0, idx < lines.count else {
            print("[TodoWatcher] Line \(line) out of range in \(todoPath)")
            return
        }

        let currentLine = lines[idx]
        let newLine: String
        if checked {
            // Mark as checked: replace "- [ ]" with "- [x]"
            newLine = currentLine.replacingOccurrences(of: "- [ ] ", with: "- [x] ")
        } else {
            // Mark as unchecked: replace "- [x]" or "- [X]" with "- [ ]"
            newLine = currentLine
                .replacingOccurrences(of: "- [x] ", with: "- [ ] ")
                .replacingOccurrences(of: "- [X] ", with: "- [ ] ")
        }

        lines[idx] = newLine
        let updated = lines.joined(separator: "\n")
        try? updated.write(toFile: todoPath, atomically: true, encoding: .utf8)
        print("[TodoWatcher] Toggled line \(line) in \(todoPath): checked=\(checked)")
    }
}
