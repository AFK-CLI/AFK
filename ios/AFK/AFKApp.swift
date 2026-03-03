import SwiftUI
import StoreKit
import UserNotifications
import CryptoKit
import OSLog

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var onDeviceToken: ((Data) -> Void)?
    var onNotificationTap: ((String) -> Void)?  // sessionId
    var onPermissionAction: ((String, String) -> Void)?  // (nonce, action)
    var onPermissionFromPush: ((PermissionRequest) -> Void)?  // reconstruct from push payload

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        registerNotificationCategories()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        onDeviceToken?(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppLogger.push.error("Failed to register for push: \(error, privacy: .public)")
    }

    // Show banner when app is in foreground for permission requests, questions, and errors
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let category = notification.request.content.categoryIdentifier
        if category == "permission_request" || category == "ask_user_question" || category == "session_error" {
            return [.banner, .sound]
        }
        return [.banner]
    }

    // Handle notification tap and action buttons
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo

        switch response.actionIdentifier {
        case "approve_permission":
            if let nonce = userInfo["nonce"] as? String {
                onPermissionAction?(nonce, "allow")
            }
        case "deny_permission":
            if let nonce = userInfo["nonce"] as? String {
                onPermissionAction?(nonce, "deny")
            }
        case "open_session":
            if let sessionId = userInfo["sessionId"] as? String {
                onNotificationTap?(sessionId)
            }
        default:
            // Regular tap — navigate to session and reconstruct permission request
            if let sessionId = userInfo["sessionId"] as? String {
                // Reconstruct PermissionRequest from push payload so overlay shows immediately
                if let nonce = userInfo["nonce"] as? String,
                   let toolName = userInfo["toolName"] as? String,
                   let expiresAtStr = userInfo["expiresAt"] as? String,
                   let expiresAt = Int64(expiresAtStr),
                   let deviceId = userInfo["deviceId"] as? String,
                   let toolUseId = userInfo["toolUseId"] as? String {
                    var toolInput: [String: String] = [:]
                    if let toolInputStr = userInfo["toolInput"] as? String,
                       let data = toolInputStr.data(using: .utf8),
                       let parsed = try? JSONDecoder().decode([String: String].self, from: data) {
                        toolInput = parsed
                    }
                    let challenge = userInfo["challenge"] as? String
                    let request = PermissionRequest(
                        sessionId: sessionId,
                        toolName: toolName,
                        toolInput: toolInput,
                        toolUseId: toolUseId,
                        nonce: nonce,
                        expiresAt: expiresAt,
                        deviceId: deviceId,
                        challenge: challenge
                    )
                    if !request.isExpired {
                        onPermissionFromPush?(request)
                    }
                }
                onNotificationTap?(sessionId)
            }
        }
    }

    private func registerNotificationCategories() {
        let approveAction = UNNotificationAction(
            identifier: "approve_permission",
            title: "Approve",
            options: [.authenticationRequired]
        )
        let denyAction = UNNotificationAction(
            identifier: "deny_permission",
            title: "Deny",
            options: [.destructive]
        )
        let permissionCategory = UNNotificationCategory(
            identifier: "permission_request",
            actions: [approveAction, denyAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        // AskUserQuestion: tap to open (no approve/deny buttons)
        let questionCategory = UNNotificationCategory(
            identifier: "ask_user_question",
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        // Session error: Open Session action button
        let openSessionAction = UNNotificationAction(
            identifier: "open_session",
            title: "Open Session",
            options: [.foreground]
        )
        let errorCategory = UNNotificationCategory(
            identifier: "session_error",
            actions: [openSessionAction],
            intentIdentifiers: [],
            options: []
        )
        // Session completed: tap to open
        let completedCategory = UNNotificationCategory(
            identifier: "session_completed",
            actions: [openSessionAction],
            intentIdentifiers: [],
            options: []
        )
        // Aggregated session activity: tap to open
        let activityCategory = UNNotificationCategory(
            identifier: "session_activity",
            actions: [openSessionAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([
            permissionCategory, questionCategory, errorCategory, completedCategory, activityCategory
        ])
    }
}

@main
struct AFKApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var authService: AuthService
    @State private var apiClient: APIClient
    @State private var wsService = WebSocketService()
    @State private var commandStore = CommandStore()
    @State private var sessionStore: SessionStore
    @State private var liveActivityManager = LiveActivityManager()
    @State private var subscriptionManager = SubscriptionManager()
    @State private var deepLinkSessionId: String?
    @State private var localStore: LocalStore
    @State private var syncService: SyncService
    @State private var backgroundTaskManager: BackgroundTaskManager
    @State private var taskStore: TaskStore
    @State private var todoStore: TodoStore
    @State private var logUploader = LogUploader.shared

    init() {
        let auth = AuthService()
        let client = APIClient(authService: auth)
        let ws = WebSocketService()
        let store = LocalStore.shared
        let sync = SyncService(apiClient: client, localStore: store)
        let sessionStore = SessionStore(apiClient: client, wsService: ws, localStore: store, syncService: sync)
        let bgManager = BackgroundTaskManager(syncService: sync)
        let taskStore = TaskStore(apiClient: client, localStore: store)
        let todoStore = TodoStore(apiClient: client)

        // Clear local cache on sign-out so a different account starts fresh.
        auth.onSignOut = { [weak sessionStore, weak taskStore, weak todoStore] in
            store.clearAll()
            sessionStore?.sessions = []
            sessionStore?.events = [:]
            taskStore?.tasks = []
            todoStore?.todos = []
        }

        _authService = State(initialValue: auth)
        _apiClient = State(initialValue: client)
        _wsService = State(initialValue: ws)
        _sessionStore = State(initialValue: sessionStore)
        _localStore = State(initialValue: store)
        _syncService = State(initialValue: sync)
        _backgroundTaskManager = State(initialValue: bgManager)
        _taskStore = State(initialValue: taskStore)
        _todoStore = State(initialValue: todoStore)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                authService: authService,
                apiClient: apiClient,
                wsService: wsService,
                sessionStore: sessionStore,
                commandStore: commandStore,
                deepLinkSessionId: $deepLinkSessionId,
                subscriptionManager: subscriptionManager,
                taskStore: taskStore,
                todoStore: todoStore,
                logUploader: logUploader
            )
            #if DEBUG
            .overlay(alignment: .topLeading) {
                Text("DEV")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.red, in: Capsule())
                    .padding(.leading, 70)
                    .padding(.top, 2)
                    .allowsHitTesting(false)
            }
            #endif
            .task {
                await authService.restoreSession()
            }
            .onChange(of: authService.isAuthenticated) { _, isAuth in
                if isAuth, let token = authService.accessToken {
                    // Enroll iOS device and cache E2EE keys BEFORE connecting WS,
                    // so device KA keys are available when WS events trigger decryption.
                    Task {
                        await enrollIOSDeviceIfNeeded()

                        // Sync subscription state
                        await subscriptionManager.updatePurchasedProducts()
                        if let transaction = await subscriptionManager.latestTransaction() {
                            let expiresAt = transaction.expirationDate.map { ISO8601DateFormatter().string(from: $0) }
                            try? await apiClient.syncSubscriptionReceipt(
                                originalTransactionId: String(transaction.originalID),
                                productId: transaction.productID,
                                expiresAt: expiresAt
                            )
                        }

                        wsService.connect(token: token, apiClient: apiClient, deviceId: sessionStore.myDeviceId)
                    }
                } else {
                    wsService.disconnect()
                }
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                handleScenePhaseChange(from: oldPhase, to: newPhase)
            }
            .onAppear {
                // Wire live activity manager
                sessionStore.liveActivityManager = liveActivityManager

                // Observe push-to-start token and activity updates for remote-started Live Activities.
                liveActivityManager.observePushToStartToken(apiClient: apiClient)
                liveActivityManager.observeActivityUpdates(apiClient: apiClient)

                // Setup notification service and request permission
                let notificationService = NotificationService(apiClient: apiClient)
                appDelegate.onDeviceToken = { token in
                    Task { await notificationService.registerToken(token) }
                }
                appDelegate.onNotificationTap = { sessionId in
                    deepLinkSessionId = sessionId
                }
                appDelegate.onPermissionAction = { [weak sessionStore] nonce, action in
                    Task {
                        await sessionStore?.sendPermissionResponse(nonce: nonce, action: action)
                    }
                }
                appDelegate.onPermissionFromPush = { [weak sessionStore] request in
                    sessionStore?.pendingPermissions[request.nonce] = request
                }
                Task { await notificationService.requestPermission() }

                wsService.onCommandChunk = { [weak commandStore] sessionId, text in
                    commandStore?.appendChunk(sessionId: sessionId, text: text)
                }
                wsService.onCommandDone = { [weak commandStore] sessionId, durationMs, costUsd, newSessionId in
                    commandStore?.completeCommand(sessionId: sessionId, durationMs: durationMs, costUsd: costUsd, newSessionId: newSessionId)
                    // Only deep-link for genuinely new sessions (new chat where sessionId is empty)
                    // or when the session actually changed (not just the same ID echoed back)
                    if let newSessionId, sessionId.isEmpty || newSessionId != sessionId {
                        deepLinkSessionId = newSessionId
                    }
                }
                wsService.onCommandFailed = { [weak commandStore] sessionId, error in
                    commandStore?.failCommand(sessionId: sessionId, error: error)
                }
                wsService.onCommandRunning = { _ in
                    // Command is running on agent - UI already shows active state
                }
                wsService.onCommandCancelled = { [weak commandStore] sessionId in
                    commandStore?.cancelCommand(sessionId: sessionId)
                }
                wsService.onTaskUpdate = { [weak taskStore] task in
                    taskStore?.handleTaskUpdate(task)
                }
                wsService.onTodoUpdate = { [weak todoStore] projectTodos in
                    todoStore?.handleTodoUpdate(projectTodos)
                }

                // Register background tasks
                backgroundTaskManager.registerTasks { sessions in
                    sessionStore.sessions = sessions
                }
            }
        }
    }

    private static let iosDeviceIdKey = "afk_ios_device_id"
    private static let lastRegisteredKAFingerprintKey = "afk_last_registered_ka_fingerprint"

    private func enrollIOSDeviceIfNeeded() async {
        let keyPair = DeviceKeyPair.loadOrCreate()
        let myDeviceId = BuildEnvironment.userDefaults.string(forKey: Self.iosDeviceIdKey)
        let currentFingerprint = E2EEService.fingerprint(of: keyPair.publicKeyBase64)
        AppLogger.app.info("Own KA key fingerprint: \(currentFingerprint, privacy: .public)")

        // Enroll if we haven't yet
        if myDeviceId == nil {
            do {
                let device = try await apiClient.enrollDevice(
                    name: UIDevice.current.name,
                    publicKey: keyPair.publicKeyBase64,
                    systemInfo: "iOS \(UIDevice.current.systemVersion)",
                    keyAgreementPublicKey: keyPair.publicKeyBase64,
                    capabilities: ["e2ee_v2"]
                )
                BuildEnvironment.userDefaults.set(device.id, forKey: Self.iosDeviceIdKey)
                BuildEnvironment.userDefaults.set(currentFingerprint, forKey: Self.lastRegisteredKAFingerprintKey)
                sessionStore.myDeviceId = device.id
                logUploader.configure(apiClient: apiClient, deviceId: device.id)
                AppLogger.app.info("iOS device enrolled: \(device.id.prefix(8), privacy: .public)")
            } catch {
                AppLogger.app.error("iOS device enrollment failed: \(error, privacy: .public)")
            }
        } else {
            sessionStore.myDeviceId = myDeviceId
            logUploader.configure(apiClient: apiClient, deviceId: myDeviceId!)
            // Already enrolled — only re-register KA key if it changed
            let lastFingerprint = BuildEnvironment.userDefaults.string(forKey: Self.lastRegisteredKAFingerprintKey)
            if lastFingerprint != currentFingerprint {
                AppLogger.app.warning("KA key fingerprint changed (\(lastFingerprint ?? "nil", privacy: .public) -> \(currentFingerprint, privacy: .public)) — re-registering")
                AppLogger.app.warning("This means the Keychain key was lost. Historical E2EE content may be unreadable.")

                // Reinitialize SessionStore's E2EE service with the new key
                sessionStore.reinitializeE2EE()

                do {
                    try await apiClient.registerKeyAgreement(deviceId: myDeviceId!, publicKey: keyPair.publicKeyBase64)
                    BuildEnvironment.userDefaults.set(currentFingerprint, forKey: Self.lastRegisteredKAFingerprintKey)
                    AppLogger.app.info("KA key re-registered (fingerprint: \(currentFingerprint, privacy: .public))")
                } catch {
                    AppLogger.app.error("KA key registration update failed: \(error, privacy: .public)")
                }
            } else {
                AppLogger.app.debug("KA key unchanged (\(currentFingerprint, privacy: .public)), skipping registration")
            }
        }

        // List all devices and cache agent device KA keys for E2EE decryption
        do {
            let storedId = BuildEnvironment.userDefaults.string(forKey: Self.iosDeviceIdKey)
            let devices = try await apiClient.listDevices()
            var ownDevice: Device?
            for device in devices {
                if device.id == storedId {
                    ownDevice = device
                    sessionStore.myKeyVersion = device.keyVersion
                } else if let kaKey = device.keyAgreementPublicKey, !kaKey.isEmpty {
                    sessionStore.cacheDeviceKey(deviceId: device.id, publicKey: kaKey)
                }
            }
            AppLogger.app.info("Cached \(sessionStore.deviceKAKeys.count, privacy: .public) device KA keys for E2EE")

            if let storedId {
                if ownDevice == nil {
                    // Device ID in UserDefaults doesn't exist on backend (DB rebuilt).
                    // Re-enroll to recreate the device record with KA key.
                    AppLogger.app.warning("Device \(storedId.prefix(8), privacy: .public) not found on backend — re-enrolling")
                    let device = try await apiClient.enrollDevice(
                        name: UIDevice.current.name,
                        publicKey: keyPair.publicKeyBase64,
                        systemInfo: "iOS \(UIDevice.current.systemVersion)",
                        keyAgreementPublicKey: keyPair.publicKeyBase64,
                        capabilities: ["e2ee_v2"],
                        deviceId: storedId
                    )
                    BuildEnvironment.userDefaults.set(device.id, forKey: Self.iosDeviceIdKey)
                    BuildEnvironment.userDefaults.set(currentFingerprint, forKey: Self.lastRegisteredKAFingerprintKey)
                    sessionStore.myDeviceId = device.id
                    AppLogger.app.info("Re-enrolled as \(device.id.prefix(8), privacy: .public) with KA key")
                } else if ownDevice?.keyAgreementPublicKey == nil || ownDevice?.keyAgreementPublicKey?.isEmpty == true {
                    // Device exists but backend lost our KA key.
                    AppLogger.app.warning("Backend missing our KA key — re-registering")
                    try await apiClient.registerKeyAgreement(deviceId: storedId, publicKey: keyPair.publicKeyBase64)
                    BuildEnvironment.userDefaults.set(currentFingerprint, forKey: Self.lastRegisteredKAFingerprintKey)
                    AppLogger.app.info("KA key re-registered (fingerprint: \(currentFingerprint, privacy: .public))")
                } else if let backendKey = ownDevice?.keyAgreementPublicKey, backendKey != keyPair.publicKeyBase64 {
                    // Backend has a stale key — previous registration likely failed
                    let backendFP = E2EEService.fingerprint(of: backendKey)
                    AppLogger.app.warning("Backend KA key mismatch: local=\(currentFingerprint, privacy: .public) backend=\(backendFP, privacy: .public) — re-registering")
                    try await apiClient.registerKeyAgreement(deviceId: storedId, publicKey: keyPair.publicKeyBase64)
                    BuildEnvironment.userDefaults.set(currentFingerprint, forKey: Self.lastRegisteredKAFingerprintKey)
                    AppLogger.app.info("KA key re-registered after mismatch (fingerprint: \(currentFingerprint, privacy: .public))")
                }
            }
        } catch {
            AppLogger.app.error("Failed to list devices for E2EE: \(error, privacy: .public)")
        }
    }

    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            AppLogger.app.info("Entering background")
            BiometricService.resetSession()
            backgroundTaskManager.scheduleRefresh()
            wsService.disconnect()
        case .active:
            if oldPhase == .background {
                AppLogger.app.info("Returning to foreground")
                if let token = authService.accessToken {
                    wsService.connect(token: token, apiClient: apiClient, deviceId: sessionStore.myDeviceId)
                }
                Task { await sessionStore.loadSessions() }
                Task { await taskStore.loadTasks() }
                Task { await todoStore.loadTodos() }
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }
}
