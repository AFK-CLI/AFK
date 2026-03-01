//
//  SignInWindowController.swift
//  AFK-Agent
//

import AppKit
import SwiftUI

final class SignInWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func showSignInWindow(serverURL: String, completion: @escaping (String, String, String, String) -> Void) {
        // Prevent duplicate windows
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let signInView = AgentSignInView(serverURL: serverURL) { [weak self] token, refreshToken, userId, email in
            self?.window?.close()
            self?.window = nil
            NSApp.setActivationPolicy(.accessory)
            completion(token, refreshToken, userId, email)
        }

        let hostingView = NSHostingView(rootView: signInView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.043, green: 0.102, blue: 0.18, alpha: 1)
        window.contentView = hostingView
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false

        self.window = window

        // Show in Dock so the window can receive focus
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        window = nil
    }
}
