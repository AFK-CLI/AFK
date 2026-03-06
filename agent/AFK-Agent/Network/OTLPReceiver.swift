//
//  OTLPReceiver.swift
//  AFK-Agent
//
//  Lightweight OTLP HTTP receiver on localhost:4318.
//  Accepts POST on any path (responds 200 {}), but only parses /v1/logs
//  to extract session metrics (cost, tokens, model) from Claude Code telemetry.
//

import Foundation
import Network
import OSLog

struct SessionMetrics: Sendable {
    let sessionId: String
    let model: String
    let costUsd: Double
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let cacheCreationTokens: Int64
    let durationMs: Int64
}

actor OTLPReceiver {
    private var listener: NWListener?
    private let port: UInt16 = 4318
    private let queue = DispatchQueue(label: "otlp-receiver", qos: .utility)
    /// Maximum allowed HTTP request size (headers + body) to prevent unbounded buffering.
    private let maxRequestSize = 1_048_576  // 1 MB

    var onMetrics: ((SessionMetrics) async -> Void)?

    func setOnMetrics(_ handler: @escaping (SessionMetrics) async -> Void) {
        self.onMetrics = handler
    }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)

        let listener = try NWListener(using: params)
        self.listener = listener

        let portNumber = port
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                AppLogger.agent.info("OTLP receiver listening on 127.0.0.1:\(portNumber)")
            case .failed(let error):
                AppLogger.agent.error("OTLP listener failed: \(error.localizedDescription)")
            case .cancelled:
                AppLogger.agent.info("OTLP listener cancelled")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        AppLogger.agent.info("OTLP receiver stopped")
    }

    // MARK: - Connection Handling

    /// Handle an incoming TCP connection. Runs on the dispatch queue (nonisolated context).
    private nonisolated func handleConnection(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "otlp-conn", qos: .utility))

        // Read the full HTTP request in chunks
        readHTTPRequest(connection: connection, accumulated: Data()) { [weak self] requestData in
            guard let self, let requestData, !requestData.isEmpty else {
                connection.cancel()
                return
            }

            // Parse HTTP request line and headers
            guard let headerEnd = Self.findHeaderEnd(in: requestData) else {
                Self.sendResponse(connection: connection, status: "400 Bad Request", body: "{}")
                return
            }

            let headerData = requestData[..<headerEnd]
            let headerString = String(data: headerData, encoding: .utf8) ?? ""
            let lines = headerString.components(separatedBy: "\r\n")

            // Parse request line
            let requestLine = lines.first ?? ""
            let parts = requestLine.split(separator: " ", maxSplits: 2)
            let method = parts.first.map(String.init) ?? ""
            let path = parts.count > 1 ? String(parts[1]) : ""

            // Only accept POST
            guard method == "POST" else {
                Self.sendResponse(connection: connection, status: "405 Method Not Allowed", body: "{}")
                return
            }

            // Parse Content-Length
            var contentLength = 0
            for line in lines {
                let lower = line.lowercased()
                if lower.hasPrefix("content-length:") {
                    let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                    contentLength = Int(value) ?? 0
                    break
                }
            }

            // Reject oversized requests early
            if contentLength > self.maxRequestSize {
                Self.sendResponse(connection: connection, status: "413 Payload Too Large", body: "{}")
                return
            }

            // Body starts after \r\n\r\n
            let bodyStart = headerEnd + 4  // skip \r\n\r\n
            let currentBody = requestData[bodyStart...]

            if currentBody.count >= contentLength {
                // Full body received
                let body = Data(currentBody.prefix(contentLength))
                Self.sendResponse(connection: connection, status: "200 OK", body: "{}")

                if path == "/v1/logs" || path.hasSuffix("/v1/logs") {
                    Task { [weak self] in
                        await self?.processLogs(body)
                    }
                }
            } else {
                // Need more data for the body
                let remaining = contentLength - currentBody.count
                self.readBody(connection: connection, accumulated: Data(currentBody), remaining: remaining, path: path)
            }
        }
    }

    private nonisolated func readHTTPRequest(connection: NWConnection, accumulated: Data, completion: @escaping @Sendable (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let error {
                AppLogger.agent.debug("OTLP read error: \(error.localizedDescription)")
                completion(nil)
                return
            }

            var buffer = accumulated
            if let data {
                buffer.append(data)
            }

            // Guard against unbounded buffering
            if buffer.count > self.maxRequestSize {
                AppLogger.agent.warning("OTLP request exceeded \(self.maxRequestSize) bytes, dropping")
                completion(nil)
                return
            }

            // Check if we have the full headers
            if Self.findHeaderEnd(in: buffer) != nil {
                completion(buffer)
            } else if isComplete {
                completion(buffer.isEmpty ? nil : buffer)
            } else {
                self.readHTTPRequest(connection: connection, accumulated: buffer, completion: completion)
            }
        }
    }

    private nonisolated func readBody(connection: NWConnection, accumulated: Data, remaining: Int, path: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 65536)) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if error != nil || (isComplete && data == nil) {
                Self.sendResponse(connection: connection, status: "400 Bad Request", body: "{}")
                return
            }

            var buffer = accumulated
            if let data {
                buffer.append(data)
            }

            let left = remaining - (data?.count ?? 0)
            if left <= 0 {
                Self.sendResponse(connection: connection, status: "200 OK", body: "{}")
                if path == "/v1/logs" || path.hasSuffix("/v1/logs") {
                    Task { [weak self] in
                        await self?.processLogs(buffer)
                    }
                }
            } else {
                self.readBody(connection: connection, accumulated: buffer, remaining: left, path: path)
            }
        }
    }

    private nonisolated static func findHeaderEnd(in data: Data) -> Int? {
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]  // \r\n\r\n
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) {
            if bytes[i] == separator[0] && bytes[i+1] == separator[1]
                && bytes[i+2] == separator[2] && bytes[i+3] == separator[3] {
                return i
            }
        }
        return nil
    }

    private nonisolated static func sendResponse(connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - OTLP Log Parsing

    private func processLogs(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resourceLogs = json["resourceLogs"] as? [[String: Any]] else {
            AppLogger.agent.warning("OTLP: failed to parse log payload (\(data.count) bytes)")
            return
        }

        var recordCount = 0
        var metricsCount = 0
        for resourceLog in resourceLogs {
            guard let scopeLogs = resourceLog["scopeLogs"] as? [[String: Any]] else { continue }
            for scopeLog in scopeLogs {
                guard let logRecords = scopeLog["logRecords"] as? [[String: Any]] else { continue }
                for record in logRecords {
                    recordCount += 1
                    if let metrics = parseAPIRequestRecord(record) {
                        metricsCount += 1
                        if let handler = onMetrics {
                            Task { await handler(metrics) }
                        } else {
                            AppLogger.agent.warning("OTLP: onMetrics handler is nil")
                        }
                    }
                }
            }
        }
        AppLogger.agent.info("OTLP: processed \(recordCount) record(s), extracted \(metricsCount) metric(s)")
    }

    private func parseAPIRequestRecord(_ record: [String: Any]) -> SessionMetrics? {
        let recordAttributes = record["attributes"] as? [[String: Any]] ?? []

        // Check if this is an api_request event
        // Claude Code uses body.stringValue = "claude_code.api_request"
        // and/or attributes with event.name = "api_request"
        var isAPIRequest = false

        if let body = record["body"] as? [String: Any],
           let bodyStr = body["stringValue"] as? String {
            if bodyStr == "claude_code.api_request" || bodyStr == "api_request" {
                isAPIRequest = true
            }
        }

        if !isAPIRequest {
            let eventName = Self.extractStringAttribute(from: recordAttributes, key: "event.name")
                ?? Self.extractStringAttribute(from: recordAttributes, key: "event")
            if eventName == "api_request" {
                isAPIRequest = true
            }
        }

        guard isAPIRequest else { return nil }

        // All data lives in record-level attributes
        // Session ID key is "session.id" (Claude Code format) or "session_id"
        guard let sessionId = Self.extractStringAttribute(from: recordAttributes, key: "session.id")
                ?? Self.extractStringAttribute(from: recordAttributes, key: "session_id"),
              !sessionId.isEmpty else {
            return nil
        }

        let model = Self.extractStringAttribute(from: recordAttributes, key: "model") ?? "unknown"
        let costUsd = Self.extractDoubleAttribute(from: recordAttributes, key: "cost_usd") ?? 0.0
        let inputTokens = Self.extractIntAttribute(from: recordAttributes, key: "input_tokens") ?? 0
        let outputTokens = Self.extractIntAttribute(from: recordAttributes, key: "output_tokens") ?? 0
        let cacheReadTokens = Self.extractIntAttribute(from: recordAttributes, key: "cache_read_tokens") ?? 0
        let cacheCreationTokens = Self.extractIntAttribute(from: recordAttributes, key: "cache_creation_tokens") ?? 0
        let durationMs = Self.extractIntAttribute(from: recordAttributes, key: "duration_ms") ?? 0

        return SessionMetrics(
            sessionId: sessionId,
            model: model,
            costUsd: costUsd,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            durationMs: durationMs
        )
    }

    // MARK: - OTLP Attribute Helpers

    private static func extractStringAttribute(from attrs: [[String: Any]], key: String) -> String? {
        for attr in attrs {
            guard let k = attr["key"] as? String, k == key,
                  let value = attr["value"] as? [String: Any] else { continue }
            if let s = value["stringValue"] as? String { return s }
        }
        return nil
    }

    private static func extractDoubleAttribute(from attrs: [[String: Any]], key: String) -> Double? {
        for attr in attrs {
            guard let k = attr["key"] as? String, k == key,
                  let value = attr["value"] as? [String: Any] else { continue }
            if let d = value["doubleValue"] as? Double { return d }
            if let s = value["stringValue"] as? String, let d = Double(s) { return d }
        }
        return nil
    }

    private static func extractIntAttribute(from attrs: [[String: Any]], key: String) -> Int64? {
        for attr in attrs {
            guard let k = attr["key"] as? String, k == key,
                  let value = attr["value"] as? [String: Any] else { continue }
            if let i = value["intValue"] as? Int64 { return i }
            if let s = value["intValue"] as? String, let i = Int64(s) { return i }
            if let s = value["stringValue"] as? String, let i = Int64(s) { return i }
        }
        return nil
    }
}
