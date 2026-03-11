import SwiftUI

struct CommandDetailView: View {
    let command: InventoryCommand
    let sourceDevice: Device
    let apiClient: APIClient
    var e2eeService: E2EEService?
    var tier: String = "free"

    @State private var devices: [Device] = []
    @State private var showDevicePicker = false
    @State private var sendResult: SendResult?

    private var myDeviceId: String? {
        BuildEnvironment.userDefaults.string(forKey: "afk_ios_device_id")
    }

    private var canShare: Bool {
        tier == "pro" || tier == "contributor"
    }

    enum SendResult: Equatable {
        case success(String)
        case error(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Text("/\(command.name)")
                        .font(.title2.monospaced().bold())
                    Spacer()
                    Text(command.scope == "global" ? "global" : projectName(command.scope))
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.blue.opacity(0.15), in: .capsule)
                        .foregroundStyle(.blue)
                }

                if !command.description.isEmpty {
                    Text(command.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Markdown content
                MarkdownText(text: command.content)
            }
            .padding()
        }
        .navigationTitle("/\(command.name)")
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if canShare {
                    Button {
                        Task { await loadOtherDevices() }
                        showDevicePicker = true
                    } label: {
                        Label("Send to Mac", systemImage: "paperplane")
                    }
                    .disabled(command.content.isEmpty)
                } else {
                    Label("Pro", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .sheet(isPresented: $showDevicePicker) {
            DevicePickerSheet(
                devices: devices,
                onSelect: { target in
                    showDevicePicker = false
                    Task { await sendToDevice(target) }
                }
            )
        }
        .overlay {
            if let result = sendResult {
                sendResultBanner(result)
            }
        }
    }

    private func loadOtherDevices() async {
        do {
            let allDevices = try await apiClient.listDevices()
            devices = allDevices.filter { Self.isMacAgent($0) }
        } catch {
            devices = []
        }
    }

    private func sendToDevice(_ target: Device) async {
        do {
            // Encrypt the skill payload using target device's KA public key
            guard let targetKAKey = target.keyAgreementPublicKey, !targetKAKey.isEmpty,
                  let e2ee = e2eeService,
                  let senderDeviceId = myDeviceId else {
                sendResult = .error("E2EE not available for this device")
                try? await Task.sleep(for: .seconds(3))
                sendResult = nil
                return
            }

            // Build plaintext JSON payload
            let skillPayload: [String: String] = [
                "name": command.name,
                "content": command.content,
                "sourceDeviceName": sourceDevice.name
            ]
            let jsonData = try JSONSerialization.data(withJSONObject: skillPayload)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                sendResult = .error("Failed to encode skill")
                try? await Task.sleep(for: .seconds(3))
                sendResult = nil
                return
            }

            // Derive key using target device ID as HKDF salt (matches agent's key derivation)
            let key = try e2ee.sessionKey(peerPublicKeyBase64: targetKAKey, sessionId: target.id)
            let encrypted = try E2EEService.encrypt(jsonString, key: key)

            _ = try await apiClient.installSkill(
                targetDeviceId: target.id,
                senderDeviceId: senderDeviceId,
                encryptedPayload: encrypted
            )
            sendResult = .success(target.name)
        } catch {
            sendResult = .error(error.localizedDescription)
        }

        // Auto-dismiss banner after 3 seconds
        try? await Task.sleep(for: .seconds(3))
        sendResult = nil
    }

    @ViewBuilder
    private func sendResultBanner(_ result: SendResult) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                switch result {
                case .success(let deviceName):
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Sent to \(deviceName)")
                case .error(let message):
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .lineLimit(2)
                }
            }
            .font(.subheadline.bold())
            .padding()
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
            .padding()
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring, value: sendResult)
    }

    /// Returns true if the device is a Mac agent (not an iOS/iPadOS device).
    static func isMacAgent(_ device: Device) -> Bool {
        let info = (device.systemInfo ?? "").lowercased()
        if info.hasPrefix("ios") || info.hasPrefix("ipados") { return false }
        return true
    }

    private func projectName(_ path: String) -> String {
        path.components(separatedBy: "/").last ?? path
    }
}

// MARK: - Device Picker Sheet

struct DevicePickerSheet: View {
    let devices: [Device]
    let onSelect: (Device) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if devices.isEmpty {
                    ContentUnavailableView(
                        "No Macs Available",
                        systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                        description: Text("No other Mac agents are available to receive this command. The command will be delivered when the Mac comes online.")
                    )
                } else {
                    ForEach(devices) { (device: Device) in
                        Button {
                            onSelect(device)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: DeviceListView.sfSymbol(for: device))
                                    .font(.title2)
                                    .foregroundStyle(device.isOnline ? .green : .secondary)
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .font(.body.bold())
                                    if let systemInfo = device.systemInfo, !systemInfo.isEmpty {
                                        Text(systemInfo)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                if device.isOnline {
                                    Image(systemName: "paperplane.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.tint)
                                } else {
                                    Text("Queued")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            .navigationTitle("Send to Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
