import SwiftUI

struct PasskeySetupView: View {
    let authService: AuthService
    var onComplete: () -> Void

    @State private var isRegistering = false
    @State private var errorMessage = ""
    @State private var didSucceed = false
    @AppStorage("hasOfferedPasskeySetup", store: BuildEnvironment.userDefaults) private var hasOfferedPasskeySetup = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.043, green: 0.102, blue: 0.18),
                    Color(red: 0.086, green: 0.176, blue: 0.314),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0.23, green: 0.48, blue: 0.97),
                                Color(red: 0.15, green: 0.39, blue: 0.92),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(spacing: 8) {
                    Text("Secure your account with a Passkey")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    Text("Sign in faster next time with Face ID or Touch ID. No password needed.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }

                if didSucceed {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Passkey created successfully!")
                            .foregroundStyle(.white.opacity(0.9))
                            .font(.subheadline)
                    }
                    .padding(12)
                    .background(Color.green.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                if !errorMessage.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red.opacity(0.9))
                            .font(.caption)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(3)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.red.opacity(0.3), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        createPasskey()
                    } label: {
                        if isRegistering {
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                        } else {
                            Text(didSucceed ? "Done" : "Create Passkey")
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                        }
                    }
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
                    .buttonStyle(.plain)
                    .disabled(isRegistering)

                    if !didSucceed {
                        Button {
                            dismiss()
                        } label: {
                            Text("Maybe Later")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .disabled(isRegistering)
                    }
                }
                .padding(.bottom, 40)
            }
            .padding(.horizontal, 32)
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isRegistering)
    }

    private func createPasskey() {
        if didSucceed {
            dismiss()
            return
        }
        isRegistering = true
        errorMessage = ""
        Task {
            do {
                try await authService.registerPasskey()
                await MainActor.run {
                    didSucceed = true
                    isRegistering = false
                }
                try? await Task.sleep(for: .seconds(1.5))
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isRegistering = false
                }
            }
        }
    }

    private func dismiss() {
        hasOfferedPasskeySetup = true
        onComplete()
    }
}
