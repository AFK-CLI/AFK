import SwiftUI

struct DeviceListView: View {
    let apiClient: APIClient
    @State private var devices: [Device] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            List {
                if devices.isEmpty && !isLoading {
                    ContentUnavailableView(
                        "No Devices",
                        systemImage: "laptopcomputer",
                        description: Text("Enroll a Mac by running the AFK Agent")
                    )
                } else {
                    ForEach(devices) { device in
                        HStack(spacing: 12) {
                            Image(systemName: Self.sfSymbol(for: device))
                                .font(.title2)
                                .foregroundStyle(device.isOnline ? .green : .secondary)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name)
                                    .font(.body.bold())
                                if let systemInfo = device.systemInfo, !systemInfo.isEmpty {
                                    Text(systemInfo)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            Text(device.isOnline ? "Online" : "Offline")
                                .font(.caption)
                                .foregroundStyle(device.isOnline ? .green : .secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    (device.isOnline ? Color.green : Color.secondary).opacity(0.15),
                                    in: .capsule
                                )
                        }
                    }
                }
            }
            .navigationTitle("Devices")
            .refreshable { await loadDevices() }
            .task { await loadDevices() }
        }
    }

    private func loadDevices() async {
        if ScreenshotMode.isActive {
            devices = ScreenshotData.devices
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            devices = try await apiClient.listDevices()
        } catch {
            print("Failed to load devices: \(error)")
        }
    }

    /// Map device name and system info to the appropriate SF Symbol.
    private static func sfSymbol(for device: Device) -> String {
        let name = device.name.lowercased()
        let info = (device.systemInfo ?? "").lowercased()

        // iOS devices
        if info.hasPrefix("ios") || name.contains("iphone") {
            return "iphone"
        }
        if info.hasPrefix("ipados") || name.contains("ipad") {
            return "ipad"
        }

        // Check both device name and systemInfo (which may contain hw.model like "macbookpro18,1")
        let hints = name + " " + info

        if hints.contains("macbook") {
            return "laptopcomputer"
        }
        if hints.contains("macmini") || hints.contains("mac mini") {
            return "macmini"
        }
        if hints.contains("macstudio") || hints.contains("mac studio") {
            return "macstudio"
        }
        if hints.contains("macpro") || hints.contains("mac pro") {
            return "macpro.gen3"
        }
        if hints.contains("imac") {
            return "desktopcomputer"
        }

        return "desktopcomputer"
    }
}
