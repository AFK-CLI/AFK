import SwiftUI

// MARK: - Starfield Background

struct StarfieldView: View {
    private struct Star {
        let x, y, size: CGFloat
        let opacity: Double
    }

    private struct Meteor {
        let startX, startY, angle, trailLength, speed: CGFloat
        let cyclePeriod, offset: Double
    }

    let starCount: Int

    init(starCount: Int = 30) {
        self.starCount = starCount
    }

    // Truly random, evaluated once per process via static let
    private static let allStars: [Star] = {
        (0..<50).map { _ in
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
                for star in Self.allStars.prefix(starCount) {
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
                        let fade: Double =
                            if progress < 0.1 {
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
                        context.stroke(
                            trail,
                            with: .linearGradient(
                                Gradient(colors: [.clear, .white]),
                                startPoint: CGPoint(x: tailX, y: tailY),
                                endPoint: CGPoint(x: headX, y: headY)
                            ), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))

                        // Bright head dot
                        context.opacity = fade * 0.9
                        context.fill(
                            Circle().path(
                                in: CGRect(
                                    x: headX - 1, y: headY - 1, width: 2, height: 2
                                )), with: .color(.white))
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Dark Text Field (iOS)

private struct DarkTextField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var contentType: UITextContentType? = nil
    var keyboardType: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .never
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
                        .keyboardType(keyboardType)
                        .textInputAutocapitalization(autocapitalization)
                        .autocorrectionDisabled()
                        .onSubmit { onSubmit?() }
                }
            }
            .textFieldStyle(.plain)
            .foregroundStyle(.white)
            .focused($isFocused)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
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

    var body: some View {
        Button(action: action) {
            Text(title)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.23, green: 0.48, blue: 0.97),
                            Color(red: 0.15, green: 0.39, blue: 0.92),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .opacity(isDisabled ? 0.4 : 1)
        .disabled(isDisabled)
    }
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
            .onAppear { animating = true }
    }
}

// MARK: - Sign In View

struct SignInView: View {
    let authService: AuthService

    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var displayName = ""
    @State private var isRegistering = false
    @State private var errorMessage = ""
    @State private var successMessage = ""
    @State private var isLoading = false
    @State private var showPasskeySetup = false
    @AppStorage("hasOfferedPasskeySetup", store: BuildEnvironment.userDefaults) private var hasOfferedPasskeySetup = false

    private var passwordsMatch: Bool { password == confirmPassword }
    private var passwordLongEnough: Bool { password.count >= 8 }
    private var hasUppercase: Bool { password.range(of: "[A-Z]", options: .regularExpression) != nil }
    private var hasLowercase: Bool { password.range(of: "[a-z]", options: .regularExpression) != nil }
    private var hasDigit: Bool { password.range(of: "[0-9]", options: .regularExpression) != nil }
    private var hasSpecialChar: Bool { password.range(of: "[^A-Za-z0-9]", options: .regularExpression) != nil }
    private var passwordMeetsComplexity: Bool { passwordLongEnough && hasUppercase && hasLowercase && hasDigit && hasSpecialChar }

    private var canSubmit: Bool {
        if isRegistering {
            return !email.isEmpty && passwordMeetsComplexity && passwordsMatch && !isLoading
        } else {
            return !email.isEmpty && !password.isEmpty && !isLoading
        }
    }

    var body: some View {
        ZStack {
            // MARK: Background
            LinearGradient(
                colors: [
                    Color(red: 0.043, green: 0.102, blue: 0.18),
                    Color(red: 0.086, green: 0.176, blue: 0.314),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            StarfieldView()
                .ignoresSafeArea()

            // MARK: Content
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 0) {
                        // MARK: Hero
                        VStack(spacing: 12) {
                            Image("AppIcon")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 88, height: 88)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                                .modifier(BobAnimation())

                            Text("AFK")
                                .font(.title.bold())
                                .foregroundStyle(.white)

                            Text("Monitor Claude Code sessions\nfrom your iPhone")
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.6))
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 100)
                        .padding(.bottom, 32)

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
                                .frame(height: 50)
                                .background(Color.white.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 32)
                            .padding(.bottom, 8)
                        }

                        // MARK: Text Fields
                        VStack(spacing: 12) {
                            if isRegistering {
                                DarkTextField(
                                    icon: "person.fill",
                                    placeholder: "Display Name (optional)",
                                    text: $displayName,
                                    autocapitalization: .words
                                )
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            DarkTextField(
                                icon: "envelope",
                                placeholder: "Email",
                                text: $email,
                                contentType: .emailAddress,
                                keyboardType: .emailAddress
                            )

                            DarkTextField(
                                icon: "lock",
                                placeholder: "Password",
                                text: $password,
                                isSecure: true,
                                contentType: isRegistering ? .newPassword : .password,
                                onSubmit: { if !isRegistering { submit() } }
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
                            VStack(alignment: .leading, spacing: 4) {
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

                        // MARK: Success Banner
                        if !successMessage.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "envelope.circle.fill")
                                    .foregroundStyle(.green.opacity(0.9))
                                    .font(.caption)
                                Text(successMessage)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.9))
                                    .lineLimit(3)
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

                        // MARK: Error Banner
                        if !errorMessage.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red.opacity(0.9))
                                    .font(.caption)
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.9))
                                    .lineLimit(3)
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

                        Spacer()
                            .frame(minHeight: 40)

                        // MARK: Action Buttons
                        VStack(spacing: 12) {
                            PrimaryButton(
                                title: isRegistering ? "Create Account" : "Sign In",
                                isDisabled: !canSubmit,
                                action: { submit() }
                            )

                            Button {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    isRegistering.toggle()
                                    errorMessage = ""
                                    successMessage = ""
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
                        .padding(.bottom, 40)
                    }
                    .frame(minHeight: geo.size.height)
                }
                .scrollDismissesKeyboard(.interactively)
            }

            // MARK: Loading Overlay
            if isLoading {
                Color(red: 0.043, green: 0.102, blue: 0.18).opacity(0.6)
                    .overlay(.ultraThinMaterial)
                    .overlay {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                                .tint(.white)
                            Text(isRegistering ? "Creating account..." : "Signing in...")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPasskeySetup) {
            PasskeySetupView(authService: authService) {
                showPasskeySetup = false
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

    // MARK: - Passkey

    private func loginWithPasskey() {
        isLoading = true
        Task {
            do {
                try await authService.loginWithPasskey()
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

    // MARK: - Submit

    private func submit() {
        guard canSubmit else { return }

        withAnimation(.easeInOut(duration: 0.25)) {
            errorMessage = ""
            successMessage = ""
        }
        isLoading = true

        Task {
            do {
                if isRegistering {
                    try await authService.register(
                        email: email,
                        password: password,
                        displayName: displayName
                    )
                    await MainActor.run {
                        isLoading = false
                        showPasskeySetup = true
                    }
                } else {
                    try await authService.signIn(email: email, password: password)
                    await MainActor.run {
                        isLoading = false
                        if !hasOfferedPasskeySetup {
                            showPasskeySetup = true
                        }
                    }
                }
            } catch AuthError.emailVerificationRequired {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        successMessage = "Account created! Check your email to verify, then sign in."
                        isRegistering = false
                    }
                    isLoading = false
                }
            } catch AuthError.emailNotVerified {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        errorMessage = "Please verify your email before signing in. Check your inbox."
                    }
                    isLoading = false
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
}
