import SwiftUI
import AuthenticationServices

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
                            Color(red: 0.15, green: 0.39, blue: 0.92)
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
    @State private var isLoading = false

    private var passwordsMatch: Bool { password == confirmPassword }
    private var passwordLongEnough: Bool { password.count >= 8 }

    private var canSubmit: Bool {
        if isRegistering {
            return !email.isEmpty && passwordLongEnough && passwordsMatch && !isLoading
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
                    Color(red: 0.086, green: 0.176, blue: 0.314)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            StarfieldView()
                .ignoresSafeArea()

            // MARK: Content
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
                    .padding(.top, 48)
                    .padding(.bottom, 28)

                    // MARK: Apple Sign In
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.email, .fullName]
                    } onCompletion: { result in
                        switch result {
                        case .success:
                            print("[SignIn] Apple Sign-In dialog succeeded")
                        case .failure(let error):
                            print("[SignIn] Apple Sign-In dialog failed — \(error.localizedDescription)")
                        }
                        Task {
                            await authService.handleSignInWithApple(result: result)
                        }
                    }
                    .signInWithAppleButtonStyle(.whiteOutline)
                    .frame(height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 32)

                    // MARK: Divider
                    HStack(spacing: 12) {
                        Rectangle()
                            .fill(Color.white.opacity(0.15))
                            .frame(height: 0.5)
                        Text("or")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                        Rectangle()
                            .fill(Color.white.opacity(0.15))
                            .frame(height: 0.5)
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)

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
                    if isRegistering {
                        VStack(alignment: .leading, spacing: 4) {
                            if !password.isEmpty && !passwordLongEnough {
                                Text("Password must be at least 8 characters")
                                    .font(.caption)
                                    .foregroundStyle(.red.opacity(0.9))
                            }
                            if !confirmPassword.isEmpty && !passwordsMatch {
                                Text("Passwords do not match")
                                    .font(.caption)
                                    .foregroundStyle(.red.opacity(0.9))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 36)
                        .padding(.top, 4)
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

                    Spacer().frame(height: 40)
                }
            }
            .scrollDismissesKeyboard(.interactively)

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
    }

    // MARK: - Submit

    private func submit() {
        guard canSubmit else { return }

        withAnimation(.easeInOut(duration: 0.25)) { errorMessage = "" }
        isLoading = true

        Task {
            do {
                if isRegistering {
                    try await authService.register(
                        email: email,
                        password: password,
                        displayName: displayName
                    )
                } else {
                    try await authService.signIn(email: email, password: password)
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
