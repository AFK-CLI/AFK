import SwiftUI

struct ServerSetupView: View {
    var onConfigured: () -> Void
    @State private var serverURL = "https://afk.ahmetbirinci.dev"
    @State private var isValidating = false
    @State private var errorMessage: String?

    private var hasValidHost: Bool {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme), let host = url.host, !host.isEmpty else { return false }
        return host.contains(".")
    }

    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [
                    Color(red: 0.043, green: 0.102, blue: 0.18),
                    Color(red: 0.086, green: 0.176, blue: 0.314)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            StarfieldView(starCount: 20)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Hero
                VStack(spacing: 16) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 64))
                        .foregroundStyle(.white.opacity(0.8))
                        .modifier(BobModifier())

                    Text("Connect to Server")
                        .font(.title.bold())
                        .foregroundStyle(.white)

                    Text("Enter your AFK server URL to get started.")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }

                Spacer().frame(height: 36)

                // Server URL field
                HStack(spacing: 10) {
                    Image(systemName: "globe")
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 16)

                    TextField("https://afk.example.com", text: $serverURL)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)

                    if !serverURL.isEmpty {
                        Button {
                            serverURL = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 50)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                )
                .padding(.horizontal, 32)
                .colorScheme(.dark)

                // Error message
                if let errorMessage {
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
                }

                Spacer()
                Spacer()

                // Connect button
                Button(action: validateAndConnect) {
                    Group {
                        if isValidating {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Connect")
                                .fontWeight(.semibold)
                        }
                    }
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
                .opacity(isValidating || !hasValidHost ? 0.4 : 1)
                .disabled(isValidating || !hasValidHost)
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
            .padding()
        }
        .preferredColorScheme(.dark)
    }

    private func validateAndConnect() {
        errorMessage = nil

        var url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "https://\(url)"
        }
        while url.hasSuffix("/") {
            url.removeLast()
        }

        guard let parsed = URL(string: url), let host = parsed.host, !host.isEmpty else {
            errorMessage = "Enter a valid server URL"
            return
        }
        _ = host

        guard let healthURL = URL(string: "\(url)/healthz") else {
            errorMessage = "Invalid URL format"
            return
        }

        isValidating = true

        Task {
            do {
                let (_, response) = try await URLSession.shared.data(from: healthURL)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    await MainActor.run {
                        errorMessage = "Server returned HTTP \(code) — expected 200"
                        isValidating = false
                    }
                    return
                }
                await MainActor.run {
                    AppConfig.configure(apiURL: url)
                    isValidating = false
                    onConfigured()
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Cannot reach server: \(error.localizedDescription)"
                    isValidating = false
                }
            }
        }
    }
}

// MARK: - Bob Animation (internal, used by ServerSetupView)

private struct BobModifier: ViewModifier {
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
