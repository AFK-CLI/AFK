//
//  SessionPickerWindow.swift
//  AFK-Agent
//

import AppKit
import SwiftUI

struct SessionEntry {
    let sessionId: String
    let projectPath: String
    let status: String
}

final class SessionPickerWindow: NSObject, NSWindowDelegate {
    private var panel: NSPanel?

    func show(sessions: [SessionEntry], onCopy: @escaping (SessionEntry) -> Void) {
        if let existing = panel {
            existing.close()
            panel = nil
        }

        let pickerView = SessionPickerView(sessions: sessions) { [weak self] entry in
            onCopy(entry)
            self?.panel?.close()
            self?.panel = nil
        }

        let contentSize = NSSize(width: 380, height: min(CGFloat(sessions.count * 56 + 48), 400))

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Copy Resume Command"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let hostingView = NSHostingView(rootView: pickerView)
        hostingView.frame = NSRect(origin: .zero, size: contentSize)
        panel.contentView = hostingView
        panel.center()

        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}

private struct SessionPickerView: View {
    let sessions: [SessionEntry]
    let onCopy: (SessionEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Select a session to copy its resume command:")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(sessions.enumerated()), id: \.offset) { _, entry in
                        SessionRow(entry: entry, onCopy: onCopy)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }
}

private struct SessionRow: View {
    let entry: SessionEntry
    let onCopy: (SessionEntry) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(projectName)
                    .font(.system(.body, design: .default, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(shortId)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)

                    Text(entry.status)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.15))
                        .foregroundColor(statusColor)
                        .cornerRadius(4)
                }
            }

            Spacer()

            Button("Copy") {
                onCopy(entry)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }

    private var projectName: String {
        if entry.projectPath.isEmpty { return "Unknown Project" }
        return (entry.projectPath as NSString).lastPathComponent
    }

    private var shortId: String {
        String(entry.sessionId.prefix(8))
    }

    private var statusColor: Color {
        switch entry.status {
        case "running": return .green
        case "idle": return .orange
        case "waitingPermission": return .yellow
        case "error": return .red
        default: return .secondary
        }
    }
}
