import SwiftUI

struct NotificationSettingsView: View {
    let apiClient: APIClient

    @State private var permissionRequests = true
    @State private var askUser = true
    @State private var sessionErrors = true
    @State private var sessionCompletions = false
    @State private var sessionActivity = false
    @State private var quietHoursEnabled = false
    @State private var quietHoursStart = Date.fromTimeString("22:00")
    @State private var quietHoursEnd = Date.fromTimeString("08:00")
    @State private var prefsLoaded = false

    var body: some View {
        List {
            Section("Alerts") {
                Toggle("Permission Requests", isOn: $permissionRequests)
                Toggle("Questions", isOn: $askUser)
                Toggle("Session Errors", isOn: $sessionErrors)
            }

            Section {
                Toggle("Session Completions", isOn: $sessionCompletions)
                Toggle("Session Activity", isOn: $sessionActivity)
            } header: {
                Text("Activity")
            } footer: {
                Text("Session Activity sends notifications for tool completions during active sessions. Can be noisy for long-running tasks.")
            }

            Section("Schedule") {
                Toggle("Quiet Hours", isOn: $quietHoursEnabled)
                if quietHoursEnabled {
                    DatePicker("Start", selection: $quietHoursStart, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: $quietHoursEnd, displayedComponents: .hourAndMinute)
                }
            }
        }
        .navigationTitle("Notifications")
        .onChange(of: permissionRequests) { _, _ in savePrefs() }
        .onChange(of: askUser) { _, _ in savePrefs() }
        .onChange(of: sessionErrors) { _, _ in savePrefs() }
        .onChange(of: sessionCompletions) { _, _ in savePrefs() }
        .onChange(of: sessionActivity) { _, _ in savePrefs() }
        .onChange(of: quietHoursEnabled) { _, _ in savePrefs() }
        .onChange(of: quietHoursStart) { _, _ in savePrefs() }
        .onChange(of: quietHoursEnd) { _, _ in savePrefs() }
        .task {
            await loadPrefs()
        }
    }

    private func loadPrefs() async {
        do {
            let prefs = try await apiClient.getNotificationPreferences()
            permissionRequests = prefs.permissionRequests
            askUser = prefs.askUser
            sessionErrors = prefs.sessionErrors
            sessionCompletions = prefs.sessionCompletions
            sessionActivity = prefs.sessionActivity
            quietHoursEnabled = prefs.quietHoursEnabled
            quietHoursStart = Date.fromTimeString(prefs.quietHoursStart ?? "22:00")
            quietHoursEnd = Date.fromTimeString(prefs.quietHoursEnd ?? "08:00")
            prefsLoaded = true
        } catch {
            print("Failed to load notification preferences: \(error)")
            prefsLoaded = true
        }
    }

    private func savePrefs() {
        guard prefsLoaded else { return }
        let prefs = NotificationPreferences(
            permissionRequests: permissionRequests,
            sessionErrors: sessionErrors,
            sessionCompletions: sessionCompletions,
            askUser: askUser,
            sessionActivity: sessionActivity,
            quietHoursStart: quietHoursEnabled ? quietHoursStart.toTimeString() : nil,
            quietHoursEnd: quietHoursEnabled ? quietHoursEnd.toTimeString() : nil
        )
        Task {
            do {
                try await apiClient.updateNotificationPreferences(prefs)
            } catch {
                print("Failed to save notification preferences: \(error)")
            }
        }
    }
}

private extension Date {
    static func fromTimeString(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.date(from: string) ?? Date()
    }

    func toTimeString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: self)
    }
}
