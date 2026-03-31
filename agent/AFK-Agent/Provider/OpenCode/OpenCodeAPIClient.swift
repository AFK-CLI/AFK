//
//  OpenCodeAPIClient.swift
//  AFK-Agent
//
//  Connects to OpenCode's local HTTP server for permission/question handling.
//  OpenCode exposes SSE at GET /event and reply APIs at POST /permission/:id/reply, POST /question/:id/reply.

import Foundation
import OSLog

actor OpenCodeAPIClient {
    private let baseURL: URL
    private let directory: String
    private var sseTask: Task<Void, Never>?
    private(set) var isConnected = false

    var onPermission: (@Sendable (PermissionEvent) async -> Void)?
    var onQuestion: (@Sendable (QuestionEvent) async -> Void)?
    var onSessionStatus: (@Sendable (String, String) async -> Void)?  // sessionId, status ("idle"/"busy")

    init(port: Int, directory: String) {
        self.baseURL = URL(string: "http://localhost:\(port)")!
        self.directory = directory
    }

    func setCallbacks(
        onPermission: @escaping @Sendable (PermissionEvent) async -> Void,
        onQuestion: @escaping @Sendable (QuestionEvent) async -> Void
    ) {
        self.onPermission = onPermission
        self.onQuestion = onQuestion
    }

    // MARK: - SSE Connection

    func connect() {
        guard sseTask == nil else { return }

        sseTask = Task { [weak self] in
            var backoff: TimeInterval = 10
            var consecutiveFailures = 0
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.runSSE()
                    // SSE connected and ran — reset backoff for next reconnect
                    consecutiveFailures = 0
                    backoff = 10
                } catch {
                    await self.setConnected(false)
                    consecutiveFailures += 1
                    if consecutiveFailures == 1 {
                        AppLogger.agent.info("OpenCode SSE: server unavailable on \(self.baseURL.absoluteString, privacy: .public)")
                    } else if consecutiveFailures % 20 == 0 {
                        AppLogger.agent.info("OpenCode SSE: still unavailable after \(consecutiveFailures, privacy: .public) attempts")
                    }
                }
                try? await Task.sleep(for: .seconds(min(backoff, 120)))
                backoff = min(backoff * 2, 120)
            }
        }
    }

    func disconnect() {
        sseTask?.cancel()
        sseTask = nil
        isConnected = false
    }

    private func setConnected(_ value: Bool) {
        isConnected = value
    }

    private func runSSE() async throws {
        // Use /global/event to receive events from ALL project instances.
        // Events arrive as { directory, payload: { type, properties } }.
        let url = baseURL.appendingPathComponent("global/event")

        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = .infinity

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OpenCodeAPIError.sseConnectionFailed
        }

        isConnected = true
        AppLogger.agent.info("OpenCode SSE connected to \(self.baseURL.absoluteString, privacy: .public)")

        // Poll for any pending permissions/questions that were asked before we connected
        await pollPendingPermissions()
        await pollPendingQuestions()

        var buffer = ""
        var eventCount = 0
        for try await line in bytes.lines {
            if line.hasPrefix("data: ") {
                // Process previous buffered event before starting new one
                if !buffer.isEmpty {
                    eventCount += 1
                    if eventCount <= 3 || buffer.contains("permission") || buffer.contains("question") {
                        let preview = buffer.prefix(200)
                        AppLogger.agent.info("OpenCode SSE[\(eventCount, privacy: .public)]: \(preview, privacy: .public)")
                    }
                    await handleSSEData(buffer)
                }
                buffer = String(line.dropFirst(6))
            }
            // Note: AsyncBytes.lines may skip empty lines, so we process
            // the buffer when the next data: line arrives instead.
        }
        // Process final buffered event
        if !buffer.isEmpty {
            await handleSSEData(buffer)
        }
    }

    private func handleSSEData(_ json: String) async {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Global event endpoint wraps as { directory, payload: { type, properties } }
        let type: String
        let props: [String: Any]
        let eventDirectory: String
        if let payload = dict["payload"] as? [String: Any],
           let t = payload["type"] as? String,
           let p = payload["properties"] as? [String: Any] {
            type = t
            props = p
            eventDirectory = dict["directory"] as? String ?? directory
        } else if let t = dict["type"] as? String,
                  let p = dict["properties"] as? [String: Any] {
            type = t
            props = p
            eventDirectory = directory
        } else {
            return
        }

        switch type {
        case "permission.asked":
            if let event = parsePermissionEvent(props, directory: eventDirectory) {
                await onPermission?(event)
            }

        case "question.asked":
            if let event = parseQuestionEvent(props, directory: eventDirectory) {
                await onQuestion?(event)
            }

        case "session.status":
            if let sessionId = props["sessionID"] as? String,
               let status = props["status"] as? [String: Any],
               let statusType = status["type"] as? String {
                await onSessionStatus?(sessionId, statusType)
            }

        default:
            break
        }
    }

    // MARK: - Pending Permission/Question Polling

    /// Check for pending permissions that were asked before SSE connected.
    private func pollPendingPermissions() async {
        guard let data = try? await get(path: "permission") else { return }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for props in array {
            if let event = parsePermissionEvent(props) {
                AppLogger.agent.info("OpenCode: found pending permission \(event.id.prefix(8), privacy: .public)")
                await onPermission?(event)
            }
        }
    }

    /// Check for pending questions that were asked before SSE connected.
    private func pollPendingQuestions() async {
        guard let data = try? await get(path: "question") else { return }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for props in array {
            if let event = parseQuestionEvent(props) {
                AppLogger.agent.info("OpenCode: found pending question \(event.id.prefix(8), privacy: .public)")
                await onQuestion?(event)
            }
        }
    }

    // MARK: - Reply APIs

    func replyPermission(requestId: String, reply: String, message: String? = nil, directory: String? = nil) async throws {
        var body: [String: Any] = ["reply": reply]
        if let message { body["message"] = message }
        try await post(path: "permission/\(requestId)/reply", body: body, directory: directory)
        AppLogger.agent.info("OpenCode: replied permission \(requestId.prefix(8), privacy: .public) with \(reply, privacy: .public) dir=\(directory ?? "default", privacy: .public)")
    }

    func replyQuestion(requestId: String, answers: [[String]], directory: String? = nil) async throws {
        let body: [String: Any] = ["answers": answers]
        try await post(path: "question/\(requestId)/reply", body: body, directory: directory)
        AppLogger.agent.info("OpenCode: replied question \(requestId.prefix(8), privacy: .public)")
    }

    func rejectQuestion(requestId: String, directory: String? = nil) async throws {
        try await post(path: "question/\(requestId)/reject", body: [:], directory: directory)
        AppLogger.agent.info("OpenCode: rejected question \(requestId.prefix(8), privacy: .public)")
    }

    func abortSession(sessionId: String) async throws {
        try await post(path: "session/\(sessionId)/abort", body: [:])
        AppLogger.agent.info("OpenCode: aborted session \(sessionId.prefix(8), privacy: .public)")
    }

    func promptAsync(sessionId: String, text: String) async throws {
        let body: [String: Any] = [
            "parts": [["type": "text", "text": text]]
        ]
        try await post(path: "session/\(sessionId)/prompt_async", body: body)
    }

    // MARK: - Discovery

    static func detectPort() async -> Int? {
        for port in [4096] {
            let url = URL(string: "http://localhost:\(port)/global/health")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 1.5
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse,
               http.statusCode == 200 {
                return port
            }
        }
        return nil
    }

    // MARK: - HTTP Helpers

    private func get(path: String) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.setValue(directory, forHTTPHeaderField: "x-opencode-directory")
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw OpenCodeAPIError.httpError(status)
        }
        return data
    }

    private func post(path: String, body: [String: Any], directory dirOverride: String? = nil) async throws {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(dirOverride ?? directory, forHTTPHeaderField: "x-opencode-directory")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw OpenCodeAPIError.httpError(status)
        }
    }

    // MARK: - SSE Event Parsing

    private func parsePermissionEvent(_ props: [String: Any], directory: String = "") -> PermissionEvent? {
        guard let id = props["id"] as? String,
              let sessionId = props["sessionID"] as? String,
              let permission = props["permission"] as? String else {
            return nil
        }

        let patterns = props["patterns"] as? [String] ?? []
        let alwaysPatterns = props["always"] as? [String] ?? []

        // Parse metadata
        var metadata: [String: String] = [:]
        if let meta = props["metadata"] as? [String: Any] {
            for (key, value) in meta {
                if let str = value as? String {
                    metadata[key] = str
                }
            }
        }

        // Parse tool reference
        var toolCallId = ""
        if let tool = props["tool"] as? [String: Any] {
            toolCallId = tool["callID"] as? String ?? ""
        }

        return PermissionEvent(
            id: id,
            sessionId: sessionId,
            directory: directory,
            permission: permission,
            patterns: patterns,
            metadata: metadata,
            alwaysPatterns: alwaysPatterns,
            toolCallId: toolCallId
        )
    }

    private func parseQuestionEvent(_ props: [String: Any], directory: String = "") -> QuestionEvent? {
        guard let id = props["id"] as? String,
              let sessionId = props["sessionID"] as? String,
              let questionsArray = props["questions"] as? [[String: Any]] else {
            return nil
        }

        let questions: [QuestionEvent.QuestionItem] = questionsArray.compactMap { q in
            guard let question = q["question"] as? String else { return nil }
            let header = q["header"] as? String ?? ""
            let options: [QuestionEvent.QuestionOption] = (q["options"] as? [[String: Any]] ?? []).compactMap { opt in
                guard let label = opt["label"] as? String else { return nil }
                let desc = opt["description"] as? String ?? ""
                return QuestionEvent.QuestionOption(label: label, description: desc)
            }
            return QuestionEvent.QuestionItem(question: question, header: header, options: options)
        }

        return QuestionEvent(
            id: id,
            sessionId: sessionId,
            directory: directory,
            questions: questions
        )
    }

    // MARK: - Types

    struct PermissionEvent: Sendable {
        let id: String
        let sessionId: String
        let directory: String
        let permission: String
        let patterns: [String]
        let metadata: [String: String]
        let alwaysPatterns: [String]
        let toolCallId: String
    }

    struct QuestionEvent: Sendable {
        let id: String
        let sessionId: String
        let directory: String
        let questions: [QuestionItem]

        struct QuestionItem: Sendable {
            let question: String
            let header: String
            let options: [QuestionOption]
        }
        struct QuestionOption: Sendable {
            let label: String
            let description: String
        }
    }

    enum OpenCodeAPIError: Error {
        case sseConnectionFailed
        case httpError(Int)
    }
}
