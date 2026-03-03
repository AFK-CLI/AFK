import SwiftUI
import OSLog

struct SubscriptionStatusView: View {
    let subscriptionManager: SubscriptionManager
    let apiClient: APIClient
    @State private var tier: String = "free"
    @State private var expiresAt: String?
    @State private var showPaywall = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Plan")
                        tierBadge
                    }

                    if let expiresAt, tier == "pro" {
                        Text("Renews \(formattedDate(expiresAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if tier == "contributor" {
                        Text("Lifetime access")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if tier == "free" {
                    Button("Upgrade") { showPaywall = true }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                } else if tier == "pro" {
                    Button("Manage") {
                        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.blue)
                }
            }
        }
        .task {
            await fetchStatus()
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(subscriptionManager: subscriptionManager)
        }
    }

    @ViewBuilder
    private var tierBadge: some View {
        switch tier {
        case "pro":
            Text("PRO")
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor)
                .clipShape(Capsule())
                .foregroundStyle(.white)
        case "contributor":
            Text("CONTRIBUTOR")
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor)
                .clipShape(Capsule())
                .foregroundStyle(.white)
        default:
            Text("FREE")
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.gray.opacity(0.3))
                .clipShape(Capsule())
                .foregroundStyle(.secondary)
        }
    }

    private func fetchStatus() async {
        do {
            let status = try await apiClient.getSubscriptionStatus()
            tier = status.tier
            expiresAt = status.expiresAt
        } catch {
            AppLogger.subscription.error("Failed to fetch status: \(error, privacy: .public)")
        }
    }

    private func formattedDate(_ dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            let display = DateFormatter()
            display.dateStyle = .medium
            return display.string(from: date)
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: dateString) {
            let display = DateFormatter()
            display.dateStyle = .medium
            return display.string(from: date)
        }
        return dateString
    }
}
