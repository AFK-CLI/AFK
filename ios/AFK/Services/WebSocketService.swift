import Foundation
import OSLog

@Observable
final class WebSocketService {
    var isConnected = false
    private var webSocketTask: URLSessionWebSocketTask?
    private var baseURL: String { AppConfig.wsBaseURL }
    private var token: String?
    private var apiClient: APIClient?
    private var deviceId: String?

    // Diagnostics tracking
    private(set) var lastConnectedAt: Date?
    private(set) var lastDisconnectedAt: Date?
    private(set) var reconnectCount: Int = 0
    private(set) var lastMessageReceivedAt: Date?

    // Reconnect backoff state
    private var consecutiveFailures: Int = 0
    private static let maxRetries = 10
    private static let baseDelay: Double = 1.0
    private static let maxDelay: Double = 60.0

    /// E2EE session key cache: sessionId -> SymmetricKey
    /// Set by SessionStore when peer key is available and privacy mode is "encrypted".
    var e2eeSessionKeys: [String: Any] = [:]  // Actually [String: SymmetricKey], using Any to avoid CryptoKit import here

    var onSessionUpdate: ((Session) -> Void)?
    var onSessionEvent: ((SessionEvent) -> Void)?
    var onDeviceStatus: ((String, Bool) -> Void)?
    var onPermissionRequest: ((PermissionRequest) -> Void)?
    var onCommandChunk: ((String, String) -> Void)?    // (sessionId, text)
    var onCommandDone: ((String, Int?, Double?, String?) -> Void)?  // (sessionId, durationMs?, costUsd?, newSessionId?)
    var onCommandFailed: ((String, String) -> Void)?    // (sessionId, error)
    var onCommandRunning: ((String) -> Void)?            // sessionId
    var onCommandCancelled: ((String) -> Void)?          // sessionId
    var onReconnect: (() -> Void)?
    var onDeviceKeyRotated: ((String, String, Int) -> Void)?  // (deviceId, newPublicKey, keyVersion)
    var onAgentControlState: ((String, Bool, Bool) -> Void)?  // (deviceId, remoteApproval, autoPlanExit)
    var onTaskUpdate: ((AFKTask) -> Void)?
    var onTodoUpdate: ((ProjectTodos) -> Void)?

    /// Content decryptor closure — set by SessionStore to decrypt E2EE content.
    /// Accepts (content dict, sessionId) and returns decrypted content dict.
    var contentDecryptor: (([String: String], String) -> [String: String])?

    init() {}

    func connect(token: String, apiClient: APIClient? = nil, deviceId: String? = nil) {
        self.token = token
        self.apiClient = apiClient
        self.deviceId = deviceId
        AppLogger.ws.info("connect() called, baseURL=\(self.baseURL, privacy: .public)")
        Task { await connectWithTicket() }
    }

    private func connectWithTicket() async {
        var components = URLComponents(string: "\(baseURL)/v1/ws/app")!

        // Try to fetch a WS ticket; fall back to raw token if ticket fetch fails
        if let apiClient {
            do {
                let ticket = try await apiClient.getWSTicket(deviceId: deviceId)
                components.queryItems = [URLQueryItem(name: "ws_ticket", value: ticket)]
                AppLogger.ws.info("Got WS ticket, connecting...")
            } catch {
                AppLogger.ws.warning("Ticket fetch failed: \(error, privacy: .public), falling back to token")
                components.queryItems = [URLQueryItem(name: "token", value: token)]
            }
        } else {
            components.queryItems = [URLQueryItem(name: "token", value: token)]
        }

        // Log URL without query parameters to avoid leaking tokens/tickets
        let redactedURL = components.url.map { "\($0.scheme ?? "")://\($0.host ?? "")\($0.port.map { ":\($0)" } ?? "")\($0.path)" } ?? "nil"
        AppLogger.ws.info("Connecting to \(redactedURL, privacy: .public)")
        let task = URLSession.shared.webSocketTask(with: components.url!)
        self.webSocketTask = task
        task.resume()
        isConnected = true
        lastConnectedAt = Date()
        consecutiveFailures = 0

        Task { await subscribe() }
        Task { await receiveLoop() }
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        lastDisconnectedAt = Date()
    }

    /// Force disconnect and reconnect using the cached token.
    func reconnect() {
        disconnect()
        guard token != nil else { return }
        reconnectCount += 1
        Task { await connectWithTicket() }
    }

    func sendPermissionResponse(_ response: PermissionResponse) async {
        guard let msg = try? WSMessage(type: "app.permission.response", payload: response),
              let data = try? msg.toJSONData() else { return }
        try? await webSocketTask?.send(.data(data))
    }

    func sendPermissionMode(deviceId: String, mode: String) async {
        struct Payload: Encodable { let deviceId: String; let mode: String }
        guard let msg = try? WSMessage(type: "app.permission_mode",
                  payload: Payload(deviceId: deviceId, mode: mode)),
              let data = try? msg.toJSONData() else { return }
        try? await webSocketTask?.send(.data(data))
    }

    func sendAgentControl(deviceId: String, remoteApproval: Bool? = nil, autoPlanExit: Bool? = nil) async {
        struct Payload: Encodable { let deviceId: String; let remoteApproval: Bool?; let autoPlanExit: Bool? }
        guard let msg = try? WSMessage(type: "app.agent_control",
                  payload: Payload(deviceId: deviceId, remoteApproval: remoteApproval, autoPlanExit: autoPlanExit)),
              let data = try? msg.toJSONData() else { return }
        try? await webSocketTask?.send(.data(data))
    }

    private func subscribe() async {
        let payload: [String: [String]] = ["sessionIds": []]
        guard let msg = try? WSMessage(type: "app.subscribe", payload: payload),
              let data = try? msg.toJSONData() else { return }
        try? await webSocketTask?.send(.data(data))
    }

    private func receiveLoop() async {
        guard let task = webSocketTask else { return }
        do {
            while true {
                let message = try await task.receive()
                switch message {
                case .data(let data):
                    handleMessage(data)
                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        handleMessage(data)
                    }
                @unknown default:
                    break
                }
            }
        } catch {
            AppLogger.ws.error("Receive loop error: \(error, privacy: .public)")
            isConnected = false
            lastDisconnectedAt = Date()
            consecutiveFailures += 1

            guard token != nil, consecutiveFailures <= Self.maxRetries else {
                if consecutiveFailures > Self.maxRetries {
                    AppLogger.ws.error("Max retries (\(Self.maxRetries, privacy: .public)) exceeded, stopping reconnect")
                }
                return
            }

            // Exponential backoff: base * 2^(failures-1), capped at maxDelay, plus random jitter
            let exponentialDelay = min(Self.baseDelay * pow(2.0, Double(consecutiveFailures - 1)), Self.maxDelay)
            let jitter = Double.random(in: 0...1.0)
            let totalDelay = exponentialDelay + jitter
            AppLogger.ws.info("Reconnecting in \(String(format: "%.1f", totalDelay), privacy: .public)s (attempt \(self.consecutiveFailures, privacy: .public)/\(Self.maxRetries, privacy: .public))...")
            try? await Task.sleep(for: .seconds(totalDelay))

            if token != nil {
                reconnectCount += 1
                await connectWithTicket()
                onReconnect?()
            }
        }
    }

    private func handleMessage(_ data: Data) {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = envelope["type"] as? String,
              let payloadObj = envelope["payload"] else {
            AppLogger.ws.warning("Failed to parse envelope")
            return
        }

        AppLogger.ws.debug("Received: \(type, privacy: .public)")
        lastMessageReceivedAt = Date()

        let decoder = AppConfig.makeJSONDecoder()

        guard let payloadData = try? JSONSerialization.data(withJSONObject: payloadObj) else { return }

        switch type {
        case "session.update":
            do {
                let payload = try decoder.decode(SessionUpdatePayload.self, from: payloadData)
                var session = payload.session
                session.deviceName = payload.deviceName
                AppLogger.ws.info("session.update: \(session.id.prefix(8), privacy: .public) status=\(session.status.rawValue, privacy: .public) project=\(session.projectName, privacy: .public)")
                onSessionUpdate?(session)
            } catch {
                let raw = String(data: payloadData, encoding: .utf8) ?? ""
                AppLogger.ws.error("DECODE ERROR session.update: \(error, privacy: .public)")
                AppLogger.ws.debug("Raw payload: \(raw.prefix(500))")
            }
        case "session.event":
            do {
                let payload = try decoder.decode(SessionEventPayload.self, from: payloadData)
                // Decrypt content if E2EE decryptor is available.
                var content = payload.content
                if let decryptor = contentDecryptor, let encrypted = content {
                    content = decryptor(encrypted, payload.sessionId)
                }

                let event = SessionEvent(
                    id: payload.id ?? UUID().uuidString,
                    sessionId: payload.sessionId,
                    deviceId: nil,
                    eventType: payload.eventType,
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    payload: payload.data,
                    content: content,
                    seq: payload.seq
                )
                onSessionEvent?(event)
            } catch {
                let raw = String(data: payloadData, encoding: .utf8) ?? ""
                AppLogger.ws.error("DECODE ERROR session.event: \(error, privacy: .public)")
                AppLogger.ws.debug("Raw payload: \(raw.prefix(500))")
            }
        case "device.status":
            if let status = try? decoder.decode(DeviceStatusPayload.self, from: payloadData) {
                onDeviceStatus?(status.deviceId, status.isOnline)
            }
        case "session.permission_request":
            if let request = try? decoder.decode(PermissionRequest.self, from: payloadData) {
                onPermissionRequest?(request)
            }
        case "command.running":
            if let payload = try? decoder.decode(CommandRunningPayload.self, from: payloadData) {
                onCommandRunning?(payload.sessionId)
            }
        case "command.chunk":
            if let payload = try? decoder.decode(CommandChunkPayload.self, from: payloadData) {
                onCommandChunk?(payload.sessionId, payload.text)
            }
        case "command.done":
            if let payload = try? decoder.decode(CommandDonePayload.self, from: payloadData) {
                onCommandDone?(payload.sessionId, payload.durationMs, payload.costUsd, payload.newSessionId)
            }
        case "command.failed":
            if let payload = try? decoder.decode(CommandFailedPayload.self, from: payloadData) {
                onCommandFailed?(payload.sessionId, payload.error)
            }
        case "command.cancelled":
            if let payload = try? decoder.decode(CommandCancelledPayload.self, from: payloadData) {
                onCommandCancelled?(payload.sessionId)
            }
        case "device.key_rotated":
            if let payload = try? decoder.decode(DeviceKeyRotatedPayload.self, from: payloadData) {
                AppLogger.ws.info("device.key_rotated: \(payload.deviceId.prefix(8), privacy: .public) v\(payload.keyVersion, privacy: .public)")
                onDeviceKeyRotated?(payload.deviceId, payload.publicKey, payload.keyVersion)
            }
        case "agent.control_state":
            if let payload = try? decoder.decode(AgentControlStatePayload.self, from: payloadData) {
                AppLogger.ws.info("agent.control_state: device=\(payload.deviceId.prefix(8), privacy: .public) remoteApproval=\(payload.remoteApproval, privacy: .public) autoPlanExit=\(payload.autoPlanExit, privacy: .public)")
                onAgentControlState?(payload.deviceId, payload.remoteApproval, payload.autoPlanExit)
            }
        case "task.updated":
            if let payload = try? decoder.decode(TaskUpdatePayload.self, from: payloadData) {
                onTaskUpdate?(payload.task)
            }
        case "todo.updated":
            if let payload = try? decoder.decode(TodoUpdatePayload.self, from: payloadData) {
                onTodoUpdate?(payload.projectTodos)
            }
        default:
            break
        }
    }
}

private struct SessionUpdatePayload: Codable {
    let session: Session
    let deviceName: String?
}

private struct SessionEventPayload: Codable {
    let id: String?
    let seq: Int?
    let sessionId: String
    let eventType: String
    let data: [String: String]?
    let content: [String: String]?
    let deviceName: String?
}

private struct DeviceStatusPayload: Codable {
    let deviceId: String
    let deviceName: String
    let isOnline: Bool
}

private struct CommandRunningPayload: Codable {
    let commandId: String
    let sessionId: String
}

private struct CommandChunkPayload: Codable {
    let commandId: String
    let sessionId: String
    let text: String
    let seq: Int
}

private struct CommandDonePayload: Codable {
    let commandId: String
    let sessionId: String
    let durationMs: Int?
    let costUsd: Double?
    let newSessionId: String?
}

private struct CommandFailedPayload: Codable {
    let commandId: String
    let sessionId: String
    let error: String
}

private struct CommandCancelledPayload: Codable {
    let commandId: String
    let sessionId: String
}

private struct DeviceKeyRotatedPayload: Codable {
    let deviceId: String
    let publicKey: String
    let keyVersion: Int
}

private struct AgentControlStatePayload: Codable {
    let deviceId: String
    let remoteApproval: Bool
    let autoPlanExit: Bool
}

private struct TaskUpdatePayload: Codable {
    let task: AFKTask
}

private struct TodoUpdatePayload: Codable {
    let projectTodos: ProjectTodos
}
