import SwiftUI

struct PermissionOverlay: View {
    let request: PermissionRequest
    let onApprove: () -> Void
    let onDeny: () -> Void

    @AppStorage("biometricGateEnabled", store: BuildEnvironment.userDefaults) private var biometricGateEnabled = false
    @State private var biometricError: String?

    private var requiresBiometric: Bool {
        biometricGateEnabled && request.toolName == "Bash"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with tool name and countdown
            HStack {
                Image(systemName: request.isUnverified ? "exclamationmark.shield.fill" : "lock.shield.fill")
                    .foregroundStyle(request.isUnverified ? .yellow : .orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Permission Required")
                        .font(.subheadline.weight(.semibold))
                    Text(request.toolName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                CountdownBadge(expiresAt: request.expiresAtDate)
            }

            // Unverified warning
            if request.isUnverified {
                Label("Unverified — Secure connection pending", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }

            // Tool input preview
            if !request.toolInputPreview.isEmpty {
                Text(request.toolInputPreview)
                    .font(.caption.monospaced())
                    .lineLimit(3)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(UIColor.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Biometric error
            if let biometricError {
                Label(biometricError, systemImage: "faceid")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // Action buttons
            HStack(spacing: 12) {
                Button(action: onDeny) {
                    Label("Deny", systemImage: "xmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button(action: handleApprove) {
                    Label(
                        "Approve",
                        systemImage: requiresBiometric ? "faceid" : "checkmark.circle.fill"
                    )
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 12, y: -4)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func handleApprove() {
        guard requiresBiometric else {
            onApprove()
            return
        }

        biometricError = nil
        Task {
            do {
                try await BiometricService().authenticate(reason: "Authenticate to approve Bash command")
                await MainActor.run { onApprove() }
            } catch {
                await MainActor.run { biometricError = "Authentication failed" }
            }
        }
    }
}
