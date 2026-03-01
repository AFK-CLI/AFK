import SwiftUI

struct ActiveSessionCard: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: session.status.iconName)
                    .foregroundStyle(session.status.color)
                Text(session.projectName)
                    .font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(session.status.displayName)
                        .font(.caption)
                        .foregroundStyle(session.status.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(session.status.color.opacity(0.15), in: .capsule)
                    if let updatedAt = session.updatedAt {
                        Text(updatedAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if !session.description.isEmpty {
                Text(session.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 16) {
                if !session.gitBranch.isEmpty {
                    Label(session.gitBranch, systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let deviceName = session.deviceName {
                    Label(deviceName, systemImage: "laptopcomputer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 24) {
                StatView(title: "Turns", value: "\(session.turnCount)", icon: "arrow.2.squarepath")
                StatView(title: "Tokens In", value: formatTokens(session.tokensIn), icon: "arrow.down.circle")
                StatView(title: "Tokens Out", value: formatTokens(session.tokensOut), icon: "arrow.up.circle")
            }
        }
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
    }

    private func formatTokens(_ count: Int64) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }
}

struct StatView: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.bold())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
