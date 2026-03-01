import SwiftUI
import Combine

struct PermissionBanner: View {
    let event: SessionEvent
    let permissionRequest: PermissionRequest?
    let onApprove: ((String) -> Void)?
    let onDeny: ((String) -> Void)?

    @State private var responded: String?  // "allow" or "deny"

    init(
        event: SessionEvent,
        permissionRequest: PermissionRequest? = nil,
        onApprove: ((String) -> Void)? = nil,
        onDeny: ((String) -> Void)? = nil
    ) {
        self.event = event
        self.permissionRequest = permissionRequest
        self.onApprove = onApprove
        self.onDeny = onDeny
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: responded != nil ? responseIcon : "lock.fill")
                    .foregroundStyle(responded != nil ? responseColor : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(responded != nil ? responseLabel : "Permission Needed")
                        .font(.subheadline.weight(.medium))
                    if let toolName = event.toolName ?? permissionRequest?.toolName {
                        Text("\(toolName) is waiting for approval")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let request = permissionRequest, responded == nil {
                    CountdownBadge(expiresAt: request.expiresAtDate)
                }
            }

            // Tool input preview
            if let request = permissionRequest, !request.toolInputPreview.isEmpty {
                Text(request.toolInputPreview)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(UIColor.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 4))
            }

            // Approve/Deny buttons (only when we have a real permission request)
            if let request = permissionRequest, responded == nil {
                if request.isExpired {
                    Text("Expired")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 12) {
                        Button {
                            responded = "allow"
                            onApprove?(request.nonce)
                        } label: {
                            Label("Approve", systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)

                        Button {
                            responded = "deny"
                            onDeny?(request.nonce)
                        } label: {
                            Label("Deny", systemImage: "xmark.circle.fill")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
            }
        }
        .padding(12)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 8))
    }

    private var backgroundColor: Color {
        switch responded {
        case "allow": return Color.green.opacity(0.1)
        case "deny": return Color.red.opacity(0.1)
        default: return Color.orange.opacity(0.1)
        }
    }

    private var responseIcon: String {
        responded == "allow" ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private var responseColor: Color {
        responded == "allow" ? .green : .red
    }

    private var responseLabel: String {
        responded == "allow" ? "Approved" : "Denied"
    }
}

struct CountdownBadge: View {
    let expiresAt: Date
    @State private var remaining: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(formattedTime)
            .font(.caption.monospacedDigit())
            .foregroundStyle(remaining < 30 ? .red : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(UIColor.tertiarySystemGroupedBackground), in: Capsule())
            .onReceive(timer) { _ in
                remaining = max(0, expiresAt.timeIntervalSinceNow)
            }
            .onAppear {
                remaining = max(0, expiresAt.timeIntervalSinceNow)
            }
    }

    private var formattedTime: String {
        let seconds = Int(remaining)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

struct ErrorBanner: View {
    let event: SessionEvent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Error")
                    .font(.subheadline.weight(.medium))
                if let toolName = event.toolName {
                    Text("\(toolName) encountered an error")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SessionLifecycleBanner: View {
    let event: SessionEvent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch event.eventType {
        case "session_started":      return "play.circle.fill"
        case "session_completed":    return "checkmark.circle.fill"
        case "session_idle":         return "pause.circle.fill"
        case "assistant_responding": return "text.bubble.fill"
        case "turn_completed":       return "checkmark"
        default:                     return "circle"
        }
    }

    private var iconColor: Color {
        switch event.eventType {
        case "session_started":      return .green
        case "session_completed":    return .gray
        case "session_idle":         return .yellow
        case "assistant_responding": return .blue
        case "turn_completed":       return .green
        default:                     return .secondary
        }
    }

    private var label: String {
        switch event.eventType {
        case "session_started":      return "Session started"
        case "session_completed":    return "Session completed"
        case "session_idle":         return "Session idle"
        case "assistant_responding": return "Assistant responded"
        case "turn_completed":
            if let ms = event.payload?["durationMs"], let val = Double(ms) {
                if val >= 60000 {
                    return "Turn completed (\(String(format: "%.0fm %.0fs", val / 60000, (val.truncatingRemainder(dividingBy: 60000)) / 1000)))"
                } else if val >= 1000 {
                    return "Turn completed (\(String(format: "%.1fs", val / 1000)))"
                }
                return "Turn completed (\(Int(val))ms)"
            }
            return "Turn completed"
        default: return event.displayTitle
        }
    }
}
