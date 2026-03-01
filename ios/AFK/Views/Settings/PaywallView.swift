import SwiftUI
import StoreKit

struct PaywallView: View {
    let subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) private var dismiss
    @State private var isPurchasing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                // Background: same as SignInView
                LinearGradient(
                    colors: [
                        Color(red: 0.043, green: 0.102, blue: 0.18),
                        Color(red: 0.086, green: 0.176, blue: 0.314)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                StarfieldView()
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        headerSection
                        featureSection
                        productSection

                        Spacer().frame(height: 16)

                        footerSection
                    }
                }

                // Purchasing overlay
                if isPurchasing {
                    Color(red: 0.043, green: 0.102, blue: 0.18).opacity(0.6)
                        .overlay(.ultraThinMaterial)
                        .overlay {
                            VStack(spacing: 12) {
                                ProgressView()
                                    .scaleEffect(1.2)
                                    .tint(.white)
                                Text("Processing...")
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        .ignoresSafeArea()
                }
            }
            .preferredColorScheme(.dark)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.6))
                            .font(.title3)
                    }
                }
            }
            .task {
                await subscriptionManager.loadProducts()
            }
            .alert("Error", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image("AppIcon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 6)

            Text("AFK Pro")
                .font(.title.bold())
                .foregroundStyle(.white)

            Text("Unlock the full power of AFK")
                .font(.body)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.top, 64)
        .padding(.bottom, 32)
    }

    // MARK: - Features

    private var featureSection: some View {
        VStack(spacing: 0) {
            featureRow(icon: "desktopcomputer", title: "Unlimited Devices", detail: "Connect all your Macs and iPhones", included: true)
            featureRow(icon: "clock.arrow.circlepath", title: "90-Day History", detail: "Extended session and event retention", included: true)
            featureRow(icon: "terminal", title: "Remote Continue", detail: "Send prompts from anywhere", included: false)
            featureRow(icon: "lock.shield", title: "End-to-End Encryption", detail: "Zero-knowledge privacy", included: false)
        }
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, 32)
        .padding(.bottom, 28)
    }

    private func featureRow(icon: String, title: String, detail: String, included: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.white.opacity(included ? 0.9 : 0.5))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
            }

            Spacer()

            if included {
                Text("PRO")
                    .font(.caption2.bold())
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
            } else {
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Products

    private var productSection: some View {
        VStack(spacing: 10) {
            if subscriptionManager.isLoading {
                ProgressView()
                    .tint(.white)
                    .padding(.vertical, 24)
            } else if subscriptionManager.products.isEmpty {
                Text("Products unavailable")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.vertical, 24)
            } else {
                ForEach(subscriptionManager.products, id: \.id) { product in
                    productCard(product)
                }
            }
        }
        .padding(.horizontal, 32)
    }

    private func productCard(_ product: Product) -> some View {
        let isYearly = product.id.contains("yearly")

        return Button {
            Task {
                isPurchasing = true
                defer { isPurchasing = false }
                do {
                    _ = try await subscriptionManager.purchase(product)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(product.displayName)
                            .font(.headline)
                            .foregroundStyle(.white)

                        if isYearly {
                            Text("BEST VALUE")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }

                    Text(product.description)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }

                Spacer()

                Text(product.displayPrice)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing)
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: 14) {
            Button {
                Task { await subscriptionManager.restorePurchases() }
            } label: {
                Text("Restore Purchases")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)

            Text("Subscriptions automatically renew unless cancelled at least 24 hours before the end of the current period. Manage subscriptions in Settings > Apple ID > Subscriptions.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.25))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(.bottom, 32)
    }
}
