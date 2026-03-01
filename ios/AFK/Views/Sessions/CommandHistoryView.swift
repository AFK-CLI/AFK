import SwiftUI

struct CommandHistoryView: View {
    let sessionId: String
    let commandStore: CommandStore
    var onRetry: ((String) -> Void)?

    var body: some View {
        let history = commandStore.history(for: sessionId)

        if history.isEmpty {
            ContentUnavailableView("No Command History", systemImage: "clock.arrow.circlepath")
        } else {
            List(history.indices, id: \.self) { index in
                let cmd = history[index]
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        statusIcon(for: cmd)
                        Text(cmd.prompt ?? "Command")
                            .font(.subheadline)
                            .lineLimit(2)
                        Spacer()
                        Text(cmd.startedAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let error = cmd.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }

                    if !cmd.chunks.isEmpty {
                        Text(cmd.chunks.joined().prefix(100) + "...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .swipeActions(edge: .trailing) {
                    if let prompt = cmd.prompt, let onRetry {
                        Button("Retry") { onRetry(prompt) }
                            .tint(.blue)
                    }
                }
            }
            .navigationTitle("Command History")
        }
    }

    @ViewBuilder
    private func statusIcon(for cmd: CommandStore.CommandState) -> some View {
        if cmd.isCancelled {
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(.orange)
        } else if cmd.error != nil {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}
