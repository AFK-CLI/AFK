import SwiftUI

struct PromptComposer: View {
    let sessionId: String
    let commandStore: CommandStore
    let apiClient: APIClient
    var isDisabled: Bool = false
    @AppStorage("biometricGateEnabled", store: BuildEnvironment.userDefaults) private var biometricGateEnabled = false
    @State private var prompt = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var showTemplates = false

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending && !isDisabled
    }

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 0) {
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.top, 4)
                }

                if prompt.isEmpty && !isDisabled {
                    quickActionButtons
                }

                inputField
            }
        }
        .sheet(isPresented: $showTemplates) {
            NavigationStack {
                List {
                    Section("Quick Actions") {
                        ForEach(CommandTemplate.builtIn) { template in
                            Button {
                                prompt = template.prompt
                                showTemplates = false
                                Task { await send() }
                            } label: {
                                Label(template.name, systemImage: template.icon)
                            }
                        }
                    }
                }
                .navigationTitle("Templates")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showTemplates = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    @ViewBuilder
    private var inputField: some View {
        HStack(alignment: .bottom, spacing: 12) {
            Button {
                showTemplates.toggle()
            } label: {
                Image(systemName: "plus.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
            }
            .glassEffect(.regular.interactive(), in: .circle)

            TextField("Send a message...", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))

            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? .blue : .gray)
                    .frame(width: 36, height: 36)
            }
            .disabled(!canSend)
            .glassEffect(.regular.interactive(), in: .circle)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var quickActionButtons: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(CommandTemplate.builtIn.prefix(4))) { template in
                    QuickActionPill(title: template.name, icon: template.icon) {
                        prompt = template.prompt
                        Task { await send() }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private func send() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if biometricGateEnabled {
            let biometric = BiometricService()
            do {
                try await biometric.authenticate(reason: "Authenticate to send command")
            } catch {
                errorMessage = "Authentication required"
                return
            }
        }

        isSending = true
        errorMessage = nil
        defer { isSending = false }

        do {
            let response = try await apiClient.continueSession(sessionId: sessionId, prompt: text)
            commandStore.startCommand(id: response.commandId, sessionId: sessionId, prompt: text)
            prompt = ""
        } catch {
            errorMessage = "Failed to send: \(error.localizedDescription)"
        }
    }
}

// MARK: - Quick Action Pill

struct QuickActionPill: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}
