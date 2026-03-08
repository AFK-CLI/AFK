//
//  AgentSignInView.swift
//  AFK-Agent
//

import AuthenticationServices
import SwiftUI

// MARK: - Starfield Background

private struct StarfieldView: View {
    private struct Star {
        let x, y, size: CGFloat
        let opacity: Double
    }

    private struct Meteor {
        let startX, startY, angle, trailLength, speed: CGFloat
        let cyclePeriod, offset: Double
    }

    // Truly random, evaluated once per process via static let
    private static let stars: [Star] = {
        (0..<25).map { _ in
            Star(
                x: .random(in: 0...1), y: .random(in: 0...1),
                size: .random(in: 1...2.5), opacity: .random(in: 0.3...0.7)
            )
        }
    }()

    private static let meteors: [Meteor] = {
        (0..<3).map { _ in
            Meteor(
                startX: .random(in: 0.05...0.95),
                startY: .random(in: 0.0...0.35),
                angle: .random(in: 0.4...1.0),
                trailLength: .random(in: 30...70),
                speed: .random(in: 250...450),
                cyclePeriod: .random(in: 5...12),
                offset: .random(in: 0...10)
            )
        }
    }()

    var body: some View {
        ZStack {
            // Static stars — Canvas never redraws on state changes
            Canvas { context, size in
                for star in Self.stars {
                    let rect = CGRect(
                        x: star.x * size.width - star.size / 2,
                        y: star.y * size.height - star.size / 2,
                        width: star.size, height: star.size
                    )
                    context.opacity = star.opacity
                    context.fill(Circle().path(in: rect), with: .color(.white))
                }
            }

            // Shooting stars — time-driven Canvas
            TimelineView(.animation(minimumInterval: 1.0 / 24)) { timeline in
                Canvas { context, size in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    for m in Self.meteors {
                        let cycleTime = (now + m.offset)
                            .truncatingRemainder(dividingBy: m.cyclePeriod)
                        let travelDuration = Double(m.trailLength * 2.5 / m.speed)
                        guard cycleTime < travelDuration else { continue }

                        let progress = CGFloat(cycleTime / travelDuration)
                        let headDist = progress * m.trailLength * 2.5
                        let headX = m.startX * size.width + cos(m.angle) * headDist
                        let headY = m.startY * size.height + sin(m.angle) * headDist

                        let visibleTrail = min(m.trailLength, headDist)
                        let tailX = headX - cos(m.angle) * visibleTrail
                        let tailY = headY - sin(m.angle) * visibleTrail

                        // Fade envelope: quick appear, gradual fade
                        let fade: Double = if progress < 0.1 {
                            Double(progress / 0.1)
                        } else if progress > 0.6 {
                            Double((1 - progress) / 0.4)
                        } else { 1.0 }
                        guard fade > 0.01 else { continue }

                        // Trail
                        var trail = Path()
                        trail.move(to: CGPoint(x: tailX, y: tailY))
                        trail.addLine(to: CGPoint(x: headX, y: headY))
                        context.opacity = fade * 0.6
                        context.stroke(trail, with: .linearGradient(
                            Gradient(colors: [.clear, .white]),
                            startPoint: CGPoint(x: tailX, y: tailY),
                            endPoint: CGPoint(x: headX, y: headY)
                        ), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))

                        // Bright head dot
                        context.opacity = fade * 0.9
                        context.fill(Circle().path(in: CGRect(
                            x: headX - 1, y: headY - 1, width: 2, height: 2
                        )), with: .color(.white))
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Dark Text Field

private struct DarkTextField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var contentType: NSTextContentType? = nil
    var onSubmit: (() -> Void)? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 16)

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                        .textContentType(contentType)
                        .onSubmit { onSubmit?() }
                } else {
                    TextField(placeholder, text: $text)
                        .textContentType(contentType)
                }
            }
            .textFieldStyle(.plain)
            .foregroundStyle(.white)
            .focused($isFocused)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    Color.white.opacity(isFocused ? 0.25 : 0.1),
                    lineWidth: 1
                )
        )
        .colorScheme(.dark)
    }
}

// MARK: - Primary Gradient Button

private struct PrimaryButton: View {
    let title: String
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.23, green: 0.48, blue: 0.97),
                            Color(red: 0.15, green: 0.39, blue: 0.92)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .brightness(isHovering && !isDisabled ? 0.06 : 0)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .opacity(isDisabled ? 0.4 : 1)
        .disabled(isDisabled)
        .onHover { hovering in
            isHovering = hovering
        }
        .keyboardShortcut(.defaultAction)
    }
}

// MARK: - Main View

struct AgentSignInView: View {
    let serverURL: String
    var onAuthenticated: (String, String, String, String) -> Void  // (token, refreshToken, userId, email)

    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var isRegistering = false
    @State private var errorMessage = ""
    @State private var successMessage = ""
    @State private var isLoading = false
    @State private var confirmPassword = ""
    @State private var pendingAuth: (token: String, refreshToken: String, userId: String, email: String)?
    @State private var isRegisteringPasskey = false
    @State private var passkeySuccess = false

    private var passwordLongEnough: Bool { password.count >= 8 }
    private var passwordsMatch: Bool { password == confirmPassword }
    private var hasUppercase: Bool { password.range(of: "[A-Z]", options: .regularExpression) != nil }
    private var hasLowercase: Bool { password.range(of: "[a-z]", options: .regularExpression) != nil }
    private var hasDigit: Bool { password.range(of: "[0-9]", options: .regularExpression) != nil }
    private var hasSpecialChar: Bool { password.range(of: "[^A-Za-z0-9]", options: .regularExpression) != nil }
    private var passwordMeetsComplexity: Bool { passwordLongEnough && hasUppercase && hasLowercase && hasDigit && hasSpecialChar }

    private var httpBaseURL: String {
        serverURL
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")
    }

    var body: some View {
        ZStack {
            // MARK: - Background
            LinearGradient(
                colors: [
                    Color(red: 0.043, green: 0.102, blue: 0.18),
                    Color(red: 0.086, green: 0.176, blue: 0.314)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            StarfieldView()
                .ignoresSafeArea()

            // MARK: - Content
            if let auth = pendingAuth {
                // MARK: Passkey Setup
                VStack(spacing: 0) {
                    Spacer()

                    Image(systemName: "person.badge.key.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.23, green: 0.48, blue: 0.97),
                                    Color(red: 0.15, green: 0.39, blue: 0.92)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .padding(.bottom, 16)

                    Text("Secure your account with a Passkey")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 6)

                    Text("Sign in faster next time with Touch ID.\nNo password needed.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 20)

                    if passkeySuccess {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Passkey created!")
                                .foregroundStyle(.white.opacity(0.9))
                                .font(.subheadline)
                        }
                        .padding(10)
                        .background(Color.green.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 12)
                    }

                    if !successMessage.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "envelope.fill")
                                .foregroundStyle(.green.opacity(0.9))
                                .font(.caption)
                            Text(successMessage)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(2)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 12)
                    }

                    if !errorMessage.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red.opacity(0.9))
                                .font(.caption)
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(2)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 12)
                    }

                    Spacer()

                    VStack(spacing: 10) {
                        PrimaryButton(
                            title: passkeySuccess ? "Continue" : "Create Passkey",
                            isDisabled: isRegisteringPasskey,
                            action: {
                                if passkeySuccess {
                                    onAuthenticated(auth.token, auth.refreshToken, auth.userId, auth.email)
                                } else {
                                    registerPasskeyForAgent(auth: auth)
                                }
                            }
                        )

                        if !passkeySuccess {
                            Button {
                                onAuthenticated(auth.token, auth.refreshToken, auth.userId, auth.email)
                            } label: {
                                Text("Skip")
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                            .disabled(isRegisteringPasskey)
                        }
                    }
                    .padding(.bottom, 32)
                }
                .padding(.horizontal, 32)
                .frame(width: 380)
            } else {
                VStack(spacing: 0) {
                    // MARK: Hero
                    VStack(spacing: 12) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 88, height: 88)
                            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                            .modifier(BobAnimation())

                        Text("AFK Agent")
                            .font(.title.weight(.bold))
                            .foregroundStyle(.white)

                        Text("Connect this Mac to your AFK server")
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.top, 32)
                    .padding(.bottom, 24)

                    // MARK: Passkey
                    if !isRegistering {
                        Button {
                            loginWithPasskey()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "person.badge.key.fill")
                                    .font(.body)
                                Text("Sign in with Passkey")
                                    .fontWeight(.medium)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Color.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 8)
                    }

                    // MARK: Text fields
                    VStack(spacing: 12) {
                        if isRegistering {
                            DarkTextField(
                                icon: "person.fill",
                                placeholder: "Display Name",
                                text: $displayName
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        DarkTextField(
                            icon: "envelope",
                            placeholder: "Email",
                            text: $email,
                            contentType: .emailAddress
                        )

                        DarkTextField(
                            icon: "lock",
                            placeholder: "Password",
                            text: $password,
                            isSecure: true,
                            contentType: isRegistering ? .newPassword : .password,
                            onSubmit: { submit() }
                        )

                        if isRegistering {
                            DarkTextField(
                                icon: "lock.fill",
                                placeholder: "Confirm Password",
                                text: $confirmPassword,
                                isSecure: true,
                                contentType: .newPassword,
                                onSubmit: { submit() }
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.horizontal, 32)

                    // MARK: Validation hints (register mode)
                    if isRegistering && !password.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            hintRow(met: passwordLongEnough, text: "At least 8 characters")
                            hintRow(met: hasUppercase, text: "One uppercase letter")
                            hintRow(met: hasLowercase, text: "One lowercase letter")
                            hintRow(met: hasDigit, text: "One digit")
                            hintRow(met: hasSpecialChar, text: "One special character")
                            if !confirmPassword.isEmpty && !passwordsMatch {
                                hintRow(met: false, text: "Passwords match")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 36)
                        .padding(.top, 4)
                    }

                    // MARK: Success banner
                    if !successMessage.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "envelope.fill")
                                .foregroundStyle(.green.opacity(0.9))
                                .font(.caption)
                            Text(successMessage)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.green.opacity(0.3), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 32)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // MARK: Error banner
                    if !errorMessage.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red.opacity(0.9))
                                .font(.caption)
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.red.opacity(0.3), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 32)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // MARK: Action buttons
                    VStack(spacing: 12) {
                        PrimaryButton(
                            title: isRegistering ? "Create Account" : "Sign In",
                            isDisabled: email.isEmpty || password.isEmpty
                                || (isRegistering && (displayName.isEmpty || !passwordMeetsComplexity || !passwordsMatch))
                                || isLoading,
                            action: { submit() }
                        )

                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isRegistering.toggle()
                                errorMessage = ""
                                confirmPassword = ""
                            }
                        } label: {
                            Text(
                                isRegistering
                                    ? "Already have an account? Sign In"
                                    : "Don't have an account? Create one"
                            )
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
                .frame(width: 380)
            }

            // MARK: Loading overlay
            if isLoading {
                Color(red: 0.043, green: 0.102, blue: 0.18).opacity(0.6)
                    .overlay(.ultraThinMaterial)
                    .overlay {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                                .colorScheme(.dark)
                            Text(isRegistering ? "Creating account..." : "Signing in...")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Bob Animation

    private struct BobAnimation: ViewModifier {
        @State private var animating = false

        func body(content: Content) -> some View {
            content
                .offset(y: animating ? -4 : 4)
                .animation(
                    .easeInOut(duration: 3).repeatForever(autoreverses: true),
                    value: animating
                )
                .task {
                    // Defer to avoid layout recursion with NSHostingView
                    try? await Task.sleep(for: .milliseconds(100))
                    animating = true
                }
        }
    }

    // MARK: - Hint Row

    @ViewBuilder
    private func hintRow(met: Bool, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: met ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(met ? .green.opacity(0.8) : .white.opacity(0.35))
                .font(.caption2)
            Text(text)
                .font(.caption)
                .foregroundStyle(met ? .white.opacity(0.7) : .white.opacity(0.4))
        }
    }

    // MARK: - Apple Sign-In

    // MARK: - Passkey Sign-In

    private func loginWithPasskey() {
        guard #available(macOS 13.0, *) else { return }
        isLoading = true
        Task {
            do {
                let resp = try await APIClient.passkeyLoginBegin(baseURL: httpBaseURL)
                guard let sessionKey = resp["sessionKey"] as? String,
                      let publicKeyDict = resp["publicKey"] as? [String: Any],
                      let challengeB64 = publicKeyDict["challenge"] as? String,
                      let challengeData = Data(base64URLEncoded: challengeB64),
                      let rpId = publicKeyDict["rpId"] as? String else {
                    throw NSError(domain: "Passkey", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
                }

                let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
                let assertionRequest = provider.createCredentialAssertionRequest(challenge: challengeData)

                let credential = try await performAuthorizationRequest(assertionRequest)
                guard let assertion = credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
                    throw NSError(domain: "Passkey", code: 0, userInfo: [NSLocalizedDescriptionKey: "Unexpected credential type"])
                }

                let authResp = try await APIClient.passkeyLoginFinish(
                    baseURL: httpBaseURL,
                    sessionKey: sessionKey,
                    credentialID: assertion.credentialID,
                    authenticatorData: assertion.rawAuthenticatorData,
                    clientDataJSON: assertion.rawClientDataJSON,
                    signature: assertion.signature,
                    userHandle: assertion.userID
                )

                await MainActor.run {
                    onAuthenticated(authResp.accessToken, authResp.refreshToken, authResp.user.id, authResp.user.email ?? "")
                }
            } catch {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        errorMessage = error.localizedDescription
                    }
                    isLoading = false
                }
            }
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
            if #available(macOS 14.0, *), preferImmediatelyAvailable {
                controller.performRequests(options: .preferImmediatelyAvailableCredentials)
            } else {
                controller.performRequests()
            }
        }
    }

    // MARK: - Email/Password Submit

    private func submit() {
        guard !email.isEmpty, !password.isEmpty else { return }
        if isRegistering && displayName.isEmpty { return }
        if isRegistering && (!passwordMeetsComplexity || !passwordsMatch) { return }

        withAnimation(.easeInOut(duration: 0.25)) { errorMessage = "" }
        isLoading = true

        Task {
            do {
                let resp: AuthResponse
                if isRegistering {
                    resp = try await APIClient.emailRegister(
                        baseURL: httpBaseURL,
                        email: email,
                        password: password,
                        displayName: displayName
                    )
                } else {
                    resp = try await APIClient.emailLogin(
                        baseURL: httpBaseURL,
                        email: email,
                        password: password
                    )
                }
                await MainActor.run {
                    isLoading = false
                    errorMessage = ""
                    withAnimation(.easeInOut(duration: 0.25)) {
                        pendingAuth = (resp.accessToken, resp.refreshToken, resp.user.id, email)
                    }
                }
            } catch is EmailVerificationRequired {
                await MainActor.run {
                    isLoading = false
                    withAnimation(.easeInOut(duration: 0.25)) {
                        successMessage = "Check your email to verify your account, then sign in."
                        errorMessage = ""
                        isRegistering = false
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        errorMessage = error.localizedDescription
                        successMessage = ""
                    }
                    isLoading = false
                }
            }
        }
    }

    // MARK: - Passkey Registration

    private func registerPasskeyForAgent(auth: (token: String, refreshToken: String, userId: String, email: String)) {
        guard #available(macOS 13.0, *) else {
            onAuthenticated(auth.token, auth.refreshToken, auth.userId, auth.email)
            return
        }
        isRegisteringPasskey = true
        errorMessage = ""

        Task {
            do {
                let beginResp = try await APIClient.passkeyRegisterBegin(baseURL: httpBaseURL, token: auth.token)
                guard let sessionKey = beginResp["sessionKey"] as? String,
                      let publicKeyDict = beginResp["publicKey"] as? [String: Any],
                      let challengeB64 = publicKeyDict["challenge"] as? String,
                      let challengeData = Data(base64URLEncoded: challengeB64),
                      let rpDict = publicKeyDict["rp"] as? [String: Any],
                      let rpId = rpDict["id"] as? String,
                      let userDict = publicKeyDict["user"] as? [String: Any],
                      let userIdB64 = userDict["id"] as? String,
                      let userId = Data(base64URLEncoded: userIdB64),
                      let userName = userDict["name"] as? String else {
                    throw NSError(domain: "Passkey", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
                }

                let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)
                let registrationRequest = provider.createCredentialRegistrationRequest(
                    challenge: challengeData,
                    name: userName,
                    userID: userId
                )

                let result = try await performAuthorizationRequest(registrationRequest)
                guard let credential = result as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
                      let attestationObject = credential.rawAttestationObject else {
                    throw NSError(domain: "Passkey", code: 0, userInfo: [NSLocalizedDescriptionKey: "Unexpected credential type"])
                }

                try await APIClient.passkeyRegisterFinish(
                    baseURL: httpBaseURL,
                    token: auth.token,
                    sessionKey: sessionKey,
                    credentialID: credential.credentialID,
                    attestationObject: attestationObject,
                    clientDataJSON: credential.rawClientDataJSON
                )

                await MainActor.run {
                    isRegisteringPasskey = false
                    withAnimation(.easeInOut(duration: 0.25)) {
                        passkeySuccess = true
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        errorMessage = error.localizedDescription
                    }
                    isRegisteringPasskey = false
                }
            }
        }
    }
}

// MARK: - Passkey Delegate

private class PasskeyDelegate: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    let continuation: CheckedContinuation<ASAuthorizationCredential, any Error>

    init(continuation: CheckedContinuation<ASAuthorizationCredential, any Error>) {
        self.continuation = continuation
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        continuation.resume(returning: authorization.credential)
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        continuation.resume(throwing: error)
    }
}

// MARK: - Base64URL Data Extension

private extension Data {
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
