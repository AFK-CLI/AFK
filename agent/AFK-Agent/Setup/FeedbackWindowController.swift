import AppKit
import SwiftUI

final class FeedbackWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func showFeedbackWindow(onSubmit: @escaping (String, String) -> Void) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentSize = NSSize(width: 420, height: 380)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.043, green: 0.102, blue: 0.18, alpha: 1)
        window.contentMinSize = contentSize
        window.contentMaxSize = contentSize
        window.title = "Send Feedback"

        let feedbackView = AgentFeedbackView { [weak self] category, message in
            self?.window?.close()
            self?.window = nil
            NSApp.setActivationPolicy(.accessory)
            onSubmit(category, message)
        } onCancel: { [weak self] in
            self?.window?.close()
            self?.window = nil
            NSApp.setActivationPolicy(.accessory)
        }

        let hostingView = NSHostingView(rootView: feedbackView)
        hostingView.frame = NSRect(origin: .zero, size: contentSize)
        window.contentView = hostingView
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        self.window = window

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        window = nil
    }
}
