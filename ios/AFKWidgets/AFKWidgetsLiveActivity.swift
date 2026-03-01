import ActivityKit
import WidgetKit
import SwiftUI

// Duplicate attributes for widget target (must match main app's SessionActivityAttributes)
struct SessionActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var status: String
        var currentTool: String?
        var turnCount: Int
        var elapsedSeconds: Int
        var agentCount: Int?
    }

    var sessionId: String
    var projectName: String
    var deviceName: String
}

struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            lockScreenView(context: context)
                .activityBackgroundTint(.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        codeIcon(size: 12, color: statusColor(context.state.status))
                        Text(context.attributes.projectName)
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    statusPill(status: context.state.status)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        if let tool = context.state.currentTool {
                            toolChip(tool: tool, status: context.state.status)
                        }

                        HStack {
                            HStack(spacing: 4) {
                                Image(systemName: "desktopcomputer")
                                    .font(.system(size: 9))
                                Text(context.attributes.deviceName)
                                    .font(.system(.caption2, design: .rounded))
                            }
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)

                            Spacer()

                            statsRow(
                                turnCount: context.state.turnCount,
                                elapsed: context.state.elapsedSeconds
                            )
                        }
                    }
                }
            } compactLeading: {
                codeIcon(size: 11, color: statusColor(context.state.status))
            } compactTrailing: {
                Text(context.attributes.projectName.prefix(10))
                    .font(.system(.caption2, design: .rounded, weight: .medium))
            } minimal: {
                codeIcon(size: 10, color: statusColor(context.state.status))
            }
            .widgetURL(URL(string: "afk://session/\(context.attributes.sessionId)"))
        }
    }

    // MARK: - Lock Screen

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<SessionActivityAttributes>) -> some View {
        HStack(spacing: 0) {
            // Left accent bar — instant status color at a glance
            RoundedRectangle(cornerRadius: 1.5)
                .fill(statusColor(context.state.status).gradient)
                .frame(width: 3)
                .padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 0) {
                // Header: project + status pill
                HStack {
                    codeIcon(size: 15, color: statusColor(context.state.status))

                    Text(context.attributes.projectName)
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .lineLimit(1)

                    Spacer()

                    statusPill(status: context.state.status)
                }

                // Gradient separator
                gradientRule(status: context.state.status)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                // Active tool
                if let tool = context.state.currentTool {
                    toolChip(tool: tool, status: context.state.status)
                        .padding(.bottom, 8)
                }

                // Footer: device + stats
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 9))
                        Text(context.attributes.deviceName)
                            .font(.system(.caption2, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.4))

                    if let count = context.state.agentCount, count > 1 {
                        agentCountBadge(count: count)
                    }

                    Spacer()

                    statsRow(
                        turnCount: context.state.turnCount,
                        elapsed: context.state.elapsedSeconds
                    )
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Components

    @ViewBuilder
    private func codeIcon(size: CGFloat, color: Color) -> some View {
        Image(systemName: "chevron.left.forwardslash.chevron.right")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func statusPill(status: String) -> some View {
        HStack(spacing: 4) {
            if status == "running" {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                    .shadow(color: .green.opacity(0.5), radius: 3)
            } else {
                Image(systemName: statusIcon(status))
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(statusLabel(status))
                .font(.system(.caption2, design: .rounded, weight: .semibold))
        }
        .foregroundStyle(statusColor(status))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor(status).opacity(0.15), in: Capsule())
    }

    @ViewBuilder
    private func toolChip(tool: String, status: String) -> some View {
        HStack(spacing: 0) {
            // Left accent line (terminal gutter feel)
            RoundedRectangle(cornerRadius: 1)
                .fill(statusColor(status))
                .frame(width: 2)
                .padding(.vertical, 3)

            HStack(spacing: 5) {
                Text("\u{276F}")
                    .font(.system(.caption2, design: .monospaced, weight: .heavy))
                    .foregroundStyle(statusColor(status).opacity(0.7))
                Text(tool)
                    .font(tool.contains(" ") ?
                        .system(.caption, design: .rounded) :
                        .system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
        }
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func agentCountBadge(count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "person.2")
                .font(.system(size: 9))
            Text("\(count)")
                .font(.system(.caption2, design: .rounded, weight: .medium))
        }
        .foregroundStyle(.cyan.opacity(0.8))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.cyan.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private func gradientRule(status: String) -> some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        statusColor(status).opacity(0.5),
                        statusColor(status).opacity(0.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
    }

    @ViewBuilder
    private func statsRow(turnCount: Int, elapsed: Int) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9))
                Text("\(turnCount)")
                    .font(.system(.caption2, design: .monospaced, weight: .medium))
                    .contentTransition(.numericText())
            }
            HStack(spacing: 3) {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                Text(formatElapsed(elapsed))
                    .font(.system(.caption2, design: .monospaced, weight: .medium))
                    .contentTransition(.numericText())
            }
        }
        .foregroundStyle(.white.opacity(0.4))
    }

    // MARK: - Helpers

    private func statusIcon(_ status: String) -> String {
        switch status {
        case "running": return "play.circle.fill"
        case "waiting_permission": return "lock.fill"
        case "waiting_input": return "keyboard"
        case "error": return "exclamationmark.triangle.fill"
        case "completed": return "checkmark.circle.fill"
        default: return "circle"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "running": return .green
        case "waiting_permission": return .orange
        case "waiting_input": return .orange
        case "error": return .red
        case "completed": return .gray
        default: return .secondary
        }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "running": return "Running"
        case "waiting_permission": return "Approve"
        case "waiting_input": return "Input"
        case "error": return "Error"
        case "completed": return "Done"
        default: return status.capitalized
        }
    }

    private func formatElapsed(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Previews

private let previewAttributes = SessionActivityAttributes(
    sessionId: "preview-1",
    projectName: "afk-cloud",
    deviceName: "My Mac"
)

#Preview("Running — Lock Screen", as: .content, using: previewAttributes) {
    SessionLiveActivity()
} contentStates: {
    SessionActivityAttributes.ContentState(
        status: "running",
        currentTool: "Read  internal/handler/auth.go",
        turnCount: 5,
        elapsedSeconds: 70
    )
}

#Preview("Approval — Lock Screen", as: .content, using: previewAttributes) {
    SessionLiveActivity()
} contentStates: {
    SessionActivityAttributes.ContentState(
        status: "waiting_permission",
        currentTool: "Bash  rm -rf node_modules",
        turnCount: 3,
        elapsedSeconds: 42
    )
}

#Preview("Error — Lock Screen", as: .content, using: previewAttributes) {
    SessionLiveActivity()
} contentStates: {
    SessionActivityAttributes.ContentState(
        status: "error",
        currentTool: nil,
        turnCount: 0,
        elapsedSeconds: 2
    )
}

#Preview("Done — Lock Screen", as: .content, using: previewAttributes) {
    SessionLiveActivity()
} contentStates: {
    SessionActivityAttributes.ContentState(
        status: "completed",
        currentTool: nil,
        turnCount: 12,
        elapsedSeconds: 185
    )
}

#Preview("Running — Expanded Island", as: .dynamicIsland(.expanded), using: previewAttributes) {
    SessionLiveActivity()
} contentStates: {
    SessionActivityAttributes.ContentState(
        status: "running",
        currentTool: "Edit  Sources/App/main.swift",
        turnCount: 8,
        elapsedSeconds: 94
    )
}

#Preview("Approval — Expanded Island", as: .dynamicIsland(.expanded), using: previewAttributes) {
    SessionLiveActivity()
} contentStates: {
    SessionActivityAttributes.ContentState(
        status: "waiting_permission",
        currentTool: "Bash  docker compose up -d",
        turnCount: 4,
        elapsedSeconds: 55
    )
}

#Preview("Running — Compact Island", as: .dynamicIsland(.compact), using: previewAttributes) {
    SessionLiveActivity()
} contentStates: {
    SessionActivityAttributes.ContentState(
        status: "running",
        currentTool: nil,
        turnCount: 3,
        elapsedSeconds: 30
    )
}

#Preview("Minimal Island", as: .dynamicIsland(.minimal), using: previewAttributes) {
    SessionLiveActivity()
} contentStates: {
    SessionActivityAttributes.ContentState(
        status: "running",
        currentTool: nil,
        turnCount: 1,
        elapsedSeconds: 10
    )
}
