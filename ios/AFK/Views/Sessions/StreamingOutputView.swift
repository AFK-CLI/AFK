import SwiftUI

struct StreamingOutputView: View {
    let commandState: CommandStore.CommandState
    let onStop: () -> Void
    let onDismiss: () -> Void
    var onRetry: (() -> Void)?
    var onViewFork: ((String) -> Void)?

    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?

    private var fullText: String {
        commandState.chunks.joined()
    }

    private var tokenEstimate: Int {
        // Rough estimate: ~4 chars per token
        fullText.count / 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                statusLabel
                Spacer()
                actionButtons
            }

            // Stats bar (while running)
            if !commandState.isComplete {
                HStack(spacing: 12) {
                    Label(formattedElapsed, systemImage: "clock")
                    Label("~\(tokenEstimate) tokens", systemImage: "number")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            // Error message
            if let error = commandState.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Fork session banner
            if commandState.isComplete, let forkId = commandState.newSessionId {
                Button {
                    onViewFork?(forkId)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch")
                        Text("View forked session")
                        Spacer()
                        Text(String(forkId.prefix(8)))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .font(.subheadline)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            // Streaming text — only while running (completed text appears in conversation)
            if !fullText.isEmpty && !commandState.isComplete {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(fullText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id("streaming-bottom")
                    }
                    .frame(maxHeight: 200)
                    .padding(8)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onChange(of: fullText) { _, _ in
                        proxy.scrollTo("streaming-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .padding()
        .background(Color(UIColor.systemGroupedBackground))
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
        .onChange(of: commandState.isComplete) { _, isComplete in
            if isComplete { stopTimer() }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if commandState.isComplete {
            if commandState.isCancelled {
                Label("Cancelled", systemImage: "stop.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline.bold())
            } else if commandState.error != nil {
                Label("Failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline.bold())
            } else {
                HStack(spacing: 8) {
                    Label("Completed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline.bold())
                    if let ms = commandState.durationMs {
                        Text(formatDuration(ms))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let cost = commandState.costUsd {
                        Text(String(format: "$%.2f", cost))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            HStack(spacing: 6) {
                SymbolSpinner()
                Text("Running...")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if commandState.isComplete {
            HStack(spacing: 8) {
                if (commandState.error != nil || commandState.isCancelled), let onRetry {
                    Button("Retry") { onRetry() }
                        .font(.subheadline)
                        .buttonStyle(.bordered)
                }
                Button("Dismiss") { onDismiss() }
                    .font(.subheadline)
            }
        } else {
            Button("Stop", role: .destructive) { onStop() }
                .font(.subheadline.bold())
                .buttonStyle(.bordered)
                .tint(.red)
        }
    }

    private func formatDuration(_ ms: Int) -> String {
        let seconds = Double(ms) / 1000.0
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(minutes)m \(secs)s"
    }

    private var formattedElapsed: String {
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            elapsed = Date().timeIntervalSince(commandState.startedAt)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
