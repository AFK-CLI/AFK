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
                        RelativeTimeText(date: updatedAt)
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
                StatView(title: "Tokens In", value: session.tokensIn.formattedTokens, icon: "arrow.down.circle")
                StatView(title: "Tokens Out", value: session.tokensOut.formattedTokens, icon: "arrow.up.circle")
                if session.costUsd > 0 {
                    StatView(title: "Cost", value: session.costUsd.formattedCost, icon: "dollarsign.circle")
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
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
