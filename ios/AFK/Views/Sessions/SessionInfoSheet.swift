import SwiftUI

struct SessionInfoSheet: View {
    let session: Session
    var siblingsSessions: [Session] = []

    @Environment(\.dismiss) private var dismiss
    @State private var copiedToast = false

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    row("Status", value: session.status.displayName, icon: session.status.iconName, color: session.status.color)

                    if !session.gitBranch.isEmpty {
                        row("Branch", value: session.gitBranch, icon: "arrow.triangle.branch")
                    }

                    if let device = session.deviceName {
                        row("Device", value: device, icon: "desktopcomputer")
                    }
                }

                Section("Stats") {
                    row("Turns", value: "\(session.turnCount)", icon: "arrow.right.circle")
                    row("Tokens In", value: formatTokens(session.tokensIn), icon: "arrow.down.circle")
                    row("Tokens Out", value: formatTokens(session.tokensOut), icon: "arrow.up.circle")
                }

                Section("Details") {
                    row("Project", value: session.projectName, icon: "folder")

                    if !session.description.isEmpty {
                        row("Description", value: session.description, icon: "text.quote")
                    }

                    if let started = session.startedAt {
                        row("Started", value: formatTimestamp(started), icon: "clock")
                    }

                    row("Session ID", value: String(session.id.prefix(8)) + "...", icon: "number")
                }

                Section("Resume on Mac") {
                    Button {
                        UIPasteboard.general.string = "cd \(session.projectPath) && claude --resume \(session.id)"
                        copiedToast = true
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(.success)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            copiedToast = false
                        }
                    } label: {
                        HStack {
                            Label("Copy resume command", systemImage: "doc.on.doc")
                            Spacer()
                            if copiedToast {
                                Text("Copied!")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }

                if !siblingsSessions.isEmpty {
                    Section("Other Sessions in Project") {
                        ForEach(siblingsSessions) { sibling in
                            HStack {
                                Image(systemName: sibling.status.iconName)
                                    .foregroundStyle(sibling.status.color)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sibling.status.displayName)
                                        .font(.subheadline)
                                    if let device = sibling.deviceName {
                                        Text(device)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text("\(sibling.turnCount) turns")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Session Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, value: String, icon: String, color: Color = .secondary) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .foregroundStyle(color)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
        }
    }

    private func formatTokens(_ count: Int64) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        }
        if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000.0)
        }
        return "\(count)"
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
