import SwiftUI

struct DiagnosticsView: View {
    let sessionStore: SessionStore
    let wsService: WebSocketService
    @State private var copied = false

    private var snapshot: SessionStore.DiagnosticSnapshot {
        sessionStore.diagnosticSnapshot
    }

    var body: some View {
        List {
            deviceIdentitySection
            e2eeStateSection
            sessionKeysSection
            webSocketSection
            permissionQueueSection
            sessionStateSection
            actionsSection
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Section 1: Device Identity

    private var deviceIdentitySection: some View {
        Section("Device Identity") {
            row("Device ID", snapshot.myDeviceId.map { truncateId($0) } ?? "Not enrolled")
            row("Key Version", snapshot.myKeyVersion.map { "\($0)" } ?? "—")
            row("KA Fingerprint", snapshot.myFingerprint ?? "—")
            row("Capabilities", snapshot.capabilities.isEmpty ? "none" : snapshot.capabilities.joined(separator: ", "))
            row("Enrolled", snapshot.myDeviceId != nil ? "Yes" : "No")
        }
    }

    // MARK: - Section 2: E2EE State

    private var e2eeStateSection: some View {
        Section("E2EE State") {
            row("Service Initialized", snapshot.e2eeInitialized ? "Yes" : "No")
            row("Session Keys Cached", "\(snapshot.sessionKeyCount)")
            row("Historical Keys", "\(snapshot.historicalKeyCount)")
            row("Permission Signing Keys", "\(snapshot.permissionKeyCount)")

            if !snapshot.peers.isEmpty {
                ForEach(snapshot.peers, id: \.deviceId) { peer in
                    peerRow(peer)
                }
            } else {
                Text("No peer devices")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func peerRow(_ peer: SessionStore.PeerDiagnostic) -> some View {
        DisclosureGroup {
            row("Device ID", truncateId(peer.deviceId))
            row("Fingerprint", peer.fingerprint)
            if let ver = peer.keyVersion {
                row("Key Version", "\(ver)")
            }
            row("Capabilities", peer.capabilities.isEmpty ? "—" : peer.capabilities.joined(separator: ", "))
            row("Sessions w/ Keys", "\(peer.sessionsWithKeys)")
        } label: {
            Label {
                Text("Peer \(truncateId(peer.deviceId))")
            } icon: {
                Image(systemName: "laptopcomputer")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Section 3: Session Keys Detail

    private var sessionKeysSection: some View {
        Section("Session Keys (\(snapshot.sessionKeys.count))") {
            if snapshot.sessionKeys.isEmpty {
                Text("No cached session keys")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.sessionKeys, id: \.sessionId) { keyInfo in
                    DisclosureGroup {
                        row("Session", truncateId(keyInfo.sessionId))
                        row("Key Version", "v\(keyInfo.keyVersion)")
                        row("Ephemeral Key", keyInfo.hasEphemeralKey ? "Yes" : "No")
                        if let peerId = keyInfo.peerDeviceId {
                            row("Peer Device", truncateId(peerId))
                        }
                    } label: {
                        HStack {
                            Text(truncateId(keyInfo.sessionId))
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Text("v\(keyInfo.keyVersion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if keyInfo.hasEphemeralKey {
                                Image(systemName: "key.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Section 4: WebSocket State

    private var webSocketSection: some View {
        Section("WebSocket") {
            row("Status", wsService.isConnected ? "Connected" : "Disconnected")
            row("Last Connected", formatDate(wsService.lastConnectedAt))
            row("Last Disconnected", formatDate(wsService.lastDisconnectedAt))
            row("Reconnect Count", "\(wsService.reconnectCount)")
            row("Last Message", formatDate(wsService.lastMessageReceivedAt))
        }
    }

    // MARK: - Section 5: Permission Queue

    private var permissionQueueSection: some View {
        Section("Permissions") {
            row("Pending", "\(snapshot.pendingPermissions.count)")
            row("Queued (E2EE wait)", "\(snapshot.queuedPermissionCount)")

            ForEach(snapshot.pendingPermissions, id: \.nonce) { perm in
                DisclosureGroup {
                    row("Session", truncateId(perm.sessionId))
                    row("Tool", perm.toolName)
                    row("Nonce", String(perm.nonce.prefix(12)) + "...")
                    row("Unverified", perm.isUnverified ? "Yes" : "No")
                    row("Expires In", formatTimeRemaining(perm.timeRemaining))
                } label: {
                    HStack {
                        Text(perm.toolName)
                        Spacer()
                        if perm.isUnverified {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        Text(formatTimeRemaining(perm.timeRemaining))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Section 6: Session State

    private var sessionStateSection: some View {
        Section("Sessions") {
            row("Total", "\(snapshot.totalSessions)")
            row("Dismissed", "\(snapshot.dismissedSessionIds.count)")

            ForEach(Array(snapshot.sessionsByStatus.keys.sorted(by: { $0.nowTabPriority < $1.nowTabPriority })), id: \.self) { status in
                row(status.displayName, "\(snapshot.sessionsByStatus[status] ?? 0)")
            }
        }
    }

    // MARK: - Section 7: Actions

    private var actionsSection: some View {
        Section("Actions") {
            Button {
                UIPasteboard.general.string = buildDiagnosticsText()
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                HStack {
                    Label("Copy Diagnostics", systemImage: "doc.on.doc")
                    if copied {
                        Spacer()
                        Text("Copied")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }

            Button("Force Refresh Device Keys") {
                Task {
                    await sessionStore.refreshDeviceKAKeys()
                }
            }

            Button("Clear Session Key Cache") {
                sessionStore.clearSessionKeyCache()
            }

            Button("Force Reconnect WS") {
                sessionStore.forceReconnectWS()
            }
        }
    }

    // MARK: - Helpers

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func truncateId(_ id: String) -> String {
        if id.count > 12 {
            return String(id.prefix(8)) + "..."
        }
        return id
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func formatTimeRemaining(_ interval: TimeInterval) -> String {
        if interval <= 0 { return "expired" }
        let seconds = Int(interval)
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    // MARK: - Copy to Clipboard

    private func buildDiagnosticsText() -> String {
        let s = snapshot
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var lines: [String] = []
        lines.append("AFK Diagnostics — \(iso.string(from: Date()))")
        lines.append(String(repeating: "=", count: 40))

        // Device Identity
        lines.append("Device ID: \(s.myDeviceId ?? "not enrolled")")
        lines.append("Key Version: \(s.myKeyVersion.map { "\($0)" } ?? "—")")
        lines.append("Fingerprint: \(s.myFingerprint ?? "—")")
        lines.append("Capabilities: \(s.capabilities.joined(separator: ", "))")
        lines.append("")

        // E2EE State
        lines.append("E2EE State:")
        lines.append("  Initialized: \(s.e2eeInitialized)")
        lines.append("  Session keys cached: \(s.sessionKeyCount)")
        lines.append("  Historical keys: \(s.historicalKeyCount)")
        lines.append("  Permission signing keys: \(s.permissionKeyCount)")
        lines.append("")

        // Peers
        if !s.peers.isEmpty {
            lines.append("Peers:")
            for peer in s.peers {
                lines.append("  \(peer.deviceId.prefix(8))...")
                lines.append("    Fingerprint: \(peer.fingerprint)")
                if let ver = peer.keyVersion { lines.append("    Key version: \(ver)") }
                if !peer.capabilities.isEmpty {
                    lines.append("    Capabilities: \(peer.capabilities.joined(separator: ", "))")
                }
                lines.append("    Sessions with keys: \(peer.sessionsWithKeys)")
            }
            lines.append("")
        }

        // Session Keys
        if !s.sessionKeys.isEmpty {
            lines.append("Session Keys:")
            for key in s.sessionKeys {
                let eph = key.hasEphemeralKey ? " [eph]" : ""
                lines.append("  \(key.sessionId.prefix(8))... v\(key.keyVersion)\(eph)")
            }
            lines.append("")
        }

        // WebSocket
        let wsStatus = wsService.isConnected ? "connected" : "disconnected"
        lines.append("WebSocket: \(wsStatus)")
        if let ts = wsService.lastConnectedAt {
            lines.append("  Connected at: \(iso.string(from: ts))")
        }
        if let ts = wsService.lastDisconnectedAt {
            lines.append("  Disconnected at: \(iso.string(from: ts))")
        }
        lines.append("  Reconnects: \(wsService.reconnectCount)")
        if let ts = wsService.lastMessageReceivedAt {
            lines.append("  Last message: \(iso.string(from: ts))")
        }
        lines.append("")

        // Permissions
        lines.append("Permissions:")
        lines.append("  Pending: \(s.pendingPermissions.count)")
        lines.append("  Queued: \(s.queuedPermissionCount)")
        for perm in s.pendingPermissions {
            let unv = perm.isUnverified ? " [unverified]" : ""
            lines.append("  \(perm.toolName) (\(perm.nonce.prefix(8))...) \(formatTimeRemaining(perm.timeRemaining))\(unv)")
        }
        lines.append("")

        // Sessions
        let statusSummary = s.sessionsByStatus
            .sorted { $0.key.nowTabPriority < $1.key.nowTabPriority }
            .map { "\($0.value) \($0.key.displayName.lowercased())" }
            .joined(separator: ", ")
        lines.append("Sessions: \(s.totalSessions) total (\(statusSummary))")
        if !s.dismissedSessionIds.isEmpty {
            lines.append("  Dismissed: \(s.dismissedSessionIds.count)")
        }

        return lines.joined(separator: "\n")
    }
}
