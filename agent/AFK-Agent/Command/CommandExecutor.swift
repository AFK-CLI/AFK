//
//  CommandExecutor.swift
//  AFK-Agent
//

import Foundation
import OSLog

actor CommandExecutor {
    private let redactor = ContentRedactor()
    private var activeProcess: Process?
    private var activeCommandId: String?
    private var isCancelled = false

    struct ImageAttachment: Codable, Sendable {
        let mediaType: String
        let data: String
    }

    struct CommandRequest: Codable, Sendable {
        let commandId: String
        let sessionId: String
        let prompt: String
        let promptEncrypted: String?
        let images: [ImageAttachment]?
        let imagesEncrypted: [ImageAttachment]?
        let promptHash: String
        let nonce: String
        let expiresAt: Int64
        let signature: String
    }

    struct NewChatRequest: Codable, Sendable {
        let commandId: String
        let projectPath: String
        let prompt: String
        let promptHash: String
        let useWorktree: Bool
        let worktreeName: String?
        let permissionMode: String?
        let nonce: String
        let expiresAt: Int64
        let signature: String
    }

    private struct ClaudeJSONResult: Codable {
        let session_id: String?
        let cost_usd: Double?
        let duration_ms: Int?
        let result: String?
        let is_error: Bool?
    }

    func execute(request: CommandRequest, verifier: CommandVerifier?, nonceStore: NonceStore, projectPath: String, wsClient: WebSocketClient, keyCache: SessionKeyCache? = nil) async {
        isCancelled = false

        do {
            // 1. Verify server signature (skip when no verifier configured)
            if let verifier {
                let signedCmd = CommandVerifier.SignedCommand(
                    commandId: request.commandId,
                    sessionId: request.sessionId,
                    promptHash: request.promptHash,
                    nonce: request.nonce,
                    expiresAt: request.expiresAt,
                    signature: request.signature
                )
                try await verifier.verify(signedCmd, nonceStore: nonceStore)
            } else {
                AppLogger.command.warning("No verifier configured — skipping signature verification")
            }

            // 2. Decrypt prompt and images if E2EE is active
            let prompt: String
            if let encrypted = request.promptEncrypted, !encrypted.isEmpty,
               let keyCache,
               let decrypted = keyCache.decryptString(encrypted, sessionId: request.sessionId) {
                prompt = decrypted
                AppLogger.command.info("Decrypted E2EE prompt for session \(request.sessionId.prefix(8), privacy: .public)")
            } else {
                prompt = request.prompt
            }

            let images: [ImageAttachment]?
            if let encryptedImages = request.imagesEncrypted, !encryptedImages.isEmpty, let keyCache {
                images = decryptImages(encryptedImages, sessionId: request.sessionId, keyCache: keyCache)
            } else {
                images = request.images
            }

            // 3. Resolve claude path and build args — resume in-place (no forking)
            let claudePath = try CommandValidator.resolveClaudePath()

            // Save attached images to temp files and build prompt with references
            let effectivePrompt = saveImagesAndBuildPrompt(prompt: prompt, images: images, projectPath: projectPath)

            let args = [claudePath, "--resume", request.sessionId, "-p", effectivePrompt, "--output-format", "json"]
            try CommandValidator.validate(args: args)

            AppLogger.command.info("Resuming session: \(request.sessionId.prefix(8), privacy: .public)")

            // 3. Send ack
            let ackMsg = try MessageEncoder.commandAck(
                commandId: request.commandId,
                sessionId: request.sessionId
            )
            try await wsClient.send(ackMsg)

            // 4. Execute process and collect JSON output
            let commandId = request.commandId
            let sessionId = request.sessionId
            let newSessionId = try await runClaudeProcess(
                claudePath: claudePath,
                args: Array(args.dropFirst()),
                projectPath: projectPath,
                commandId: commandId,
                sessionId: sessionId,
                wsClient: wsClient
            )

            if let sid = newSessionId {
                AppLogger.command.info("Session continued: \(sid.prefix(8), privacy: .public)")
            }

        } catch {
            AppLogger.command.error("Error: \(error.localizedDescription, privacy: .public)")
            if let failMsg = try? MessageEncoder.commandFailed(
                commandId: request.commandId,
                sessionId: request.sessionId,
                error: error.localizedDescription
            ) {
                try? await wsClient.send(failMsg)
            }
        }

        self.activeProcess = nil
        self.activeCommandId = nil
        self.isCancelled = false
    }

    /// Execute a new chat command. Returns the new session ID if one was created.
    func executeNewChat(request: NewChatRequest, verifier: CommandVerifier?, nonceStore: NonceStore, wsClient: WebSocketClient) async -> String? {
        isCancelled = false
        var resultSessionId: String?

        do {
            // 1. Verify server signature (empty sessionId in canonical string for new chat)
            if let verifier {
                let signedCmd = CommandVerifier.SignedCommand(
                    commandId: request.commandId,
                    sessionId: "",
                    promptHash: request.promptHash,
                    nonce: request.nonce,
                    expiresAt: request.expiresAt,
                    signature: request.signature
                )
                try await verifier.verify(signedCmd, nonceStore: nonceStore)
            } else {
                AppLogger.command.warning("No verifier configured — skipping signature verification")
            }

            // 2. Resolve claude path and build args
            let claudePath = try CommandValidator.resolveClaudePath()
            var args = [claudePath, "-p", request.prompt, "--output-format", "json"]
            if let mode = request.permissionMode, !mode.isEmpty, mode != "default" {
                args.append(contentsOf: ["--permission-mode", mode])
            }
            if request.useWorktree {
                if let name = request.worktreeName, !name.isEmpty {
                    args.append(contentsOf: ["-w", name])
                } else {
                    args.append("--worktree")
                }
            }
            try CommandValidator.validate(args: args)

            // 3. Send ack (with empty sessionId since we don't have one yet)
            let ackMsg = try MessageEncoder.commandAck(
                commandId: request.commandId,
                sessionId: ""
            )
            try await wsClient.send(ackMsg)

            // 4. Execute process and collect JSON output
            resultSessionId = try await runClaudeProcess(
                claudePath: claudePath,
                args: Array(args.dropFirst()),
                projectPath: request.projectPath,
                commandId: request.commandId,
                sessionId: "",
                wsClient: wsClient
            )

        } catch {
            AppLogger.command.error("Error: \(error.localizedDescription, privacy: .public)")
            if let failMsg = try? MessageEncoder.commandFailed(
                commandId: request.commandId,
                sessionId: "",
                error: error.localizedDescription
            ) {
                try? await wsClient.send(failMsg)
            }
        }

        self.activeProcess = nil
        self.activeCommandId = nil
        self.isCancelled = false
        return resultSessionId
    }

    /// Shared process execution logic for both continue and new chat commands.
    /// Returns the new session ID (fork or new chat) if one was created.
    @discardableResult
    private func runClaudeProcess(claudePath: String, args: [String], projectPath: String, commandId: String, sessionId: String, wsClient: WebSocketClient) async throws -> String? {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = args
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if !projectPath.isEmpty, FileManager.default.fileExists(atPath: projectPath) {
            process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
            AppLogger.command.info("Working directory: \(projectPath, privacy: .public)")
        } else {
            AppLogger.command.warning("Project path not found: \(projectPath, privacy: .public)")
        }

        self.activeProcess = process
        self.activeCommandId = commandId

        try process.run()
        process.waitUntilExit()

        if isCancelled {
            let cancelledMsg = try MessageEncoder.commandCancelled(
                commandId: commandId,
                sessionId: sessionId
            )
            try await wsClient.send(cancelledMsg)
            AppLogger.command.info("Command \(commandId, privacy: .public) cancelled")
            return nil
        }

        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
            let failMsg = try MessageEncoder.commandFailed(
                commandId: commandId,
                sessionId: sessionId,
                error: redactor.redact(stderrText)
            )
            try await wsClient.send(failMsg)
            return nil
        }

        // Parse JSON output
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        var durationMs: Int?
        var costUsd: Double?
        var newSessionId: String?

        if let jsonResult = try? JSONDecoder().decode(ClaudeJSONResult.self, from: stdoutData) {
            durationMs = jsonResult.duration_ms
            costUsd = jsonResult.cost_usd
            newSessionId = jsonResult.session_id

            // Send result text as a single chunk
            if let resultText = jsonResult.result, !resultText.isEmpty {
                let redactedText = redactor.redact(resultText)
                let chunkMsg = try MessageEncoder.commandChunk(
                    commandId: commandId,
                    sessionId: sessionId,
                    text: redactedText,
                    seq: 1
                )
                try? await wsClient.send(chunkMsg)
            }
        } else if let text = String(data: stdoutData, encoding: .utf8), !text.isEmpty {
            // Fallback: send raw output as chunk
            let redactedText = redactor.redact(text)
            let chunkMsg = try MessageEncoder.commandChunk(
                commandId: commandId,
                sessionId: sessionId,
                text: redactedText,
                seq: 1
            )
            try? await wsClient.send(chunkMsg)
        }

        let doneMsg = try MessageEncoder.commandDone(
            commandId: commandId,
            sessionId: sessionId,
            durationMs: durationMs,
            costUsd: costUsd,
            newSessionId: newSessionId
        )
        try await wsClient.send(doneMsg)

        return newSessionId
    }

    // MARK: - Image Handling

    /// Decrypt encrypted image attachments using the E2EE session key.
    private func decryptImages(_ encrypted: [ImageAttachment], sessionId: String, keyCache: SessionKeyCache) -> [ImageAttachment] {
        var decrypted: [ImageAttachment] = []
        for img in encrypted {
            // The `data` field contains the versioned-encrypted base64 image data
            if let rawData = keyCache.decryptData(img.data, sessionId: sessionId) {
                decrypted.append(ImageAttachment(
                    mediaType: img.mediaType,
                    data: rawData.base64EncodedString()
                ))
                AppLogger.command.debug("Decrypted E2EE image attachment (\(rawData.count, privacy: .public) bytes)")
            } else {
                AppLogger.command.warning("Failed to decrypt E2EE image attachment")
            }
        }
        return decrypted
    }

    /// Saves attached images to a temp directory and appends a note to the
    /// prompt so Claude can read them with the Read tool.
    private func saveImagesAndBuildPrompt(prompt: String, images: [ImageAttachment]?, projectPath: String) -> String {
        guard let images, !images.isEmpty else { return prompt }

        let fm = FileManager.default
        let tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("afk-uploads")
        try? fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

        var savedPaths: [String] = []
        for (index, img) in images.enumerated() {
            guard let data = Data(base64Encoded: img.data) else { continue }
            let ext = img.mediaType.contains("png") ? "png" : "jpg"
            let filename = "upload-\(UUID().uuidString.prefix(8))-\(index).\(ext)"
            let filePath = (tempDir as NSString).appendingPathComponent(filename)
            if fm.createFile(atPath: filePath, contents: data) {
                savedPaths.append(filePath)
                AppLogger.command.info("Saved uploaded image to \(filePath, privacy: .public)")
            }
        }

        guard !savedPaths.isEmpty else { return prompt }

        let fileList = savedPaths.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return "\(prompt)\n\nThe user has attached images from their mobile device. Use the Read tool to view them:\n\(fileList)"
    }

    /// Cancel the active command if it matches
    func cancel(commandId: String) {
        guard activeCommandId == commandId else { return }
        isCancelled = true
        activeProcess?.terminate()
        AppLogger.command.info("Terminating process for command \(commandId, privacy: .public)")
    }

}
