import SwiftUI

struct SessionHeaderCard: View {
    let session: Session

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // Always-visible compact row
            HStack {
                // Status badge
                HStack(spacing: 6) {
                    Image(systemName: session.status.iconName)
                        .font(.caption)
                    Text(session.status.displayName)
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(session.status.color)

                Spacer()

                // Branch
                if !session.gitBranch.isEmpty {
                    Label(session.gitBranch, systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Token stats row
            HStack(spacing: 16) {
                Label("\(session.turnCount) turns", systemImage: "arrow.right.circle")
                Label(session.tokensIn.formattedTokens + " in", systemImage: "arrow.down.circle")
                Label(session.tokensOut.formattedTokens + " out", systemImage: "arrow.up.circle")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 8)

            // Expandable details
            if isExpanded {
                VStack(spacing: 6) {
                    Divider()
                        .padding(.vertical, 4)

                    if let device = session.deviceName {
                        HStack {
                            Text("Device")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(device)
                        }
                        .font(.caption)
                    }

                    HStack {
                        Text("Project")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(session.projectName)
                    }
                    .font(.caption)

                    if let started = session.startedAt {
                        HStack {
                            Text("Started")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(formatTimestamp(started))
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }
    }


    private func formatTimestamp(_ date: Date) -> String {
        let display = DateFormatter()
        display.dateStyle = .short
        display.timeStyle = .short
        return display.string(from: date)
    }
}
