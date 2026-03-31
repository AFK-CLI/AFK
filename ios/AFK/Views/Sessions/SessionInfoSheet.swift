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
                    row("Tokens In", value: session.tokensIn.formattedTokens, icon: "arrow.down.circle")
                    row("Tokens Out", value: session.tokensOut.formattedTokens, icon: "arrow.up.circle")
                    if session.costUsd > 0 {
                        row("Estimated Cost", value: session.costUsd.formattedCost, icon: "dollarsign.circle")
                    }
                    if let model = session.lastModel, !model.isEmpty {
                        row("Model", value: Self.prettyModelName(model), icon: "cpu")
                    }
                    if session.otlpCacheReadTokens > 0 || session.otlpCacheCreationTokens > 0 {
                        row("Cache Read", value: session.otlpCacheReadTokens.formattedTokens, icon: "arrow.counterclockwise.circle")
                        row("Cache Write", value: session.otlpCacheCreationTokens.formattedTokens, icon: "plus.circle")
                        let total = session.otlpCacheReadTokens + session.otlpCacheCreationTokens
                        if total > 0 {
                            let hitRate = Double(session.otlpCacheReadTokens) / Double(total) * 100
                            row("Cache Hit Rate", value: String(format: "%.0f%%", hitRate), icon: "chart.pie")
                        }
                    }
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
                    row("Provider", value: session.providerDisplayName, icon: session.providerIcon)
                }

                if session.supportsResume {
                    Section("Resume on Mac") {
                        Button {
                            UIPasteboard.general.string = session.resumeCommand
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

    static func prettyModelName(_ raw: String) -> String {
        // "claude-opus-4-6" → "Opus 4.6"
        // "claude-sonnet-4-5-20250929" → "Sonnet 4.5"
        // "claude-3-5-sonnet-20241022" → "Sonnet 3.5"
        var s = raw
        if s.hasPrefix("claude-") { s = String(s.dropFirst(7)) }
        if let range = s.range(of: #"-\d{8}$"#, options: .regularExpression) {
            s = String(s[s.startIndex..<range.lowerBound])
        }
        let parts = s.split(separator: "-").map(String.init)
        guard parts.count >= 2 else { return raw }

        // Find the family name (first non-numeric part)
        if let familyIdx = parts.firstIndex(where: { $0.first?.isLetter == true }) {
            let family = parts[familyIdx].capitalized
            var versionParts = parts
            versionParts.remove(at: familyIdx)
            let version = versionParts.joined(separator: ".")
            return version.isEmpty ? family : "\(family) \(version)"
        }
        return raw
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
