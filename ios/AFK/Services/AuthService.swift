import Foundation
import AuthenticationServices

@Observable
final class AuthService {
    var isAuthenticated = false
    var currentUser: User?
    var accessToken: String?
    private var refreshToken: String?

    private var baseURL: String { AppConfig.apiBaseURL }
    private let keychain = KeychainService()

    /// Called after sign-out to let the app clear caches (sessions, events, E2EE keys).
    var onSignOut: (() -> Void)?

    private static let accessTokenKey = "accessToken"
    private static let refreshTokenKey = "refreshToken"
    private static let userDataKey = "afk_user_data"

    // Legacy UserDefaults keys used before Keychain migration
    private static let legacyAccessTokenKey = "afk_access_token"
    private static let legacyRefreshTokenKey = "afk_refresh_token"

    func handleSignInWithApple(result: Result<ASAuthorization, any Error>) async {
        #if DEBUG
        print("[AuthService] handleSignInWithApple called")
        #endif
        switch result {
        case .success(let authorization):
            #if DEBUG
            print("[AuthService] Authorization succeeded — credential type: \(type(of: authorization.credential))")
            #endif

            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                #if DEBUG
                print("[AuthService] FAILED: credential is not ASAuthorizationAppleIDCredential — actual type: \(type(of: authorization.credential))")
                #endif
                return
            }
            #if DEBUG
            print("[AuthService] Apple ID credential obtained — userID: \(credential.user)")
            print("[AuthService] Email: \(credential.email ?? "(nil — not first sign-in or not shared)")")
            print("[AuthService] Authorization code present: \(credential.authorizationCode != nil)")
            #endif

            guard let identityTokenData = credential.identityToken else {
                #if DEBUG
                print("[AuthService] FAILED: identityToken is nil — Apple did not provide an identity token")
                #endif
                return
            }
            #if DEBUG
            print("[AuthService] Identity token data: \(identityTokenData.count) bytes")
            #endif

            guard let identityToken = String(data: identityTokenData, encoding: .utf8) else {
                #if DEBUG
                print("[AuthService] FAILED: could not decode identityToken data as UTF-8")
                #endif
                return
            }
            #if DEBUG
            print("[AuthService] Identity token decoded — length: \(identityToken.count) chars, prefix: \(String(identityToken.prefix(50)))...")
            #endif

            var displayName = ""
            if let fullName = credential.fullName {
                let parts = [fullName.givenName, fullName.familyName].compactMap { $0 }
                displayName = parts.joined(separator: " ")
                #if DEBUG
                print("[AuthService] Display name from credential: \"\(displayName)\" (givenName: \(fullName.givenName ?? "nil"), familyName: \(fullName.familyName ?? "nil"))")
                #endif
            } else {
                #if DEBUG
                print("[AuthService] No fullName in credential (normal for repeat sign-ins)")
                #endif
            }

            do {
                let body: [String: String] = [
                    "identityToken": identityToken,
                    "displayName": displayName
                ]
                let bodyData = try JSONEncoder().encode(body)
                #if DEBUG
                print("[AuthService] Request body encoded — \(bodyData.count) bytes")
                #endif

                let urlString = "\(baseURL)/v1/auth/apple"
                #if DEBUG
                print("[AuthService] Sending POST to: \(urlString)")
                #endif

                var request = URLRequest(url: URL(string: urlString)!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = bodyData

                let (data, response) = try await URLSession.shared.data(for: request)

                guard let http = response as? HTTPURLResponse else {
                    #if DEBUG
                    print("[AuthService] FAILED: response is not HTTPURLResponse — actual type: \(type(of: response))")
                    #endif
                    return
                }
                #if DEBUG
                print("[AuthService] HTTP response: \(http.statusCode)")
                print("[AuthService] Response headers: \(http.allHeaderFields)")
                let responseBody = String(data: data, encoding: .utf8) ?? "(non-UTF8 data, \(data.count) bytes)"
                print("[AuthService] Response body: \(responseBody)")
                #endif

                guard (200...299).contains(http.statusCode) else {
                    #if DEBUG
                    print("[AuthService] FAILED: non-success HTTP status \(http.statusCode)")
                    #endif
                    return
                }

                #if DEBUG
                print("[AuthService] Decoding AuthResponse...")
                #endif
                let authResponse: AuthResponse
                do {
                    authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
                } catch {
                    #if DEBUG
                    print("[AuthService] FAILED: could not decode AuthResponse — \(error)")
                    if let decodingError = error as? DecodingError {
                        switch decodingError {
                        case .keyNotFound(let key, let ctx):
                            print("[AuthService]   keyNotFound: \"\(key.stringValue)\" — path: \(ctx.codingPath.map(\.stringValue)), desc: \(ctx.debugDescription)")
                        case .typeMismatch(let type, let ctx):
                            print("[AuthService]   typeMismatch: expected \(type) — path: \(ctx.codingPath.map(\.stringValue)), desc: \(ctx.debugDescription)")
                        case .valueNotFound(let type, let ctx):
                            print("[AuthService]   valueNotFound: \(type) — path: \(ctx.codingPath.map(\.stringValue)), desc: \(ctx.debugDescription)")
                        case .dataCorrupted(let ctx):
                            print("[AuthService]   dataCorrupted — path: \(ctx.codingPath.map(\.stringValue)), desc: \(ctx.debugDescription)")
                        @unknown default:
                            break
                        }
                    }
                    #endif
                    return
                }
                #if DEBUG
                print("[AuthService] AuthResponse decoded — user: \(authResponse.user.id), accessToken length: \(authResponse.accessToken.count), refreshToken length: \(authResponse.refreshToken.count)")
                #endif

                storeTokens(access: authResponse.accessToken, refresh: authResponse.refreshToken)
                #if DEBUG
                print("[AuthService] Tokens stored in keychain")
                #endif

                accessToken = authResponse.accessToken
                refreshToken = authResponse.refreshToken
                currentUser = authResponse.user
                isAuthenticated = true
                #if DEBUG
                print("[AuthService] Sign-in COMPLETE — isAuthenticated = true, user = \(authResponse.user.id)")
                #endif
            } catch {
                #if DEBUG
                print("[AuthService] FAILED with exception: \(error)")
                print("[AuthService] Error type: \(type(of: error))")
                print("[AuthService] Localized: \(error.localizedDescription)")
                if let urlError = error as? URLError {
                    print("[AuthService] URLError code: \(urlError.code.rawValue) — \(urlError.localizedDescription)")
                    print("[AuthService] URLError failingURL: \(urlError.failingURL?.absoluteString ?? "nil")")
                }
                #endif
            }

        case .failure(let error):
            #if DEBUG
            print("[AuthService] Apple Sign-In FAILED at dialog level: \(error)")
            print("[AuthService] Error type: \(type(of: error))")
            print("[AuthService] Localized: \(error.localizedDescription)")
            let nsError = error as NSError
            print("[AuthService] NSError domain: \(nsError.domain), code: \(nsError.code)")
            if nsError.code == ASAuthorizationError.canceled.rawValue {
                print("[AuthService] User cancelled the sign-in dialog")
            }
            #endif
        }
    }

    func refreshAccessToken() async throws {
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
            print("[AuthService] Token refresh failed (offline?): \(error)")
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
    case tooManyAttempts
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: return "Invalid email or password"
        case .emailAlreadyRegistered: return "An account with this email already exists"
        case .tooManyAttempts: return "Too many login attempts. Please try again later."
        case .serverError(let code): return "Server error (\(code))"
        }
    }
}

private struct AuthResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int64?
    let user: User
}
