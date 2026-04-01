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

    private var window: NSWindow?
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
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let isRemoteApprovalOn = !StatusBarController.isHookBypassed

        let settingsView = SettingsRootView(
            obeySettingsRules: config.obeySettingsRules,
            preventSleep: config.preventSleep,
            ctrlClickTogglesRemoteAndSleep: config.ctrlClickTogglesRemoteAndSleep,
            remoteApprovalEnabled: isRemoteApprovalOn,
            notifyOnIdle: config.notifyOnIdle,
            usagePollingEnabled: config.usagePollingEnabled,
            autoCheckForUpdates: config.updateCheckInterval > 0,
            updateCheckInterval: config.updateCheckInterval,
            onSave: { [weak self] settings in
                self?.applySettings(settings)
            },
            onCheckNow: { [weak self] in
                self?.checkForUpdatesNow()
            },
            onFeedback: {
                NotificationCenter.default.post(name: .settingsFeedbackRequested, object: nil)
            }
        )

        let contentSize = NSSize(width: 600, height: 480)

        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "AFK Agent Settings"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.level = .floating
        win.titlebarAppearsTransparent = true
        win.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)

        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.frame = NSRect(origin: .zero, size: contentSize)
        win.contentView = hostingView
        win.center()

        self.window = win
        win.makeKeyAndOrderFront(nil)
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
            usagePollingEnabled: settings.usagePollingEnabled,
            updateCheckInterval: settings.updateCheckInterval,
            enabledProviders: config.enabledProviders,
            openCodePollInterval: config.openCodePollInterval,
            openCodeServerPort: config.openCodeServerPort,
            hookServerPort: config.hookServerPort,
            hookServerEnabled: config.hookServerEnabled
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
        window = nil
    }
}

extension Notification.Name {
    static let settingsFeedbackRequested = Notification.Name("settingsFeedbackRequested")
}

// MARK: - Settings Values

struct SettingsValues {
    var obeySettingsRules: Bool
    var preventSleep: Bool
    var ctrlClickTogglesRemoteAndSleep: Bool
    var remoteApprovalEnabled: Bool
    var notifyOnIdle: Bool
    var usagePollingEnabled: Bool
    var updateCheckInterval: TimeInterval
}

// MARK: - Settings Tab

private enum SettingsTab: String, CaseIterable {
    case general = "General"
    case updates = "Updates"
    case about = "About"

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .updates: "arrow.triangle.2.circlepath"
        case .about: "info.circle.fill"
        }
    }
}

// MARK: - Root View (Sidebar + Content)

private struct SettingsRootView: View {
    @State var obeySettingsRules: Bool
    @State var preventSleep: Bool
    @State var ctrlClickTogglesRemoteAndSleep: Bool
    @State var remoteApprovalEnabled: Bool
    @State var notifyOnIdle: Bool
    @State var usagePollingEnabled: Bool
    @State var autoCheckForUpdates: Bool
    @State var updateCheckInterval: TimeInterval
    @State private var selectedTab: SettingsTab = .general
    @State private var showSaveConfirmation = false

    let onSave: (SettingsValues) -> Void
    let onCheckNow: () -> Void
    let onFeedback: () -> Void

    init(
        obeySettingsRules: Bool,
        preventSleep: Bool,
        ctrlClickTogglesRemoteAndSleep: Bool,
        remoteApprovalEnabled: Bool,
        notifyOnIdle: Bool,
        usagePollingEnabled: Bool,
        autoCheckForUpdates: Bool,
        updateCheckInterval: TimeInterval,
        onSave: @escaping (SettingsValues) -> Void,
        onCheckNow: @escaping () -> Void,
        onFeedback: @escaping () -> Void
    ) {
        _obeySettingsRules = State(initialValue: obeySettingsRules)
        _preventSleep = State(initialValue: preventSleep)
        _ctrlClickTogglesRemoteAndSleep = State(initialValue: ctrlClickTogglesRemoteAndSleep)
        _remoteApprovalEnabled = State(initialValue: remoteApprovalEnabled)
        _notifyOnIdle = State(initialValue: notifyOnIdle)
        _usagePollingEnabled = State(initialValue: usagePollingEnabled)
        _autoCheckForUpdates = State(initialValue: autoCheckForUpdates)
        _updateCheckInterval = State(initialValue: updateCheckInterval)
        self.onSave = onSave
        self.onCheckNow = onCheckNow
        self.onFeedback = onFeedback
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
                .overlay(Color.white.opacity(0.06))
            contentArea
        }
        .frame(width: 600, height: 480)
        .background(SettingsColors.windowBg)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // App branding
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 2)

                Text("AFK Agent")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(appVersion)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 16)

            Divider()
                .overlay(Color.white.opacity(0.06))
                .padding(.horizontal, 12)

            // Navigation
            VStack(spacing: 2) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    SidebarButton(
                        title: tab.rawValue,
                        icon: tab.icon,
                        isSelected: selectedTab == tab
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedTab = tab
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)

            Spacer()

            // Save button
            if selectedTab != .about {
                VStack(spacing: 8) {
                    if showSaveConfirmation {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.system(size: 11))
                            Text("Saved")
                                .font(.system(size: 11))
                                .foregroundStyle(.green)
                        }
                        .transition(.opacity)
                    }

                    Button(action: save) {
                        Text("Save")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.accentColor)
                            )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .frame(width: 160)
        .background(SettingsColors.sidebarBg)
    }

    // MARK: - Content

    private var contentArea: some View {
        ZStack {
            SettingsStarfieldView()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch selectedTab {
                    case .general:
                        GeneralSettingsPage(
                            obeySettingsRules: $obeySettingsRules,
                            preventSleep: $preventSleep,
                            ctrlClickTogglesRemoteAndSleep: $ctrlClickTogglesRemoteAndSleep,
                            remoteApprovalEnabled: $remoteApprovalEnabled,
                            notifyOnIdle: $notifyOnIdle,
                            usagePollingEnabled: $usagePollingEnabled
                        )
                    case .updates:
                        UpdatesSettingsPage(
                            autoCheckForUpdates: $autoCheckForUpdates,
                            updateCheckInterval: $updateCheckInterval,
                            onCheckNow: onCheckNow
                        )
                    case .about:
                        AboutPage(onFeedback: onFeedback)
                    }
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func save() {
        let effectiveInterval = autoCheckForUpdates ? updateCheckInterval : 0
        onSave(
            SettingsValues(
                obeySettingsRules: obeySettingsRules,
                preventSleep: preventSleep,
                ctrlClickTogglesRemoteAndSleep: ctrlClickTogglesRemoteAndSleep,
                remoteApprovalEnabled: remoteApprovalEnabled,
                notifyOnIdle: notifyOnIdle,
                usagePollingEnabled: usagePollingEnabled,
                updateCheckInterval: effectiveInterval
            ))

        withAnimation(.easeIn(duration: 0.2)) { showSaveConfirmation = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.3)) { showSaveConfirmation = false }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }
}

// MARK: - General Settings Page

private struct GeneralSettingsPage: View {
    @Binding var obeySettingsRules: Bool
    @Binding var preventSleep: Bool
    @Binding var ctrlClickTogglesRemoteAndSleep: Bool
    @Binding var remoteApprovalEnabled: Bool
    @Binding var notifyOnIdle: Bool
    @Binding var usagePollingEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPageHeader(
                title: "General", subtitle: "Configure agent behavior and permissions")

            SettingsCard(title: "Permission", icon: "shield.lefthalf.filled", iconColor: .blue) {
                SettingsToggle(
                    title: "Obey settings.json rules",
                    subtitle: "Respect Claude Code's allow/deny lists",
                    icon: "doc.text",
                    isOn: $obeySettingsRules
                )
                CardDivider()
                SettingsToggle(
                    title: "Remote Approval",
                    subtitle: "Approve tool calls from your iPhone",
                    icon: "iphone.gen3",
                    isOn: $remoteApprovalEnabled
                )
            }

            SettingsCard(title: "Behavior", icon: "gearshape.fill", iconColor: .gray) {
                SettingsToggle(
                    title: "Prevent Sleep",
                    subtitle: "Keep Mac awake while agent is running",
                    icon: "bolt.fill",
                    isOn: $preventSleep
                )
                CardDivider()
                SettingsToggle(
                    title: "Idle Notifications",
                    subtitle: "Notify when Claude is waiting for input",
                    icon: "bell.badge.fill",
                    isOn: $notifyOnIdle
                )
                CardDivider()
                SettingsToggle(
                    title: "Ctrl+Click Combo",
                    subtitle: "Ctrl+Click toggles Remote + Sleep together",
                    icon: "keyboard",
                    isOn: $ctrlClickTogglesRemoteAndSleep
                )
            }

            SettingsCard(title: "Claude Usage", icon: "chart.bar.fill", iconColor: .purple) {
                SettingsToggle(
                    title: "Track Usage",
                    subtitle: "Poll Claude API usage and show in menu bar",
                    icon: "gauge.with.dots.needle.bottom.50percent",
                    isOn: $usagePollingEnabled
                )
            }
        }
    }
}

// MARK: - Updates Settings Page

private struct UpdatesSettingsPage: View {
    @Binding var autoCheckForUpdates: Bool
    @Binding var updateCheckInterval: TimeInterval
    let onCheckNow: () -> Void

    private let intervalOptions: [(String, TimeInterval)] = [
        ("1 hour", 3600),
        ("6 hours", 21600),
        ("12 hours", 43200),
        ("24 hours", 86400),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPageHeader(title: "Updates", subtitle: "Manage automatic update checking")

            SettingsCard(
                title: "Auto Updates", icon: "arrow.triangle.2.circlepath", iconColor: .green
            ) {
                SettingsToggle(
                    title: "Auto-check for updates",
                    subtitle: "Periodically check for new versions",
                    icon: "arrow.down.circle",
                    isOn: $autoCheckForUpdates
                )

                if autoCheckForUpdates {
                    CardDivider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Check interval")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)

                        Picker("", selection: $updateCheckInterval) {
                            ForEach(intervalOptions, id: \.1) { name, interval in
                                Text(name).tag(interval)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .padding(.top, 4)
                }
            }

            SettingsCard(title: "Manual", icon: "hand.tap.fill", iconColor: .orange) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check for Updates")
                            .font(.system(size: 13))
                        Text("Check right now for a newer version")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check Now") { onCheckNow() }
                        .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - About Page

private struct AboutPage: View {
    let onFeedback: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // App icon + name (starfield is already the content background)
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 4)

                Text("AFK Agent")
                    .font(.system(size: 20, weight: .bold))

                Text("by Ahmet Yusuf Birinci")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

            // Info card
            VStack(spacing: 10) {
                aboutInfoRow(icon: "info.circle", label: "Version", value: appVersion)
                aboutInfoRow(icon: "hammer", label: "Build", value: buildNumber)
                aboutInfoRow(
                    icon: "desktopcomputer", label: "Platform",
                    value: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(SettingsColors.cardBg.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(SettingsColors.cardBorder, lineWidth: 0.5)
            )

            // Description
            Text(
                "AFK Agent monitors your Claude Code sessions and relays events to the AFK iOS app, letting you manage coding sessions remotely."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .padding(.horizontal, 4)

            // Action buttons
            VStack(spacing: 8) {
                aboutLinkButton(icon: "star.fill", title: "Star AFK on GitHub", subtitle: "Support the project with a star", iconColor: .yellow) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/AFK-CLI/AFK")!)
                }
                aboutLinkButton(icon: "curlybraces", title: "GitHub Repository", subtitle: "github.com/AFK-CLI/AFK", iconColor: .white) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/AFK-CLI/AFK")!)
                }
                aboutLinkButton(icon: "exclamationmark.bubble", title: "Send Feedback", subtitle: "Report bugs or suggest features", iconColor: .orange) {
                    onFeedback()
                }
            }

            Spacer()

            Text("Built by Ahmet Yusuf Birinci")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    private func aboutInfoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    private func aboutLinkButton(icon: String, title: String, subtitle: String, iconColor: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(iconColor)
                    .frame(width: 18, alignment: .center)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(SettingsColors.cardBg.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(SettingsColors.cardBorder, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

// MARK: - Reusable Components

private struct SettingsColors {
    static let windowBg = Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0))
    static let sidebarBg = Color(nsColor: NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1.0))
    static let contentBg = Color(nsColor: NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0))
    static let cardBg = Color(nsColor: NSColor(red: 0.15, green: 0.15, blue: 0.17, alpha: 1.0))
    static let cardBorder = Color.white.opacity(0.08)
}

private struct SettingsPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()
                .overlay(SettingsColors.cardBorder)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(SettingsColors.cardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(SettingsColors.cardBorder, lineWidth: 0.5)
        )
    }
}

private struct CardDivider: View {
    var body: some View {
        Divider()
            .overlay(SettingsColors.cardBorder)
            .padding(.vertical, 8)
            .padding(.leading, 28)
    }
}

private struct SettingsToggle: View {
    let title: String
    let subtitle: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(isOn ? .primary : .tertiary)
                .frame(width: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

private struct SidebarButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 16, alignment: .center)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .white : .secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.8) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings Starfield (lightweight version)

private struct SettingsStarfieldView: View {
    private struct Star {
        let x, y, size: CGFloat
        let opacity: Double
    }

    private struct Meteor {
        let startX, startY, angle, trailLength, speed: CGFloat
        let cyclePeriod, offset: Double
    }

    private static let stars: [Star] = {
        (0..<30).map { _ in
            Star(
                x: .random(in: 0...1), y: .random(in: 0...1),
                size: .random(in: 0.8...2.0), opacity: .random(in: 0.2...0.6)
            )
        }
    }()

    private static let meteors: [Meteor] = {
        (0..<2).map { _ in
            Meteor(
                startX: .random(in: 0.05...0.95),
                startY: .random(in: 0.0...0.4),
                angle: .random(in: 0.4...1.0),
                trailLength: .random(in: 25...50),
                speed: .random(in: 200...400),
                cyclePeriod: .random(in: 6...14),
                offset: .random(in: 0...10)
            )
        }
    }()

    var body: some View {
        ZStack {
            // Dark gradient base
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.05, blue: 0.12),
                    Color(red: 0.08, green: 0.06, blue: 0.14),
                    Color(red: 0.04, green: 0.04, blue: 0.08),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Static stars
            Canvas { context, size in
                for star in Self.stars {
                    let rect = CGRect(
                        x: star.x * size.width - star.size / 2,
                        y: star.y * size.height - star.size / 2,
                        width: star.size, height: star.size
                    )
                    context.opacity = star.opacity
                    context.fill(Circle().path(in: rect), with: .color(.white))
                }
            }

            // Shooting stars
            TimelineView(.animation(minimumInterval: 1.0 / 24)) { timeline in
                Canvas { context, size in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    for m in Self.meteors {
                        let cycleTime = (now + m.offset)
                            .truncatingRemainder(dividingBy: m.cyclePeriod)
                        let travelDuration = Double(m.trailLength * 2.5 / m.speed)
                        guard cycleTime < travelDuration else { continue }

                        let progress = CGFloat(cycleTime / travelDuration)
                        let headDist = progress * m.trailLength * 2.5
                        let headX = m.startX * size.width + cos(m.angle) * headDist
                        let headY = m.startY * size.height + sin(m.angle) * headDist

                        let visibleTrail = min(m.trailLength, headDist)
                        let tailX = headX - cos(m.angle) * visibleTrail
                        let tailY = headY - sin(m.angle) * visibleTrail

                        let fade: Double =
                            if progress < 0.1 {
                                Double(progress / 0.1)
                            } else if progress > 0.6 {
                                Double((1 - progress) / 0.4)
                            } else { 1.0 }
                        guard fade > 0.01 else { continue }

                        var trail = Path()
                        trail.move(to: CGPoint(x: tailX, y: tailY))
                        trail.addLine(to: CGPoint(x: headX, y: headY))
                        context.opacity = fade * 0.6
                        context.stroke(
                            trail,
                            with: .linearGradient(
                                Gradient(colors: [.clear, .white]),
                                startPoint: CGPoint(x: tailX, y: tailY),
                                endPoint: CGPoint(x: headX, y: headY)
                            ), style: StrokeStyle(lineWidth: 1.0, lineCap: .round))

                        context.opacity = fade * 0.8
                        context.fill(
                            Circle().path(
                                in: CGRect(
                                    x: headX - 1, y: headY - 1, width: 2, height: 2
                                )), with: .color(.white))
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}
