import SwiftUI
import OSLog

struct LogsView: View {
    let apiClient: APIClient
    @State private var entries: [AppLogEntry] = []
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var offset = 0
    @State private var selectedLevel: String?
    @State private var selectedSource: String?

    var body: some View {
        List {
            Section {
                Picker("Level", selection: $selectedLevel) {
                    Text("All").tag(String?.none)
                    Text("Debug").tag(String?.some("debug"))
                    Text("Info").tag(String?.some("info"))
                    Text("Warn").tag(String?.some("warn"))
                    Text("Error").tag(String?.some("error"))
                }
                .pickerStyle(.menu)

                Picker("Source", selection: $selectedSource) {
                    Text("All").tag(String?.none)
                    Text("Agent").tag(String?.some("agent"))
                    Text("iOS").tag(String?.some("ios"))
                }
                .pickerStyle(.menu)
            }

            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        levelBadge(entry.level)
                        Text(entry.subsystem)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(formatDate(entry.createdAt))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(entry.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)

                    if let deviceId = entry.deviceId {
                        HStack(spacing: 4) {
                            Image(systemName: "desktopcomputer")
                                .font(.caption2)
                            Text(deviceId.prefix(8) + "...")
                                .font(.caption2)
                        }
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
        .navigationTitle("Logs")
        .overlay {
            if isLoading && entries.isEmpty {
                SymbolSpinner(size: 24)
            }
        }
        .task {
            await loadInitial()
        }
        .refreshable {
            await loadInitial()
        }
        .onChange(of: selectedLevel) {
            Task { await loadInitial() }
        }
        .onChange(of: selectedSource) {
            Task { await loadInitial() }
        }
    }

    @ViewBuilder
    private func levelBadge(_ level: String) -> some View {
        let (icon, color) = levelStyle(level)
        Label(level.capitalized, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
    }

    private func levelStyle(_ level: String) -> (String, Color) {
        switch level {
        case "debug": ("ant", .secondary)
        case "info": ("info.circle", .blue)
        case "warn": ("exclamationmark.triangle", .orange)
        case "error": ("xmark.octagon", .red)
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
        offset = 0
        do {
            entries = try await apiClient.getAppLogs(
                level: selectedLevel,
                source: selectedSource,
                limit: 50,
                offset: 0
            )
            offset = entries.count
            hasMore = entries.count >= 50
        } catch {
            AppLogger.ui.error("LogsView: Failed to load: \(error, privacy: .public)")
        }
    }

    private func loadMore() async {
        do {
            let more = try await apiClient.getAppLogs(
                level: selectedLevel,
                source: selectedSource,
                limit: 50,
                offset: offset
            )
            entries.append(contentsOf: more)
            offset += more.count
            hasMore = more.count >= 50
        } catch {
            AppLogger.ui.error("LogsView: Failed to load more: \(error, privacy: .public)")
        }
    }
}
