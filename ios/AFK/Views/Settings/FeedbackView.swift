import SwiftUI
import OSLog

struct FeedbackView: View {
    let apiClient: APIClient
    let deviceId: String
    @State private var category = "general"
    @State private var message = ""
    @State private var isSubmitting = false
    @State private var showSuccess = false
    @State private var history: [FeedbackEntry] = []
    @State private var historyOffset = 0
    @State private var hasMoreHistory = true

    var body: some View {
        List {
            Section("Submit Feedback") {
                Picker("Category", selection: $category) {
                    Text("Bug Report").tag("bug_report")
                    Text("Feature Request").tag("feature_request")
                    Text("General").tag("general")
                }
                .pickerStyle(.segmented)

                ZStack(alignment: .topLeading) {
                    if message.isEmpty {
                        Text("Describe your feedback...")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                    }
                    TextEditor(text: $message)
                        .frame(minHeight: 120)
                }

                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        if isSubmitting {
                            ProgressView()
                        }
                        Text("Submit")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(message.isEmpty || isSubmitting)
            }

            Section("History") {
                ForEach(history) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            categoryBadge(entry.category)
                            Spacer()
                            Text(formatDate(entry.createdAt))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Text(entry.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)

                        if let platform = entry.platform, let version = entry.appVersion {
                            Text("\(platform) v\(version)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                if hasMoreHistory {
                    Button("Load More") {
                        Task { await loadMoreHistory() }
                    }
                    .frame(maxWidth: .infinity)
                    .font(.subheadline)
                }
            }
        }
        .navigationTitle("Feedback")
        .alert("Feedback Sent", isPresented: $showSuccess) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Thank you for your feedback!")
        }
        .task {
            await loadHistory()
        }
    }

    @ViewBuilder
    private func categoryBadge(_ cat: String) -> some View {
        let (icon, color) = categoryStyle(cat)
        Label(cat.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
    }

    private func categoryStyle(_ cat: String) -> (String, Color) {
        switch cat {
        case "bug_report": ("ladybug", .red)
        case "feature_request": ("lightbulb", .yellow)
        case "general": ("bubble.left", .blue)
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

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        do {
            _ = try await apiClient.submitFeedback(
                deviceId: deviceId,
                category: category,
                message: message,
                appVersion: appVersion
            )
            message = ""
            showSuccess = true
            await loadHistory()
        } catch {
            AppLogger.feedback.error("Submit failed: \(error, privacy: .public)")
        }
    }

    private func loadHistory() async {
        historyOffset = 0
        do {
            history = try await apiClient.listFeedback(limit: 50, offset: 0)
            historyOffset = history.count
            hasMoreHistory = history.count >= 50
        } catch {
            AppLogger.feedback.error("Failed to load history: \(error, privacy: .public)")
        }
    }

    private func loadMoreHistory() async {
        do {
            let more = try await apiClient.listFeedback(limit: 50, offset: historyOffset)
            history.append(contentsOf: more)
            historyOffset += more.count
            hasMoreHistory = more.count >= 50
        } catch {
            AppLogger.feedback.error("Failed to load more: \(error, privacy: .public)")
        }
    }
}
