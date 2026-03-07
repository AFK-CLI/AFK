import SwiftUI

struct CompactChatSheet: View {
    let summary: String
    let projectPath: String
    let deviceId: String
    let apiClient: APIClient
    let commandStore: CommandStore
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var isSending = false
    @State private var errorMessage: String?

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                summaryContent
                Spacer(minLength: 0)
                inputArea
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Continue from Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Summary

    private var summaryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Explanation header
                Label("Session compacted", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Text("The summary below captures your previous session. Type a message to start a new session with this context.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                // Summary card
                VStack(alignment: .leading, spacing: 0) {
                    MarkdownText(text: summary)
                        .textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding()
        }
    }

    // MARK: - Input

    private var inputArea: some View {
        VStack(spacing: 0) {
            Divider()

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            GlassEffectContainer {
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("What should the new session do?", text: $prompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))

                    Button {
                        Task { await send() }
                    } label: {
                        Group {
                            if isSending {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.up.circle.fill")
                            }
                        }
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
        }
    }

    // MARK: - Send

    private func send() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isSending = true
        errorMessage = nil
        defer { isSending = false }

        let combined = "Here is the compacted context from a previous session:\n\n\(summary)\n\n---\n\nUser request: \(text)"

        do {
            let response = try await apiClient.newChat(
                prompt: combined,
                projectPath: projectPath,
                deviceId: deviceId,
                useWorktree: false
            )
            commandStore.startCommand(id: response.commandId, sessionId: "", prompt: text)
            dismiss()
        } catch {
            errorMessage = "Failed to start: \(error.localizedDescription)"
        }
    }
}
