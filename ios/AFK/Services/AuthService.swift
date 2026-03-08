import Foundation
import OSLog
import AuthenticationServices

@Observable
final class AuthService: @unchecked Sendable {
    var isAuthenticated = false
    var currentUser: User?
    var accessToken: String?
    private var refreshToken: String?

    private var baseURL: String { AppConfig.apiBaseURL }
    private let keychain = KeychainService()
    private let refreshCoordinator = TokenRefreshCoordinator()

    /// Called after sign-out to let the app clear caches (sessions, events, E2EE keys).
    var onSignOut: (() -> Void)?

    private static let accessTokenKey = "accessToken"
    private static let refreshTokenKey = "refreshToken"
    private static let userDataKey = "afk_user_data"

    // Legacy UserDefaults keys used before Keychain migration
    private static let legacyAccessTokenKey = "afk_access_token"
    private static let legacyRefreshTokenKey = "afk_refresh_token"

    /// Refreshes the access token, coalescing concurrent calls so only one
    /// HTTP refresh happens at a time (prevents thundering herd on 401s).
    func refreshAccessToken() async throws {
        try await refreshCoordinator.refreshIfNeeded { [self] in
            try await performTokenRefresh()
        }
    }

    private func performTokenRefresh() async throws {
        guard let refreshToken else { throw URLError(.userAuthenticationRequired) }

        let body = ["refreshToken": refreshToken]
        let bodyData = try JSONEncoder().encode(body)

        var request = URLRequest(url: URL(string: "\(baseURL)/v1/auth/refresh")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            signOut()
            throw URLError(.userAuthenticationRequired)
        }

        let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
        storeTokens(access: authResponse.accessToken, refresh: authResponse.refreshToken)
        accessToken = authResponse.accessToken
        self.refreshToken = authResponse.refreshToken
        currentUser = authResponse.user
    }

    func signIn(email: String, password: String) async throws {
        let body = ["email": email, "password": password]
        let bodyData = try JSONEncoder().encode(body)

        var request = URLRequest(url: URL(string: "\(baseURL)/v1/auth/login")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.serverError(0)
        }

        switch http.statusCode {
        case 200:
            let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
            storeTokens(access: authResponse.accessToken, refresh: authResponse.refreshToken)
            accessToken = authResponse.accessToken
            refreshToken = authResponse.refreshToken
            currentUser = authResponse.user
            isAuthenticated = true
        case 401:
            throw AuthError.invalidCredentials
        case 403:
            throw AuthError.emailNotVerified
        case 429:
            throw AuthError.tooManyAttempts
        default:
            throw AuthError.serverError(http.statusCode)
        }
    }

    func register(email: String, password: String, displayName: String) async throws {
        var bodyDict: [String: String] = ["email": email, "password": password]
        if !displayName.isEmpty {
            bodyDict["displayName"] = displayName
        }
        let bodyData = try JSONEncoder().encode(bodyDict)

        var request = URLRequest(url: URL(string: "\(baseURL)/v1/auth/register")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.serverError(0)
        }

        switch http.statusCode {
        case 201:
            // Check if this is a verification_required response (no tokens).
            if let status = try? JSONDecoder().decode(StatusResponse.self, from: data),
               status.status == "verification_required" {
                throw AuthError.emailVerificationRequired
            }
            let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
            storeTokens(access: authResponse.accessToken, refresh: authResponse.refreshToken)
            accessToken = authResponse.accessToken
            refreshToken = authResponse.refreshToken
            currentUser = authResponse.user
            isAuthenticated = true
        case 409:
            throw AuthError.emailAlreadyRegistered
        default:
            throw AuthError.serverError(http.statusCode)
        }
    }

    @MainActor
    func loginWithPasskey() async throws {
        let beginURL = URL(string: "\(baseURL)/v1/auth/passkey/login/begin")!
        var beginReq = URLRequest(url: beginURL)
        beginReq.httpMethod = "POST"
        beginReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        beginReq.httpBody = try JSONEncoder().encode([String: String]())

        let (beginData, beginResp) = try await URLSession.shared.data(for: beginReq)
        guard let beginHTTP = beginResp as? HTTPURLResponse, beginHTTP.statusCode == 200 else {
            throw AuthError.serverError((beginResp as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let beginJSON = try JSONSerialization.jsonObject(with: beginData) as? [String: Any] ?? [:]
        guard let sessionKey = beginJSON["sessionKey"] as? String,
              let publicKeyDict = beginJSON["publicKey"] as? [String: Any],
              let challengeB64 = publicKeyDict["challenge"] as? String,
              let challengeData = Data(base64URLEncoded: challengeB64),
              let rpId = publicKeyDict["rpId"] as? String else {
            throw AuthError.serverError(0)
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
        let assertionRequest = provider.createCredentialAssertionRequest(challenge: challengeData)

        let result: ASAuthorizationCredential
        do {
            result = try await performAuthorizationRequest(assertionRequest, preferImmediatelyAvailable: true)
        } catch let error as ASAuthorizationError where error.code == .canceled || error.code == .failed {
            throw AuthError.noPasskeysFound
        }
        guard let credential = result as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw AuthError.serverError(0)
        }

        let finishBody: [String: Any] = [
            "sessionKey": sessionKey,
            "id": credential.credentialID.base64URLEncodedString(),
            "rawId": credential.credentialID.base64URLEncodedString(),
            "type": "public-key",
            "response": [
                "authenticatorData": credential.rawAuthenticatorData.base64URLEncodedString(),
                "clientDataJSON": credential.rawClientDataJSON.base64URLEncodedString(),
                "signature": credential.signature.base64URLEncodedString(),
                "userHandle": credential.userID.base64URLEncodedString()
            ]
        ]

        let finishURL = URL(string: "\(baseURL)/v1/auth/passkey/login/finish")!
        var finishReq = URLRequest(url: finishURL)
        finishReq.httpMethod = "POST"
        finishReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        finishReq.httpBody = try JSONSerialization.data(withJSONObject: finishBody)

        let (finishData, finishResp) = try await URLSession.shared.data(for: finishReq)
        guard let finishHTTP = finishResp as? HTTPURLResponse, finishHTTP.statusCode == 200 else {
            throw AuthError.serverError((finishResp as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let authResponse = try JSONDecoder().decode(AuthResponse.self, from: finishData)
        storeTokens(access: authResponse.accessToken, refresh: authResponse.refreshToken)
        accessToken = authResponse.accessToken
        refreshToken = authResponse.refreshToken
        currentUser = authResponse.user
        isAuthenticated = true
    }

    @MainActor
    func registerPasskey() async throws {
        guard let accessToken else { throw URLError(.userAuthenticationRequired) }

        let beginURL = URL(string: "\(baseURL)/v1/auth/passkey/register/begin")!
        var beginReq = URLRequest(url: beginURL)
        beginReq.httpMethod = "POST"
        beginReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        beginReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        beginReq.httpBody = try JSONEncoder().encode([String: String]())

        let (beginData, beginResp) = try await URLSession.shared.data(for: beginReq)
        guard let beginHTTP = beginResp as? HTTPURLResponse, beginHTTP.statusCode == 200 else {
            throw AuthError.serverError((beginResp as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let beginJSON = try JSONSerialization.jsonObject(with: beginData) as? [String: Any] ?? [:]
        guard let sessionKey = beginJSON["sessionKey"] as? String,
              let publicKeyDict = beginJSON["publicKey"] as? [String: Any],
              let challengeB64 = publicKeyDict["challenge"] as? String,
              let challengeData = Data(base64URLEncoded: challengeB64),
              let rpDict = publicKeyDict["rp"] as? [String: Any],
              let rpId = rpDict["id"] as? String,
              let userDict = publicKeyDict["user"] as? [String: Any],
              let userIdB64 = userDict["id"] as? String,
              let userId = Data(base64URLEncoded: userIdB64),
              let userName = userDict["name"] as? String else {
            throw AuthError.serverError(0)
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
        let registrationRequest = provider.createCredentialRegistrationRequest(
            challenge: challengeData,
            name: userName,
            userID: userId
        )

        let result = try await performAuthorizationRequest(registrationRequest)
        guard let credential = result as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
            throw AuthError.serverError(0)
        }

        let finishBody: [String: Any] = [
            "sessionKey": sessionKey,
            "id": credential.credentialID.base64URLEncodedString(),
            "rawId": credential.credentialID.base64URLEncodedString(),
            "type": "public-key",
            "response": [
                "attestationObject": credential.rawAttestationObject!.base64URLEncodedString(),
                "clientDataJSON": credential.rawClientDataJSON.base64URLEncodedString()
            ]
        ]

        let finishURL = URL(string: "\(baseURL)/v1/auth/passkey/register/finish")!
        var finishReq = URLRequest(url: finishURL)
        finishReq.httpMethod = "POST"
        finishReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        finishReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        finishReq.httpBody = try JSONSerialization.data(withJSONObject: finishBody)

        let (_, finishResp) = try await URLSession.shared.data(for: finishReq)
        guard let finishHTTP = finishResp as? HTTPURLResponse, finishHTTP.statusCode == 200 else {
            throw AuthError.serverError((finishResp as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    @MainActor
    private func performAuthorizationRequest(_ request: ASAuthorizationRequest, preferImmediatelyAvailable: Bool = false) async throws -> ASAuthorizationCredential {
        try await withCheckedThrowingContinuation { continuation in
            let controller = ASAuthorizationController(authorizationRequests: [request])
            let delegate = PasskeyDelegate(continuation: continuation)
            controller.delegate = delegate
            controller.presentationContextProvider = delegate
            objc_setAssociatedObject(controller, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            if preferImmediatelyAvailable {
                controller.performRequests(options: .preferImmediatelyAvailableCredentials)
            } else {
                controller.performRequests()
            }
        }
    }

    func signOut() {
        // Fire-and-forget logout to revoke refresh token on server
        if let refreshToken {
            let body = ["refreshToken": refreshToken]
            if let bodyData = try? JSONEncoder().encode(body) {
                var request = URLRequest(url: URL(string: "\(baseURL)/v1/auth/logout")!)
                request.httpMethod = "DELETE"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = bodyData
                Task { try? await URLSession.shared.data(for: request) }
            }
        }

        keychain.delete(forKey: Self.accessTokenKey)
        keychain.delete(forKey: Self.refreshTokenKey)
        BuildEnvironment.userDefaults.removeObject(forKey: Self.userDataKey)
        isAuthenticated = false
        currentUser = nil
        accessToken = nil
        refreshToken = nil
        onSignOut?()
    }

    /// Attempt to restore a previous session on app launch.
    /// Loads stored tokens and refreshes them to ensure validity.
    func restoreSession() async {
        migrateFromUserDefaults()

        guard let access = keychain.loadString(forKey: Self.accessTokenKey),
              let refresh = keychain.loadString(forKey: Self.refreshTokenKey) else {
            return
        }
        accessToken = access
        refreshToken = refresh

        if let userData = BuildEnvironment.userDefaults.data(forKey: Self.userDataKey) {
            currentUser = try? JSONDecoder().decode(User.self, from: userData)
        }

        // Proactively refresh to ensure tokens are valid
        do {
            try await refreshAccessToken()
        } catch {
            #if DEBUG
            AppLogger.auth.warning("Token refresh failed (offline?): \(error, privacy: .public)")
            #endif
            // If refreshAccessToken() signed out (401), tokens are nil — don't restore
            guard accessToken != nil, refreshToken != nil else { return }
            // Network error — continue with cached tokens. APIClient will retry on 401.
        }
        isAuthenticated = true
    }

    private func migrateFromUserDefaults() {
        if let legacyAccess = BuildEnvironment.userDefaults.string(forKey: Self.legacyAccessTokenKey),
           let legacyRefresh = BuildEnvironment.userDefaults.string(forKey: Self.legacyRefreshTokenKey) {
            try? keychain.save(legacyAccess, forKey: Self.accessTokenKey)
            try? keychain.save(legacyRefresh, forKey: Self.refreshTokenKey)
            BuildEnvironment.userDefaults.removeObject(forKey: Self.legacyAccessTokenKey)
            BuildEnvironment.userDefaults.removeObject(forKey: Self.legacyRefreshTokenKey)
        }
    }

    private func storeTokens(access: String, refresh: String) {
        try? keychain.save(access, forKey: Self.accessTokenKey)
        try? keychain.save(refresh, forKey: Self.refreshTokenKey)

        if let user = currentUser, let data = try? JSONEncoder().encode(user) {
            BuildEnvironment.userDefaults.set(data, forKey: Self.userDataKey)
        }
    }
}

enum AuthError: LocalizedError {
    case invalidCredentials
    case emailAlreadyRegistered
    case emailVerificationRequired
    case emailNotVerified
    case tooManyAttempts
    case noPasskeysFound
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: return "Invalid email or password"
        case .emailAlreadyRegistered: return "An account with this email already exists"
        case .emailVerificationRequired: return "Please check your email to verify your account"
        case .emailNotVerified: return "Please verify your email before signing in"
        case .tooManyAttempts: return "Too many login attempts. Please try again later."
        case .noPasskeysFound: return "No passkeys found. Sign in with email first, then create a passkey from Settings."
        case .serverError(let code): return "Server error (\(code))"
        }
    }
}

private struct StatusResponse: Codable {
    let status: String
    let message: String?
}

private struct AuthResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int64?
    let user: User
}

/// Serialises concurrent token refresh calls so only one HTTP request
/// is in flight at a time. Additional callers await the same result.
private actor TokenRefreshCoordinator {
    private var activeTask: Task<Void, any Error>?

    func refreshIfNeeded(perform operation: @Sendable @escaping () async throws -> Void) async throws {
        if let activeTask {
            return try await activeTask.value
        }

        let task = Task { try await operation() }
        activeTask = task

        defer { activeTask = nil }
        try await task.value
    }
}

private class PasskeyDelegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    let continuation: CheckedContinuation<ASAuthorizationCredential, any Error>

    init(continuation: CheckedContinuation<ASAuthorizationCredential, any Error>) {
        self.continuation = continuation
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        continuation.resume(returning: authorization.credential)
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        continuation.resume(throwing: error)
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        self.init(base64Encoded: base64)
    }
}
