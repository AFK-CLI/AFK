//
//  APIClient.swift
//  AFK-Agent
//

import Foundation

struct APIClient: Sendable {
    let baseURL: String
    let token: String

    /// Refresh an expired access token using a refresh token (no Bearer needed).
    static func refreshToken(baseURL: String, refreshToken: String) async throws -> RefreshResponse {
        guard let url = URL(string: "\(baseURL)/v1/auth/refresh") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["refreshToken": refreshToken]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "APIClient", code: code, userInfo: [NSLocalizedDescriptionKey: "Token refresh failed: HTTP \(code)"])
        }
        return try JSONDecoder().decode(RefreshResponse.self, from: data)
    }

    static func emailLogin(baseURL: String, email: String, password: String) async throws -> AuthResponse {
        guard let url = URL(string: "\(baseURL)/v1/auth/login") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["email": email, "password": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let code = http.statusCode
            let message: String
            switch code {
            case 401: message = "Invalid email or password"
            case 429: message = "Too many login attempts"
            default: message = "Login failed: HTTP \(code)"
            }
            throw NSError(domain: "APIClient", code: code, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try JSONDecoder().decode(AuthResponse.self, from: data)
    }

    static func emailRegister(baseURL: String, email: String, password: String, displayName: String) async throws -> AuthResponse {
        guard let url = URL(string: "\(baseURL)/v1/auth/register") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = ["email": email, "password": password]
        if !displayName.isEmpty {
            body["displayName"] = displayName
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let code = http.statusCode
            let message: String
            switch code {
            case 409: message = "Email already registered"
            default: message = "Registration failed: HTTP \(code)"
            }
            throw NSError(domain: "APIClient", code: code, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try JSONDecoder().decode(AuthResponse.self, from: data)
    }

    func enrollDevice(name: String, publicKey: String, systemInfo: String, keyAgreementPublicKey: String? = nil, deviceId: String? = nil) async throws -> DeviceEnrollResponse {
        var body: [String: String] = [
            "name": name,
            "publicKey": publicKey,
            "systemInfo": systemInfo
        ]
        if let kaKey = keyAgreementPublicKey {
            body["keyAgreementPublicKey"] = kaKey
        }
        if let id = deviceId {
            body["deviceId"] = id
        }
        return try await post("/v1/devices", body: body)
    }

    /// Re-register the KA public key on an existing device after re-enrollment.
    func registerKeyAgreement(deviceId: String, publicKey: String) async throws {
        guard let url = URL(string: "\(baseURL)/v1/devices/\(deviceId)/key-agreement") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body = ["publicKey": publicKey]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "APIClient", code: code, userInfo: [NSLocalizedDescriptionKey: "Register KA key failed: HTTP \(code)"])
        }
    }

    /// Request a single-use WebSocket ticket (expires in 30s).
    func getWSTicket(deviceId: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/v1/auth/ws-ticket?deviceId=\(deviceId)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "APIClient", code: code, userInfo: [NSLocalizedDescriptionKey: "WS ticket request failed: HTTP \(code)"])
        }
        let decoded = try JSONDecoder().decode(WSTicketResponse.self, from: data)
        return decoded.ticket
    }

    /// List all devices for the current user.
    func listDevices() async throws -> [DeviceListEntry] {
        guard let url = URL(string: "\(baseURL)/v1/devices") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([DeviceListEntry].self, from: data)
    }

    /// Fetch a peer device's KeyAgreement public key for ECDH.
    func getPeerKeyAgreement(deviceId: String) async throws -> PeerKeyAgreementResponse {
        guard let url = URL(string: "\(baseURL)/v1/devices/\(deviceId)/key-agreement") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "APIClient", code: code, userInfo: [NSLocalizedDescriptionKey: "Get peer KA key failed: HTTP \(code)"])
        }
        return try JSONDecoder().decode(PeerKeyAgreementResponse.self, from: data)
    }

    /// Upload a batch of log entries.
    func uploadLogs(_ entries: [LogUploadEntry]) async throws {
        guard let url = URL(string: "\(baseURL)/v1/logs") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body = ["entries": entries]
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "APIClient", code: code, userInfo: [NSLocalizedDescriptionKey: "Upload logs failed: HTTP \(code)"])
        }
    }

    /// Submit user feedback.
    func submitFeedback(deviceId: String, category: String, message: String, appVersion: String, platform: String = "macos") async throws {
        guard let url = URL(string: "\(baseURL)/v1/feedback") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: String] = [
            "deviceId": deviceId,
            "category": category,
            "message": message,
            "appVersion": appVersion,
            "platform": platform
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "APIClient", code: code, userInfo: [NSLocalizedDescriptionKey: "Submit feedback failed: HTTP \(code)"])
        }
    }

    private func post<T: Decodable>(_ path: String, body: [String: String]) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

}

struct AuthResponse: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let user: AuthUser
}

struct AuthUser: Codable, Sendable {
    let id: String
    let displayName: String
}

struct DeviceEnrollResponse: Codable, Sendable {
    let id: String
    let name: String
    let enrolledAt: String
}

struct WSTicketResponse: Codable, Sendable {
    let ticket: String
}

struct RefreshResponse: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int64
}

struct PeerKeyAgreementResponse: Codable, Sendable {
    let deviceId: String
    let publicKey: String
}

struct DeviceListEntry: Codable, Sendable {
    let id: String
    let name: String
    let keyAgreementPublicKey: String?
    let keyVersion: Int?
    let capabilities: [String]?
}

struct LogUploadEntry: Codable, Sendable {
    let deviceId: String
    let source: String
    let level: String
    let subsystem: String
    let message: String
    let metadata: [String: String]?
}
