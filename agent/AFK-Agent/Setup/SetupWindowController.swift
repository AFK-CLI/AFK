//
//  SetupWindowController.swift
//  AFK-Agent
//

import AppKit
import SwiftUI

final class SetupWindowController {
    private var window: NSWindow?

    func showSetupWindow(completion: @escaping (AgentConfig) -> Void) {
        // Temporarily show in Dock so the window can receive focus
        NSApp.setActivationPolicy(.regular)

        let setupView = SetupView { config in
            // Switch back to accessory (menu bar only)
            NSApp.setActivationPolicy(.accessory)
            self.window?.close()
            self.window = nil
            completion(config)
        }

        let hostingView = NSHostingView(rootView: setupView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 450, height: 400)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "AFK Agent Setup"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = WindowCloseDelegate.shared

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Terminates the app if the setup window is closed without saving.
private final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    static let shared = WindowCloseDelegate()

    func windowWillClose(_ notification: Notification) {
        // If the app is still in .regular mode, user closed without saving
        if NSApp.activationPolicy() == .regular {
            NSApp.terminate(nil)
        }
    }
}
