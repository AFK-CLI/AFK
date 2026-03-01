import Foundation
import UserNotifications
import UIKit

final class NotificationService {
    private let apiClient: APIClient

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    func requestPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
            return granted
        } catch {
            print("Notification permission error: \(error)")
            return false
        }
    }

    func registerToken(_ deviceToken: Data) async {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        do {
            try await apiClient.registerPushToken(deviceToken: tokenString)
        } catch {
            print("Failed to register push token: \(error)")
        }
    }

    func unregisterToken(_ deviceToken: String) async {
        do {
            try await apiClient.unregisterPushToken(deviceToken: deviceToken)
        } catch {
            print("Failed to unregister push token: \(error)")
        }
    }
}
