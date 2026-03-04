import SwiftUI

struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.status.iconName)
                .foregroundStyle(session.status.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.projectName)
                    .font(.body.bold())
                if !session.description.isEmpty {
                    Text(session.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    if !session.gitBranch.isEmpty {
                        Text(session.gitBranch)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(session.turnCount) turns")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(session.status.displayName)
                    .font(.caption2)
                    .foregroundStyle(session.status.color)
                if let updatedAt = session.updatedAt {
                    RelativeTimeText(date: updatedAt)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
