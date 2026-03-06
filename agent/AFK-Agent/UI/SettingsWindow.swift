//
//  SettingsWindow.swift
//  AFK-Agent
//

import AppKit
import OSLog
import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var panel: NSPanel?
    private var config: AgentConfig
    private var onConfigChanged: ((AgentConfig) -> Void)?
    private var onRemoteApprovalChanged: ((Bool) -> Void)?
    #if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
    #endif

    private override init() {
        self.config = AgentConfig.load()
        super.init()
    }

    func configure(
        config: AgentConfig,
        sleepPreventer: SleepPreventer,
        onConfigChanged: @escaping (AgentConfig) -> Void,
        onRemoteApprovalChanged: @escaping (Bool) -> Void
    ) {
        self.config = config
        self.onConfigChanged = onConfigChanged
        self.onRemoteApprovalChanged = onRemoteApprovalChanged
    }

    #if canImport(Sparkle)
    func setUpdaterController(_ controller: SPUStandardUpdaterController) {
        self.updaterController = controller
    }
    #endif

    func show() {
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let isRemoteApprovalOn = !StatusBarController.isHookBypassed

        let settingsView = SettingsContentView(
            obeySettingsRules: config.obeySettingsRules,
            preventSleep: config.preventSleep,
            ctrlClickTogglesRemoteAndSleep: config.ctrlClickTogglesRemoteAndSleep,
            remoteApprovalEnabled: isRemoteApprovalOn,
            notifyOnIdle: config.notifyOnIdle,
            autoCheckForUpdates: config.updateCheckInterval > 0,
            updateCheckInterval: config.updateCheckInterval,
            onSave: { [weak self] settings in
                self?.applySettings(settings)
            },
            onCheckNow: { [weak self] in
                self?.checkForUpdatesNow()
            }
        )

        let contentSize = NSSize(width: 400, height: 530)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "AFK Agent Settings"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.frame = NSRect(origin: .zero, size: contentSize)
        panel.contentView = hostingView
        panel.center()

        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applySettings(_ settings: SettingsValues) {
        config = AgentConfig(
            serverURL: config.serverURL,
            deviceID: config.deviceID,
            authToken: config.authToken,
            claudeProjectsPath: config.claudeProjectsPath,
            heartbeatInterval: config.heartbeatInterval,
            idleTimeout: config.idleTimeout,
            completedTimeout: config.completedTimeout,
            permissionStallTimeout: config.permissionStallTimeout,
            remoteApprovalEnabled: config.remoteApprovalEnabled,
            remoteApprovalTimeout: config.remoteApprovalTimeout,
            hookInstallPath: config.hookInstallPath,
            defaultPrivacyMode: config.defaultPrivacyMode,
            projectPrivacyOverrides: config.projectPrivacyOverrides,
            acceptLegacyPermissionFallback: config.acceptLegacyPermissionFallback,
            deviceName: config.deviceName,
            logLevel: config.logLevel,
            hooksEnabled: config.hooksEnabled,
            planAutoExit: config.planAutoExit,
            obeySettingsRules: settings.obeySettingsRules,
            preventSleep: settings.preventSleep,
            ctrlClickTogglesRemoteAndSleep: settings.ctrlClickTogglesRemoteAndSleep,
            notifyOnIdle: settings.notifyOnIdle,
            updateCheckInterval: settings.updateCheckInterval
        )
        config.save()
        onConfigChanged?(config)
        onRemoteApprovalChanged?(settings.remoteApprovalEnabled)

        #if canImport(Sparkle)
        if let updater = updaterController?.updater {
            updater.updateCheckInterval = settings.updateCheckInterval
            updater.automaticallyChecksForUpdates = settings.updateCheckInterval > 0
        }
        #endif

        AppLogger.statusBar.info("Settings saved")
    }

    private func checkForUpdatesNow() {
        #if canImport(Sparkle)
        updaterController?.checkForUpdates(nil)
        #endif
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}

// MARK: - Settings Values

struct SettingsValues {
    var obeySettingsRules: Bool
    var preventSleep: Bool
    var ctrlClickTogglesRemoteAndSleep: Bool
    var remoteApprovalEnabled: Bool
    var notifyOnIdle: Bool
    var updateCheckInterval: TimeInterval
}

// MARK: - Settings SwiftUI View

private struct SettingsContentView: View {
    @State var obeySettingsRules: Bool
    @State var preventSleep: Bool
    @State var ctrlClickTogglesRemoteAndSleep: Bool
    @State var remoteApprovalEnabled: Bool
    @State var notifyOnIdle: Bool
    @State var autoCheckForUpdates: Bool
    @State var updateCheckInterval: TimeInterval

    let onSave: (SettingsValues) -> Void
    let onCheckNow: () -> Void

    private let intervalOptions: [(String, TimeInterval)] = [
        ("1 hour", 3600),
        ("6 hours", 21600),
        ("12 hours", 43200),
        ("24 hours", 86400)
    ]

    init(
        obeySettingsRules: Bool,
        preventSleep: Bool,
        ctrlClickTogglesRemoteAndSleep: Bool,
        remoteApprovalEnabled: Bool,
        notifyOnIdle: Bool,
        autoCheckForUpdates: Bool,
        updateCheckInterval: TimeInterval,
        onSave: @escaping (SettingsValues) -> Void,
        onCheckNow: @escaping () -> Void
    ) {
        _obeySettingsRules = State(initialValue: obeySettingsRules)
        _preventSleep = State(initialValue: preventSleep)
        _ctrlClickTogglesRemoteAndSleep = State(initialValue: ctrlClickTogglesRemoteAndSleep)
        _remoteApprovalEnabled = State(initialValue: remoteApprovalEnabled)
        _notifyOnIdle = State(initialValue: notifyOnIdle)
        _autoCheckForUpdates = State(initialValue: autoCheckForUpdates)
        _updateCheckInterval = State(initialValue: updateCheckInterval)
        self.onSave = onSave
        self.onCheckNow = onCheckNow
    }

    var body: some View {
        Form {
            GroupBox(label: Label("Permission", systemImage: "shield.lefthalf.filled")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Obey settings.json rules", isOn: $obeySettingsRules)
                    Toggle("Remote Approval", isOn: $remoteApprovalEnabled)
                }
                .padding(.vertical, 4)
            }

            GroupBox(label: Label("Power", systemImage: "bolt.fill")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Prevent Sleep", isOn: $preventSleep)
                }
                .padding(.vertical, 4)
            }

            GroupBox(label: Label("Notifications", systemImage: "bell.badge")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Notify when Claude is idle", isOn: $notifyOnIdle)
                    Text("Shows a macOS notification and turns the menu bar icon orange when Claude is waiting for input.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            GroupBox(label: Label("Shortcuts", systemImage: "keyboard")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Ctrl+Click toggles Remote + Sleep", isOn: $ctrlClickTogglesRemoteAndSleep)
                }
                .padding(.vertical, 4)
            }

            GroupBox(label: Label("Updates", systemImage: "arrow.triangle.2.circlepath")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Auto-check for updates", isOn: $autoCheckForUpdates)

                    if autoCheckForUpdates {
                        Picker("Check interval:", selection: $updateCheckInterval) {
                            ForEach(intervalOptions, id: \.1) { name, interval in
                                Text(name).tag(interval)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Button("Check Now") {
                        onCheckNow()
                    }
                }
                .padding(.vertical, 4)
            }

            HStack {
                Spacer()
                Button("Save") {
                    let effectiveInterval = autoCheckForUpdates ? updateCheckInterval : 0
                    onSave(SettingsValues(
                        obeySettingsRules: obeySettingsRules,
                        preventSleep: preventSleep,
                        ctrlClickTogglesRemoteAndSleep: ctrlClickTogglesRemoteAndSleep,
                        remoteApprovalEnabled: remoteApprovalEnabled,
                        notifyOnIdle: notifyOnIdle,
                        updateCheckInterval: effectiveInterval
                    ))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 400)
    }
}
