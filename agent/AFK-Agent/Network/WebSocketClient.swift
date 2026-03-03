//
//  WebSocketClient.swift
//  AFK-Agent
//

import Foundation
import Network
import OSLog

actor WebSocketClient {
    private let url: URL
    private var token: String
    private let deviceId: String
    private var webSocketTask: URLSessionWebSocketTask?
    private(set) var isConnected = false
    private(set) var isCancelled = false
    private let session = URLSession(configuration: .default)
    private var messageHandler: (@Sendable (WSMessage) async -> Void)?
    private var reconnectHandler: (@Sendable () async -> Void)?
    private var reconnectDelay: TimeInterval = 1.0
    private var hasConnectedOnce = false
    private let maxReconnectDelay: TimeInterval = 60.0
    private var connectionContinuations: [CheckedContinuation<Bool, Never>] = []
    private var ticketProvider: (@Sendable () async -> String?)?
    private let diskQueue: DiskQueue

    // Network path monitoring for sleep/wake resilience
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "afk.ws.pathMonitor")
    private var isNetworkAvailable = true
    private var networkContinuation: CheckedContinuation<Void, Never>?

    init(url: URL, token: String, deviceId: String, diskQueue: DiskQueue) {
        self.url = url
        self.token = token
        self.deviceId = deviceId
        self.diskQueue = diskQueue
    }

    /// Register a closure that provides a fresh WS ticket for each connection attempt.
    /// When set, `reconnect()` will fetch a ticket and use it instead of the long-lived token.
    func setTicketProvider(_ provider: @escaping @Sendable () async -> String?) {
        self.ticketProvider = provider
    }

    /// Update the stored token (used as fallback when ticket auth fails).
    func updateToken(_ newToken: String) {
        self.token = newToken
    }

    func onMessage(_ handler: @escaping @Sendable (WSMessage) async -> Void) {
        self.messageHandler = handler
    }

    /// Register a handler called after each successful reconnection (not the initial connect).
    func onReconnect(_ handler: @escaping @Sendable () async -> Void) {
        self.reconnectHandler = handler
    }

    /// Start monitoring network path changes. Pauses reconnection when the
    /// network is unavailable and triggers immediate reconnection on recovery.
    func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { await self.handlePathUpdate(path) }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    private func handlePathUpdate(_ path: NWPath) {
        let wasAvailable = isNetworkAvailable
        isNetworkAvailable = (path.status == .satisfied)

        if isNetworkAvailable && !wasAvailable {
            AppLogger.ws.info("Network became available")
            // Reset backoff since this is a fresh connectivity event
            reconnectDelay = 1.0
            networkContinuation?.resume()
            networkContinuation = nil
        } else if !isNetworkAvailable && wasAvailable {
            AppLogger.ws.warning("Network lost — pausing reconnect loop")
        }
    }

    /// Suspend until the network path is satisfied. Returns immediately if already available.
    private func waitForNetwork() async {
        guard !isNetworkAvailable else { return }
        AppLogger.ws.info("Waiting for network...")
        await withCheckedContinuation { continuation in
            if isNetworkAvailable {
                // Network came back between guard and here
                continuation.resume()
            } else {
                self.networkContinuation = continuation
            }
        }
    }

    /// Connect and return true once the first receive succeeds (proves handshake done)
    /// - Parameter ticket: A single-use WS ticket. When provided the connection
    ///   authenticates with `ws_ticket` instead of the long-lived token.
    func connect(ticket: String? = nil) async {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var queryItems = components.queryItems ?? []
        if let ticket {
            queryItems.append(URLQueryItem(name: "ws_ticket", value: ticket))
        } else {
            queryItems.append(URLQueryItem(name: "token", value: token))
        }
        queryItems.append(URLQueryItem(name: "deviceId", value: deviceId))
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30

        // Cancel any existing task to prevent orphan callbacks
        webSocketTask?.cancel(with: .goingAway, reason: nil)

        let task = session.webSocketTask(with: request)
        self.webSocketTask = task
        task.resume()

        // Send a ping with timeout to verify connection is alive.
        // Without a timeout, sendPing can leak its continuation when the
        // HTTP upgrade fails (e.g. Cloudflare 530) and never calls back.
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        task.sendPing { error in
                            if let error {
                                cont.resume(throwing: error)
                            } else {
                                cont.resume()
                            }
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    throw URLError(.timedOut)
                }
                // Whichever finishes first wins; cancel the other
                try await group.next()
                group.cancelAll()
            }
            let isReconnect = hasConnectedOnce
            isConnected = true
            hasConnectedOnce = true
            reconnectDelay = 1.0
            AppLogger.ws.info("Connected to \(self.url.host ?? "", privacy: .public)")
            // Resume all waiters
            for cont in connectionContinuations {
                cont.resume(returning: true)
            }
            connectionContinuations.removeAll()
            await flushQueue()
            if isReconnect {
                await reconnectHandler?()
            }
        } catch {
            AppLogger.ws.error("Handshake failed: \(error.localizedDescription, privacy: .public)")
            isConnected = false
            for cont in connectionContinuations {
                cont.resume(returning: false)
            }
            connectionContinuations.removeAll()
            await reconnect()
            return
        }

        await receiveLoop()
    }

    /// Wait until the WS is connected (or fails)
    func waitForConnection() async -> Bool {
        if isConnected { return true }
        return await withCheckedContinuation { continuation in
            self.connectionContinuations.append(continuation)
        }
    }

    func send(_ message: WSMessage) async throws {
        guard let task = webSocketTask, isConnected else {
            // Don't queue heartbeats
            if message.type == "agent.heartbeat" { return }
            let data = try message.encode()
            diskQueue.enqueue(data)
            AppLogger.ws.debug("Queued message (type: \(message.type, privacy: .public), depth: \(self.diskQueue.count, privacy: .public))")
            return
        }
        let data = try message.encode()
        try await task.send(.data(data))
    }

    private func flushQueue() async {
        guard diskQueue.count > 0, let task = webSocketTask, isConnected else { return }
        await diskQueue.flushAll { data in
            try await task.send(.data(data))
        }
    }

    func disconnect() {
        isCancelled = true
        pathMonitor.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        // Resume any pending network waiter
        networkContinuation?.resume()
        networkContinuation = nil
        // Resume any pending connection waiters
        for cont in connectionContinuations {
            cont.resume(returning: false)
        }
        connectionContinuations.removeAll()
    }

    private func receiveLoop() async {
        guard let task = webSocketTask else { return }
        do {
            while true {
                let message = try await task.receive()
                switch message {
                case .data(let data):
                    if let wsMsg = try? WSMessage.decode(from: data) {
                        await messageHandler?(wsMsg)
                    }
                case .string(let text):
                    if let data = text.data(using: .utf8),
                       let wsMsg = try? WSMessage.decode(from: data) {
                        await messageHandler?(wsMsg)
                    }
                @unknown default:
                    break
                }
            }
        } catch {
            AppLogger.ws.warning("Disconnected: \(error.localizedDescription, privacy: .public)")
            isConnected = false
            await reconnect()
        }
    }

    private func reconnect() async {
        guard !isCancelled else {
            AppLogger.ws.info("Client cancelled — stopping reconnect loop")
            return
        }

        // Wait for network before attempting reconnect (avoids 530 storm after sleep)
        await waitForNetwork()

        guard !isCancelled else {
            AppLogger.ws.info("Client cancelled while waiting for network — stopping")
            return
        }

        AppLogger.ws.info("Reconnecting in \(self.reconnectDelay, privacy: .public)s...")
        try? await Task.sleep(for: .seconds(reconnectDelay))
        guard !isCancelled else {
            AppLogger.ws.info("Client cancelled during backoff — stopping reconnect loop")
            return
        }
        reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)

        // Fetch a fresh ticket if a provider is configured; fall back to token auth on failure
        let ticket = await ticketProvider?()
        guard !isCancelled else {
            AppLogger.ws.info("Client cancelled after ticket fetch — stopping reconnect loop")
            return
        }
        await connect(ticket: ticket)
    }
}
