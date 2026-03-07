import Foundation
import OSLog

@Observable
final class APIClient {
    private let authService: AuthService

    var baseURL: String { AppConfig.apiBaseURL }

    init(authService: AuthService) {
        self.authService = authService
    }

    // MARK: - Devices

    func listDevices() async throws -> [Device] {
        try await request("GET", "/v1/devices")
    }

    func enrollDevice(name: String, publicKey: String, systemInfo: String, keyAgreementPublicKey: String? = nil, capabilities: [String]? = nil, deviceId: String? = nil) async throws -> Device {
        let body = EnrollDeviceBody(name: name, publicKey: publicKey, systemInfo: systemInfo, keyAgreementPublicKey: keyAgreementPublicKey, capabilities: capabilities, deviceId: deviceId)
        return try await request("POST", "/v1/devices", body: body)
    }

    func deleteDevice(id: String) async throws {
        let _: EmptyResponse = try await request("DELETE", "/v1/devices/\(id)")
    }

    // MARK: - Sessions

    func listSessions(deviceId: String? = nil, status: String? = nil) async throws -> [Session] {
        var queryItems: [URLQueryItem] = []
        if let deviceId {
            queryItems.append(URLQueryItem(name: "device_id", value: deviceId))
        }
        if let status {
            queryItems.append(URLQueryItem(name: "status", value: status))
        }
        return try await request("GET", "/v1/sessions", queryItems: queryItems.isEmpty ? nil : queryItems)
    }

    func getSession(id: String) async throws -> (Session, [SessionEvent]) {
        let response: SessionDetailResponse = try await request("GET", "/v1/sessions/\(id)")
        return (response.session, response.events ?? [])
    }

    func getSessionEvents(sessionId: String, limit: Int = 100) async throws -> (events: [SessionEvent], hasMore: Bool) {
        let response: PaginatedEventsResponse = try await request(
            "GET", "/v1/sessions/\(sessionId)",
            queryItems: [URLQueryItem(name: "limit", value: "\(limit)")]
        )
        return (response.events ?? [], response.hasMore)
    }

    func getOlderEvents(sessionId: String, beforeSeq: Int, limit: Int = 100) async throws -> (events: [SessionEvent], hasMore: Bool) {
        let response: PaginatedEventsResponse = try await request(
            "GET", "/v1/sessions/\(sessionId)",
            queryItems: [
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "before_seq", value: "\(beforeSeq)")
            ]
        )
        return (response.events ?? [], response.hasMore)
    }

    // MARK: - Commands

    func continueSession(sessionId: String, prompt: String, promptEncrypted: String? = nil, images: [ImageAttachment]? = nil, imagesEncrypted: [ImageAttachment]? = nil) async throws -> ContinueResponse {
        let body = ContinueBody(
            prompt: prompt,
            promptEncrypted: promptEncrypted,
            images: images,
            imagesEncrypted: imagesEncrypted,
            nonce: UUID().uuidString,
            expiresAt: Int64(Date().timeIntervalSince1970) + 120
        )
        return try await request("POST", "/v2/sessions/\(sessionId)/continue", body: body)
    }

    // MARK: - New Chat

    func newChat(prompt: String, promptEncrypted: String? = nil,
                 projectPath: String, deviceId: String, useWorktree: Bool,
                 worktreeName: String? = nil,
                 permissionMode: String? = nil) async throws -> ContinueResponse {
        let body = NewChatBody(
            prompt: prompt,
            promptEncrypted: promptEncrypted,
            projectPath: projectPath,
            deviceId: deviceId,
            useWorktree: useWorktree,
            worktreeName: worktreeName,
            permissionMode: permissionMode,
            nonce: UUID().uuidString,
            expiresAt: Int64(Date().timeIntervalSince1970) + 120
        )
        return try await request("POST", "/v1/commands/new", body: body)
    }

    // MARK: - Cancel Command

    func cancelCommand(sessionId: String, commandId: String) async throws {
        struct Body: Encodable { let commandId: String }
        let _: CancelResponse = try await request("POST", "/v2/sessions/\(sessionId)/cancel", body: Body(commandId: commandId))
    }

    // MARK: - Live Activity

    func registerLiveActivityToken(sessionId: String, pushToken: String) async throws {
        struct Body: Encodable { let pushToken: String }
        let _: EmptyResponse = try await request("POST", "/v2/sessions/\(sessionId)/live-activity-token", body: Body(pushToken: pushToken))
    }

    // MARK: - Push-to-Start Token

    func registerPushToStartToken(_ token: String) async throws {
        struct Body: Encodable { let token: String }
        let _: EmptyResponse = try await request("POST", "/v1/push-to-start-token", body: Body(token: token))
    }

    // MARK: - WebSocket Ticket

    func getWSTicket(deviceId: String? = nil) async throws -> String {
        var path = "/v1/auth/ws-ticket"
        if let deviceId, !deviceId.isEmpty {
            path += "?deviceId=\(deviceId)"
        }
        let response: TicketResponse = try await request("POST", path)
        return response.ticket
    }

    // MARK: - Push Tokens

    func registerPushToken(deviceToken: String, platform: String = "ios", bundleId: String = Bundle.main.bundleIdentifier ?? "") async throws {
        let body = RegisterPushTokenBody(deviceToken: deviceToken, platform: platform, bundleId: bundleId)
        let _: EmptyResponse = try await request("POST", "/v1/push-tokens", body: body)
    }

    func unregisterPushToken(deviceToken: String) async throws {
        let body = UnregisterPushTokenBody(deviceToken: deviceToken)
        let _: EmptyResponse = try await request("DELETE", "/v1/push-tokens", body: body)
    }

    // MARK: - Notification Preferences

    func getNotificationPreferences() async throws -> NotificationPreferences {
        try await request("GET", "/v1/notification-preferences")
    }

    func updateNotificationPreferences(_ prefs: NotificationPreferences) async throws {
        let _: EmptyResponse = try await request("PUT", "/v1/notification-preferences", body: prefs)
    }

    // MARK: - Projects

    func listProjects() async throws -> [Project] {
        try await request("GET", "/v1/projects")
    }

    // MARK: - Tasks

    func listTasks(source: String? = nil, projectId: String? = nil, status: String? = nil) async throws -> [AFKTask] {
        var queryItems: [URLQueryItem] = []
        if let source { queryItems.append(URLQueryItem(name: "source", value: source)) }
        if let projectId { queryItems.append(URLQueryItem(name: "project_id", value: projectId)) }
        if let status { queryItems.append(URLQueryItem(name: "status", value: status)) }
        return try await request("GET", "/v1/tasks", queryItems: queryItems.isEmpty ? nil : queryItems)
    }

    func createTask(subject: String, description: String = "", projectId: String? = nil) async throws -> AFKTask {
        struct Body: Encodable {
            let subject: String
            let description: String
            let projectId: String?
        }
        return try await request("POST", "/v1/tasks", body: Body(subject: subject, description: description, projectId: projectId))
    }

    func updateTask(id: String, subject: String? = nil, description: String? = nil, status: String? = nil) async throws -> AFKTask {
        struct Body: Encodable {
            let subject: String?
            let description: String?
            let status: String?
        }
        return try await request("PUT", "/v1/tasks/\(id)", body: Body(subject: subject, description: description, status: status))
    }

    func deleteTask(id: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await request("DELETE", "/v1/tasks/\(id)")
    }

    // MARK: - Todos

    func listTodos() async throws -> [ProjectTodos] {
        try await request("GET", "/v1/todos")
    }

    func appendTodo(projectId: String, text: String) async throws {
        struct Body: Encodable {
            let projectId: String
            let text: String
        }
        let _: EmptyResponse = try await request("POST", "/v1/todos/append", body: Body(projectId: projectId, text: text))
    }

    func toggleTodo(projectId: String, line: Int, checked: Bool) async throws {
        struct Body: Encodable {
            let projectId: String
            let line: Int
            let checked: Bool
        }
        let _: EmptyResponse = try await request("POST", "/v1/todos/toggle", body: Body(projectId: projectId, line: line, checked: checked))
    }

    func startTodoSession(projectId: String, deviceId: String, todoText: String, useWorktree: Bool, permissionMode: String) async throws -> String {
        struct Body: Encodable {
            let projectId: String
            let deviceId: String
            let todoText: String
            let useWorktree: Bool
            let permissionMode: String
        }
        let response: ContinueResponse = try await request("POST", "/v1/todos/start-session", body: Body(
            projectId: projectId,
            deviceId: deviceId,
            todoText: todoText,
            useWorktree: useWorktree,
            permissionMode: permissionMode
        ))
        return response.commandId
    }

    // MARK: - Key Agreement (E2EE)

    func registerKeyAgreement(deviceId: String, publicKey: String) async throws {
        struct Body: Encodable { let publicKey: String }
        let _: KeyAgreementResponse = try await request("POST", "/v1/devices/\(deviceId)/key-agreement", body: Body(publicKey: publicKey))
    }

    func getPeerKeyAgreement(deviceId: String) async throws -> PeerKeyResponse {
        try await request("GET", "/v1/devices/\(deviceId)/key-agreement")
    }

    func getPeerKeyByVersion(deviceId: String, version: Int) async throws -> PeerKeyVersionResponse {
        try await request("GET", "/v1/devices/\(deviceId)/key-agreement/\(version)")
    }

    // MARK: - Audit Log

    func getAuditLog(limit: Int = 50, offset: Int = 0) async throws -> [AuditLogEntry] {
        try await request("GET", "/v1/audit", queryItems: [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ])
    }

    // MARK: - Logs

    func getAppLogs(level: String? = nil, deviceId: String? = nil, source: String? = nil, subsystem: String? = nil, limit: Int = 50, offset: Int = 0) async throws -> [AppLogEntry] {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ]
        if let level { queryItems.append(URLQueryItem(name: "level", value: level)) }
        if let deviceId { queryItems.append(URLQueryItem(name: "device_id", value: deviceId)) }
        if let source { queryItems.append(URLQueryItem(name: "source", value: source)) }
        if let subsystem { queryItems.append(URLQueryItem(name: "subsystem", value: subsystem)) }
        return try await request("GET", "/v1/logs", queryItems: queryItems)
    }

    func uploadLogs(_ entries: [AppLogUploadEntry]) async throws {
        struct Body: Encodable { let entries: [AppLogUploadEntry] }
        let _: EmptyResponse = try await request("POST", "/v1/logs", body: Body(entries: entries))
    }

    // MARK: - Feedback

    func listFeedback(limit: Int = 50, offset: Int = 0) async throws -> [FeedbackEntry] {
        try await request("GET", "/v1/feedback", queryItems: [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ])
    }

    func submitFeedback(deviceId: String, category: String, message: String, appVersion: String, platform: String = "ios") async throws -> FeedbackEntry {
        struct Body: Encodable {
            let deviceId: String
            let category: String
            let message: String
            let appVersion: String
            let platform: String
        }
        return try await request("POST", "/v1/feedback", body: Body(
            deviceId: deviceId, category: category, message: message,
            appVersion: appVersion, platform: platform
        ))
    }

    // MARK: - Subscription

    func getSubscriptionStatus() async throws -> SubscriptionStatusResponse {
        try await request("GET", "/v1/subscription/status")
    }

    func syncSubscriptionReceipt(originalTransactionId: String, productId: String, expiresAt: String?) async throws {
        struct Body: Encodable {
            let originalTransactionId: String
            let productId: String
            let expiresAt: String?
        }
        let _: EmptyResponse = try await request("POST", "/v1/subscription/sync", body: Body(
            originalTransactionId: originalTransactionId,
            productId: productId,
            expiresAt: expiresAt
        ))
    }

    // MARK: - Generic Request

    private func request<T: Decodable>(
        _ method: String,
        _ path: String,
        body: (any Encodable)? = nil,
        queryItems: [URLQueryItem]? = nil,
        isRetryAfterRefresh: Bool = false
    ) async throws -> T {
        var components = URLComponents(string: "\(baseURL)\(path)")!
        if let queryItems {
            components.queryItems = (components.queryItems ?? []) + queryItems
        }

        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let token = authService.accessToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            AppLogger.api.warning("No access token for \(method, privacy: .public) \(path, privacy: .public)")
        }

        if let body {
            req.httpBody = try JSONSerialization.data(
                withJSONObject: jsonObject(from: body)
            )
        }

        AppLogger.api.debug("\(method, privacy: .public) \(components.url?.absoluteString ?? path, privacy: .public)")

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let http = response as? HTTPURLResponse else {
            AppLogger.api.error("Not an HTTP response for \(path, privacy: .public)")
            throw URLError(.badServerResponse)
        }

        AppLogger.api.debug("\(method, privacy: .public) \(path, privacy: .public) -> \(http.statusCode, privacy: .public) (\(data.count, privacy: .public) bytes)")

        if http.statusCode == 401 && !isRetryAfterRefresh {
            AppLogger.api.info("401 — refreshing token and retrying (once)")
            try await authService.refreshAccessToken()
            return try await request(method, path, body: body, queryItems: queryItems, isRetryAfterRefresh: true)
        }

        if http.statusCode == 402 {
            var message = "Upgrade required"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let serverMsg = json["error"] as? String {
                message = serverMsg
            }
            throw SubscriptionError.upgradeRequired(message)
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(binary)"
            AppLogger.api.error("HTTP \(http.statusCode, privacy: .public) body: \(body.prefix(500), privacy: .public)")
            // Try to extract server error message from JSON response
            var message = "Server error \(http.statusCode)"
            if let jsonData = data as Data?,
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let serverMsg = json["error"] as? String {
                message = serverMsg
            } else if http.statusCode >= 500 {
                message = "Server unavailable (\(http.statusCode)). Please try again."
            }
            throw NSError(domain: "AFKAPIError", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }

        let decoder = AppConfig.makeJSONDecoder()
        do {
            let result = try decoder.decode(T.self, from: data)
            return result
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "(binary)"
            AppLogger.api.error("DECODE ERROR for \(path, privacy: .public): \(error, privacy: .public)")
            AppLogger.api.debug("Raw response: \(raw.prefix(1000))")
            throw error
        }
    }

    private func jsonObject(from encodable: any Encodable) throws -> Any {
        let data = try JSONEncoder().encode(encodable)
        return try JSONSerialization.jsonObject(with: data)
    }
}

private struct EmptyResponse: Codable {}

private struct TicketResponse: Codable {
    let ticket: String
}

private struct SessionDetailResponse: Codable {
    let session: Session
    let events: [SessionEvent]?
}

private struct PaginatedEventsResponse: Codable {
    let session: Session
    let events: [SessionEvent]?
    let hasMore: Bool
}

private struct ContinueBody: Codable {
    let prompt: String
    let promptEncrypted: String?
    let images: [ImageAttachment]?
    let imagesEncrypted: [ImageAttachment]?
    let nonce: String
    let expiresAt: Int64
}

struct ContinueResponse: Codable {
    let commandId: String
    let status: String
}

private struct EnrollDeviceBody: Codable {
    let name: String
    let publicKey: String
    let systemInfo: String
    let keyAgreementPublicKey: String?
    let capabilities: [String]?
    let deviceId: String?
}

private struct RegisterPushTokenBody: Codable {
    let deviceToken: String
    let platform: String
    let bundleId: String
}

private struct UnregisterPushTokenBody: Codable {
    let deviceToken: String
}

private struct NewChatBody: Codable {
    let prompt: String
    let promptEncrypted: String?
    let projectPath: String
    let deviceId: String
    let useWorktree: Bool
    let worktreeName: String?
    let permissionMode: String?
    let nonce: String
    let expiresAt: Int64
}

struct CancelResponse: Codable {
    let commandId: String
    let status: String
}

struct AuditLogEntry: Codable, Identifiable {
    let id: String
    let userId: String
    let deviceId: String?
    let action: String
    let details: String
    let contentHash: String?
    let ipAddress: String?
    let createdAt: String
}

struct Project: Codable, Identifiable {
    let id: String
    let userId: String
    let path: String
    let name: String
    let settings: String?
    let createdAt: String
    let updatedAt: String
}

struct KeyAgreementResponse: Codable {
    let version: Int
    let publicKey: String
}

struct PeerKeyResponse: Codable {
    let deviceId: String
    let publicKey: String
}

struct PeerKeyVersionResponse: Codable {
    let deviceId: String
    let publicKey: String
    let version: Int
    let active: Bool
}

struct SubscriptionStatusResponse: Codable {
    let tier: String
    let expiresAt: String?
    let productId: String?
}

enum SubscriptionError: LocalizedError {
    case upgradeRequired(String)

    var errorDescription: String? {
        switch self {
        case .upgradeRequired(let message):
            return message
        }
    }
}

struct AppLogEntry: Codable, Identifiable {
    let id: String
    let deviceId: String?
    let source: String
    let level: String
    let subsystem: String
    let message: String
    let metadata: [String: String]?
    let createdAt: String
}

struct AppLogUploadEntry: Codable {
    let deviceId: String
    let source: String
    let level: String
    let subsystem: String
    let message: String
    let metadata: [String: String]?
}

struct FeedbackEntry: Codable, Identifiable {
    let id: String
    let deviceId: String?
    let category: String
    let message: String
    let appVersion: String?
    let platform: String?
    let createdAt: String
}

struct NotificationPreferences: Codable {
    var permissionRequests: Bool
    var sessionErrors: Bool
    var sessionCompletions: Bool
    var askUser: Bool
    var sessionActivity: Bool
    var quietHoursStart: String?  // "HH:mm"
    var quietHoursEnd: String?    // "HH:mm"

    // Local-only — derived from whether quietHoursStart is set.
    var quietHoursEnabled: Bool {
        quietHoursStart != nil && quietHoursStart?.isEmpty == false
    }

    enum CodingKeys: String, CodingKey {
        case permissionRequests, sessionErrors, sessionCompletions, askUser, sessionActivity
        case quietHoursStart, quietHoursEnd
    }
}
