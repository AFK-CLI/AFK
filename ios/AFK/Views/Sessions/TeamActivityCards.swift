import SwiftUI

// MARK: - Task Notification Card

struct TaskNotificationCard: View {
    let data: TaskNotificationData
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button {
                if data.result != nil {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: statusIcon)
                        .font(.subheadline)
                        .foregroundStyle(statusColor)
                        .frame(width: 24)

                    Text(data.summary)
                        .font(.subheadline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)

                    Spacer()

                    Text(data.status.capitalized)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(statusColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(statusColor)

                    if data.result != nil {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            // Expandable result
            if isExpanded, let result = data.result {
                Divider()
                    .padding(.horizontal, 12)

                ScrollView {
                    MarkdownText(text: result)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .padding(12)
            }
        }
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusIcon: String {
        switch data.status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "clock.fill"
        default: return "circle.dashed"
        }
    }

    private var statusColor: Color {
        switch data.status {
        case "completed": return .green
        case "in_progress": return .blue
        default: return .gray
        }
    }
}

// MARK: - Teammate Message Card

struct TeammateMessageCard: View {
    let data: TeammateMessageData
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            Button {
                if hasExpandableContent {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(teammateColor.opacity(0.8))
                        .frame(width: 8, height: 8)

                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(teammateColor)

                    Text(displayLabel)
                        .font(.caption)
                        .lineLimit(isExpanded ? nil : 2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if hasExpandableContent {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            // Expandable content
            if isExpanded, let content = data.displayMessage, data.messageType == "message" {
                Divider()
                    .padding(.horizontal, 12)

                ScrollView {
                    MarkdownText(text: content)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .padding(12)
            }
        }
        .background(teammateColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private var hasExpandableContent: Bool {
        data.messageType == "message" && data.displayMessage != nil
    }

    private var icon: String {
        switch data.messageType {
        case "teammate_terminated": return "xmark.circle"
        case "shutdown_approved": return "power"
        case "shutdown_request": return "power"
        default: return "person.circle"
        }
    }

    private var displayLabel: String {
        let name = data.from ?? data.teammateId
        switch data.messageType {
        case "teammate_terminated":
            return data.displayMessage ?? "\(name) has shut down"
        case "shutdown_approved":
            return "\(name) approved shutdown"
        case "shutdown_request":
            return "\(name) requested shutdown"
        case "message":
            if let summary = data.summary, !summary.isEmpty {
                return "\(name): \(summary)"
            }
            return "\(name) sent a message"
        default:
            return "\(name): \(data.messageType.replacingOccurrences(of: "_", with: " "))"
        }
    }

    private var teammateColor: Color {
        switch data.color?.lowercased() {
        case "yellow": return .yellow
        case "blue": return .blue
        case "green": return .green
        case "red": return .red
        case "purple": return .purple
        case "orange": return .orange
        case "cyan": return .cyan
        default: return .gray
        }
    }
}

// MARK: - Previews

#Preview("Task Notification — Completed") {
    ScrollView {
        VStack(spacing: 12) {
            TaskNotificationCard(data: TaskNotificationData(
                taskId: "a439afdf0504cbd15",
                toolUseId: "toolu_01EL9e1Y1QGwsMkLR2VV2fb4",
                status: "completed",
                summary: "Agent \"Explore PR #63 for cherry-pick items\" completed",
                result: """
                ## Thorough Analysis of PR #63 Diff

                I've read the complete 1697-line diff. Here's what you need to cherry-pick:

                ### 1. **DisplayStaticQR Feature**

                **In `web/server/streamer_server.go`:**
                ```go
                func (s *StreamerServer) DisplayStaticQR(ctx context.Context, data string, duration time.Duration) error {
                    if s.displayService == nil {
                        return fmt.Errorf("display service not available")
                    }
                    return s.displayService.DisplayStaticQR(ctx, data, duration)
                }
                ```

                ### 2. **Key Exchange Endpoint**

                - Added `/v1/devices/{id}/key-agreement` endpoint
                - Supports `GET` and `POST` methods
                - Returns public key and version info
                """
            ))

            TaskNotificationCard(data: TaskNotificationData(
                taskId: "b123",
                toolUseId: nil,
                status: "in_progress",
                summary: "Researching authentication patterns in the codebase",
                result: nil
            ))

            TaskNotificationCard(data: TaskNotificationData(
                taskId: "c456",
                toolUseId: nil,
                status: "pending",
                summary: "Waiting for dependency analysis to complete",
                result: nil
            ))
        }
        .padding()
    }
}

#Preview("Teammate Messages") {
    VStack(spacing: 8) {
        TeammateMessageCard(data: TeammateMessageData(
            teammateId: "architect-analyst",
            color: "yellow",
            messageType: "shutdown_approved",
            from: "architect-analyst",
            timestamp: "2026-03-02T08:34:31.586Z",
            displayMessage: nil
        ))

        TeammateMessageCard(data: TeammateMessageData(
            teammateId: "system",
            color: nil,
            messageType: "teammate_terminated",
            from: nil,
            timestamp: nil,
            displayMessage: "architect-analyst has shut down."
        ))

        TeammateMessageCard(data: TeammateMessageData(
            teammateId: "researcher",
            color: "blue",
            messageType: "shutdown_request",
            from: "researcher",
            timestamp: "2026-03-02T08:30:00.000Z",
            displayMessage: nil
        ))

        TeammateMessageCard(data: TeammateMessageData(
            teammateId: "code-reviewer",
            color: "green",
            messageType: "task_completed",
            from: "code-reviewer",
            timestamp: nil,
            displayMessage: nil
        ))
    }
    .padding()
}

#Preview("Mixed Conversation") {
    ScrollView {
        VStack(alignment: .leading, spacing: 8) {
            // Simulates how it looks in a real conversation
            Text("Here are the results from the team analysis:")
                .font(.body)
                .padding(.horizontal, 4)

            TaskNotificationCard(data: TaskNotificationData(
                taskId: "task-1",
                toolUseId: nil,
                status: "completed",
                summary: "Agent \"Explore codebase architecture\" completed",
                result: "Found **3 main modules**: backend, agent, and iOS app. The backend uses Go with WebSocket hub pattern."
            ))

            TeammateMessageCard(data: TeammateMessageData(
                teammateId: "system",
                color: nil,
                messageType: "teammate_terminated",
                from: nil,
                timestamp: nil,
                displayMessage: "architect-analyst has shut down."
            ))

            TeammateMessageCard(data: TeammateMessageData(
                teammateId: "architect-analyst",
                color: "yellow",
                messageType: "shutdown_approved",
                from: "architect-analyst",
                timestamp: nil,
                displayMessage: nil
            ))
        }
        .padding()
    }
}
