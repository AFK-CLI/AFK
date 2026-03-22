import SwiftUI

/// Transparency feed showing WWUD (Smart Mode) auto-decisions.
/// Users can see what was auto-approved/denied and override if needed.
struct WWUDDigestView: View {
    let decisions: [WWUDAutoDecision]
    let stats: WWUDStatsPayload?
    let deviceId: String
    let onOverride: (String, String) -> Void  // (decisionId, correctedAction)

    @State private var expandedId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow

            if decisions.isEmpty {
                emptyState
            } else {
                ForEach(decisions.prefix(15)) { decision in
                    decisionRow(decision)
                }
            }
        }
        .padding(.horizontal)
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain")
                .foregroundStyle(.purple)
            Text("Smart Decisions")
                .font(.subheadline.weight(.semibold))
            Spacer()
            if let stats {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption2)
                    Text("\(stats.autoApproved)")
                        .font(.caption2.monospacedDigit())
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption2)
                    Text("\(stats.autoDenied)")
                        .font(.caption2.monospacedDigit())
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple.opacity(0.6))
            Text("Learning from your decisions...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func decisionRow(_ decision: WWUDAutoDecision) -> some View {
        let isExpanded = expandedId == decision.id

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.25)) {
                    expandedId = expandedId == decision.id ? nil : decision.id
                }
            } label: {
                HStack(spacing: 10) {
                    toolIcon(decision.toolName)
                        .frame(width: 24, height: 24)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(decision.toolName)
                            .font(.caption.weight(.medium))
                        Text(decision.toolInputPreview)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    actionBadge(decision.action, confidence: decision.confidence)

                    Text(decision.date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 50, alignment: .trailing)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedContent(decision)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func expandedContent(_ decision: WWUDAutoDecision) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.vertical, 4)

            HStack(spacing: 6) {
                Image(systemName: "target")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(decision.patternDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Confidence: \(Int(decision.confidence * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button {
                    let corrected = decision.action == "allow" ? "deny" : "allow"
                    onOverride(decision.id, corrected)
                    withAnimation {
                        expandedId = nil
                    }
                } label: {
                    Label(
                        decision.action == "allow" ? "Should Deny" : "Should Allow",
                        systemImage: decision.action == "allow" ? "xmark.circle" : "checkmark.circle"
                    )
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        decision.action == "allow" ? Color.red.opacity(0.15) : Color.green.opacity(0.15),
                        in: Capsule()
                    )
                    .foregroundStyle(decision.action == "allow" ? .red : .green)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toolIcon(_ toolName: String) -> some View {
        let icon: String = switch toolName {
        case "Bash": "terminal"
        case "Write": "doc.badge.plus"
        case "Edit": "pencil"
        case "WebFetch": "globe"
        case "WebSearch": "magnifyingglass"
        case "NotebookEdit": "book"
        default: "wrench"
        }
        return Image(systemName: icon)
    }

    private func actionBadge(_ action: String, confidence: Double) -> some View {
        let isAllow = action == "allow"
        return HStack(spacing: 3) {
            Image(systemName: isAllow ? "checkmark" : "xmark")
                .font(.system(size: 8, weight: .bold))
            Text("\(Int(confidence * 100))%")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            (isAllow ? Color.green : Color.red).opacity(0.15),
            in: Capsule()
        )
        .foregroundStyle(isAllow ? .green : .red)
    }
}
