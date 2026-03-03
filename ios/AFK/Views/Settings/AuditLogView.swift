import SwiftUI
import OSLog

struct AuditLogView: View {
    let apiClient: APIClient
    @State private var entries: [AuditLogEntry] = []
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var offset = 0

    var body: some View {
        List {
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        actionBadge(entry.action)
                        Spacer()
                        Text(formatDate(entry.createdAt))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if !entry.details.isEmpty {
                        Text(entry.details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if let deviceId = entry.deviceId {
                        Text("Device: \(deviceId.prefix(8))...")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if hasMore {
                Button("Load More") {
                    Task { await loadMore() }
                }
                .frame(maxWidth: .infinity)
                .font(.subheadline)
            }
        }
        .navigationTitle("Security Log")
        .overlay {
            if isLoading && entries.isEmpty {
                SymbolSpinner(size: 24)
            }
        }
        .task {
            await loadInitial()
        }
        .refreshable {
            offset = 0
            await loadInitial()
        }
    }

    @ViewBuilder
    private func actionBadge(_ action: String) -> some View {
        let (icon, color) = actionStyle(action)
        Label(action.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: icon)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(color)
    }

    private func actionStyle(_ action: String) -> (String, Color) {
        switch action {
        case "device_created": ("plus.circle", .green)
        case "device_deleted": ("minus.circle", .red)
        case "command_continue": ("play.circle", .blue)
        case "command_cancel": ("stop.circle", .orange)
        case "permission_response": ("hand.raised", .purple)
        case "content_relay": ("arrow.right.circle", .secondary)
        case "project_privacy_changed": ("lock.shield", .yellow)
        default: ("circle", .secondary)
        }
    }

    private func formatDate(_ dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: dateString) else { return dateString }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }

    private func loadInitial() async {
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await apiClient.getAuditLog(limit: 50, offset: 0)
            offset = entries.count
            hasMore = entries.count >= 50
        } catch {
            AppLogger.ui.error("AuditLog: Failed to load: \(error, privacy: .public)")
        }
    }

    private func loadMore() async {
        do {
            let more = try await apiClient.getAuditLog(limit: 50, offset: offset)
            entries.append(contentsOf: more)
            offset += more.count
            hasMore = more.count >= 50
        } catch {
            AppLogger.ui.error("AuditLog: Failed to load more: \(error, privacy: .public)")
        }
    }
}
