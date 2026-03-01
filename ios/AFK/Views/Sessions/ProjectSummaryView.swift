import SwiftUI

struct ProjectSummaryView: View {
    let projectName: String
    let sessions: [Session]
    let events: [String: [SessionEvent]]

    private var summary: ProjectChangeSummary {
        ProjectChangeSummary.compute(sessions: sessions, events: events)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.blue)
                Text("What Changed")
                    .font(.headline)
            }

            if summary.isEmpty {
                Text("No recent activity")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ], spacing: 8) {
                    summaryItem(icon: "arrow.turn.down.right", label: "Turns", count: summary.newTurns, color: .blue)
                    summaryItem(icon: "wrench.fill", label: "Tool Calls", count: summary.toolCalls, color: .orange)
                    summaryItem(icon: "exclamationmark.triangle", label: "Errors", count: summary.errors, color: .red)
                    summaryItem(icon: "doc.text", label: "File Changes", count: summary.fileChanges, color: .green)
                }

                if let since = summary.sinceDate {
                    Text("Since \(since, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func summaryItem(icon: String, label: String, count: Int, color: Color) -> some View {
        if count > 0 {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.caption)
                VStack(alignment: .leading) {
                    Text("\(count)")
                        .font(.subheadline.bold())
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ProjectChangeSummary {
    var newTurns: Int = 0
    var toolCalls: Int = 0
    var errors: Int = 0
    var fileChanges: Int = 0
    var sinceDate: Date?

    var isEmpty: Bool {
        newTurns == 0 && toolCalls == 0 && errors == 0 && fileChanges == 0
    }

    /// Compute a local-only summary using event types (no content needed, works in encrypted mode).
    static func compute(sessions: [Session], events: [String: [SessionEvent]], since: Date? = nil) -> ProjectChangeSummary {
        let cutoff = since ?? Date().addingTimeInterval(-3600 * 2) // default: last 2 hours
        var summary = ProjectChangeSummary(sinceDate: cutoff)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for session in sessions {
            guard let sessionEvents = events[session.id] else { continue }
            let recentEvents = sessionEvents.filter {
                guard let date = isoFormatter.date(from: $0.timestamp) else { return false }
                return date > cutoff
            }

            for event in recentEvents {
                switch event.eventType {
                case "assistant_responding":
                    summary.newTurns += 1
                case "tool_started":
                    summary.toolCalls += 1
                case "error_raised":
                    summary.errors += 1
                default:
                    break
                }
            }

            // Count file changes from tool names
            let fileTools = recentEvents.filter {
                $0.eventType == "tool_started" && ($0.toolName == "Edit" || $0.toolName == "Write")
            }
            summary.fileChanges += fileTools.count
        }

        return summary
    }
}
