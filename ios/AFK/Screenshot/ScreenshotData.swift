import Foundation

// swiftlint:disable file_length type_body_length

/// Mock data for screenshot mode. Provides realistic-looking sessions, conversations,
/// tasks, todos, devices, and usage for App Store and marketing screenshots.
enum ScreenshotData {

    // MARK: - IDs

    private static let userId = "usr_ss_001"
    private static let macDeviceId = "dev_mac_001"
    private static let miniDeviceId = "dev_mini_002"
    private static let afkProjectId = "proj_afk"
    private static let vaporProjectId = "proj_vapor"
    private static let markdownProjectId = "proj_md"

    private static let runningSessionId = "sess_running_001"
    private static let permissionSessionId = "sess_perm_002"
    private static let idleSessionId = "sess_idle_003"
    private static let completedSessionId = "sess_done_004"

    // MARK: - User

    static let user = User(
        id: userId,
        appleUserId: "apple_ss",
        email: "alex@example.com",
        displayName: "Alex Chen",
        createdAt: "2025-01-15T10:00:00Z",
        updatedAt: "2026-03-07T09:00:00Z",
        subscriptionTier: "pro",
        subscriptionExpiresAt: nil
    )

    // MARK: - Devices

    static let devices: [Device] = [
        Device(
            id: macDeviceId, userId: userId, name: "MacBook Pro",
            publicKey: "mock_key_1",
            systemInfo: "macOS 15.3 (MacBookPro18,1)",
            enrolledAt: "2025-06-10T14:00:00Z",
            lastSeenAt: "2026-03-07T09:30:00Z",
            isOnline: true, isRevoked: false,
            privacyMode: "encrypted",
            keyAgreementPublicKey: nil, keyVersion: 1,
            capabilities: ["e2ee_v2"]
        ),
        Device(
            id: miniDeviceId, userId: userId, name: "Mac Mini",
            publicKey: "mock_key_2",
            systemInfo: "macOS 15.3 (Macmini9,1)",
            enrolledAt: "2025-08-22T10:00:00Z",
            lastSeenAt: "2026-03-06T18:00:00Z",
            isOnline: false, isRevoked: false,
            privacyMode: "telemetry_only",
            keyAgreementPublicKey: nil, keyVersion: 1,
            capabilities: nil
        ),
    ]

    // MARK: - Usage

    static let usage = ClaudeUsage(
        deviceId: macDeviceId,
        sessionPercentage: 34,
        sessionResetTime: Date().addingTimeInterval(2.5 * 3600),
        weeklyPercentage: 52,
        weeklyResetTime: Date().addingTimeInterval(3 * 86400),
        opusWeeklyPercentage: 28,
        sonnetWeeklyPercentage: 24,
        sonnetWeeklyResetTime: Date().addingTimeInterval(3 * 86400),
        subscriptionType: "claude_max_5x",
        lastUpdated: Date(),
        deviceName: "MacBook Pro"
    )

    // MARK: - Sessions

    static let sessions: [Session] = [
        Session(
            id: runningSessionId, deviceId: macDeviceId, userId: userId,
            projectPath: "/Users/alex/Projects/AFK",
            gitBranch: "feature/screenshot-mode",
            cwd: "/Users/alex/Projects/AFK",
            status: .running,
            startedAt: Date().addingTimeInterval(-1800),
            updatedAt: Date().addingTimeInterval(-60),
            tokensIn: 12_450, tokensOut: 8_320, turnCount: 3,
            deviceName: "MacBook Pro", projectId: afkProjectId,
            description: "Adding screenshot mode for App Store images",
            costUsd: 0.28, lastModel: "claude-sonnet-4-6"
        ),
        Session(
            id: permissionSessionId, deviceId: macDeviceId, userId: userId,
            projectPath: "/Users/alex/Projects/vapor-api",
            gitBranch: "main",
            cwd: "/Users/alex/Projects/vapor-api",
            status: .waitingPermission,
            startedAt: Date().addingTimeInterval(-3600),
            updatedAt: Date().addingTimeInterval(-120),
            tokensIn: 25_800, tokensOut: 18_400, turnCount: 7,
            deviceName: "MacBook Pro", projectId: vaporProjectId,
            description: "Refactoring database middleware",
            costUsd: 0.62, lastModel: "claude-opus-4-6"
        ),
        Session(
            id: idleSessionId, deviceId: miniDeviceId, userId: userId,
            projectPath: "/Users/alex/Projects/swift-markdown",
            gitBranch: "fix/parser-edge-cases",
            cwd: "/Users/alex/Projects/swift-markdown",
            status: .idle,
            startedAt: Date().addingTimeInterval(-7200),
            updatedAt: Date().addingTimeInterval(-3600),
            tokensIn: 8_900, tokensOut: 5_100, turnCount: 4,
            deviceName: "Mac Mini", projectId: markdownProjectId,
            description: "Fixing nested blockquote parsing",
            costUsd: 0.19, lastModel: "claude-sonnet-4-6"
        ),
        Session(
            id: completedSessionId, deviceId: macDeviceId, userId: userId,
            projectPath: "/Users/alex/Projects/AFK",
            gitBranch: "main",
            cwd: "/Users/alex/Projects/AFK",
            status: .completed,
            startedAt: Date().addingTimeInterval(-14400),
            updatedAt: Date().addingTimeInterval(-10800),
            tokensIn: 42_000, tokensOut: 31_500, turnCount: 12,
            deviceName: "MacBook Pro", projectId: afkProjectId,
            description: "Implementing push notification deep linking",
            costUsd: 1.05, lastModel: "claude-opus-4-6"
        ),
    ]

    // MARK: - Events

    static let eventsBySession: [String: [SessionEvent]] = [
        runningSessionId: buildRunningSessionEvents(),
        permissionSessionId: buildPermissionSessionEvents(),
    ]

    // MARK: - Tasks

    static let tasks: [AFKTask] = [
        AFKTask(
            id: "task_001", sessionId: runningSessionId, projectId: afkProjectId,
            source: .claudeCode,
            subject: "Add screenshot mode with mock data",
            description: "Create a dedicated Xcode scheme that populates the app with realistic dummy data for taking App Store screenshots",
            status: .inProgress, activeForm: "Adding screenshot mode",
            createdAt: Date().addingTimeInterval(-1800), projectName: "AFK"
        ),
        AFKTask(
            id: "task_002", projectId: afkProjectId,
            source: .user,
            subject: "Write unit tests for E2EE key rotation",
            description: "Cover edge cases: simultaneous rotation, offline device reconnect, historical key fallback",
            status: .pending,
            createdAt: Date().addingTimeInterval(-86400), projectName: "AFK"
        ),
        AFKTask(
            id: "task_003", sessionId: permissionSessionId, projectId: vaporProjectId,
            source: .claudeCode,
            subject: "Refactor database middleware to use connection pooling",
            description: "Replace per-request connections with a shared pool, add health checks",
            status: .inProgress, activeForm: "Refactoring database middleware",
            createdAt: Date().addingTimeInterval(-3600), projectName: "vapor-api"
        ),
        AFKTask(
            id: "task_004", projectId: vaporProjectId,
            source: .claudeCode,
            subject: "Add rate limiting to REST endpoints",
            description: "Implement token bucket algorithm with Redis backing store",
            status: .completed,
            createdAt: Date().addingTimeInterval(-172800), updatedAt: Date().addingTimeInterval(-86400),
            projectName: "vapor-api"
        ),
    ]

    // MARK: - Todos

    static let todos: [ProjectTodos] = [
        ProjectTodos(
            projectId: afkProjectId,
            projectPath: "/Users/alex/Projects/AFK",
            projectName: "AFK",
            rawContent: """
            - [x] Implement push notification deep linking
            - [x] Add biometric auth for remote commands
            - [ ] Add App Store screenshots
            - [ ] Write privacy policy page
            - [ ] Localize for Japanese market
            """,
            items: [
                TodoItem(text: "Implement push notification deep linking", checked: true, line: 1),
                TodoItem(text: "Add biometric auth for remote commands", checked: true, line: 2),
                TodoItem(text: "Add App Store screenshots", checked: false, inProgress: true, line: 3),
                TodoItem(text: "Write privacy policy page", checked: false, line: 4),
                TodoItem(text: "Localize for Japanese market", checked: false, line: 5),
            ],
            updatedAt: Date().addingTimeInterval(-300)
        ),
        ProjectTodos(
            projectId: vaporProjectId,
            projectPath: "/Users/alex/Projects/vapor-api",
            projectName: "vapor-api",
            rawContent: """
            - [x] Add rate limiting to REST endpoints
            - [ ] Migrate to PostgreSQL
            - [ ] Add OpenAPI spec generation
            """,
            items: [
                TodoItem(text: "Add rate limiting to REST endpoints", checked: true, line: 1),
                TodoItem(text: "Migrate to PostgreSQL", checked: false, line: 2),
                TodoItem(text: "Add OpenAPI spec generation", checked: false, line: 3),
            ],
            updatedAt: Date().addingTimeInterval(-7200)
        ),
    ]

    // MARK: - Permission Request

    static let permissionRequest = PermissionRequest(
        sessionId: permissionSessionId,
        toolName: "Bash",
        toolInput: ["command": "rm -rf ./build && npm run build --production"],
        toolUseId: "tool_perm_001",
        nonce: "ss_nonce_001",
        expiresAt: Int64(Date().addingTimeInterval(120).timeIntervalSince1970),
        deviceId: macDeviceId
    )

    // MARK: - Event Builders

    private static func buildRunningSessionEvents() -> [SessionEvent] {
        let sid = runningSessionId
        let did = macDeviceId

        let toolInputFields_read = """
        [{"label":"file_path","value":"/src/handlers/sessions.go","style":"path"}]
        """
        let toolInputFields_write = """
        [{"label":"file_path","value":"/src/handlers/sessions.go","style":"path"},{"label":"new_string","value":"func HandleListSessions(w http.ResponseWriter, r *http.Request) {\\n    limit := parseIntParam(r, \\"limit\\", 20)\\n    cursor := r.URL.Query().Get(\\"cursor\\")\\n    sessions, nextCursor, err := store.ListSessionsPaginated(r.Context(), limit, cursor)","style":"code"}]
        """
        let toolInputFields_bash = """
        [{"label":"command","value":"go test ./... -count=1","style":"code"}]
        """

        return [
            // Turn 1: User asks to add pagination
            SessionEvent(
                id: "evt_001", sessionId: sid, deviceId: did,
                eventType: "turn_started", timestamp: ts(-1800),
                payload: ["turnIndex": "1"],
                content: ["userSnippet": "Refactor the /api/sessions endpoint to use cursor-based pagination instead of returning all sessions at once. Add `limit` and `cursor` query parameters."],
                seq: 1
            ),
            SessionEvent(
                id: "evt_002", sessionId: sid, deviceId: did,
                eventType: "tool_started", timestamp: ts(-1798),
                payload: [
                    "toolName": "Read", "toolUseId": "tool_001",
                    "toolCategory": "file", "toolIcon": "doc.text",
                    "toolIconColor": "blue",
                    "toolDescription": "Reading sessions handler",
                ],
                content: [
                    "toolInputSummary": "{\"file_path\": \"/src/handlers/sessions.go\"}",
                    "toolInputFields": toolInputFields_read,
                ],
                seq: 2
            ),
            SessionEvent(
                id: "evt_003", sessionId: sid, deviceId: did,
                eventType: "tool_finished", timestamp: ts(-1796),
                payload: ["toolName": "Read", "toolUseId": "tool_001", "toolCategory": "file"],
                content: ["toolResultSummary": "func HandleListSessions(w http.ResponseWriter, r *http.Request) {\n    sessions, err := store.ListSessions(r.Context())\n    if err != nil {\n        http.Error(w, \"internal error\", 500)\n        return\n    }\n    json.NewEncoder(w).Encode(sessions)\n}"],
                seq: 3
            ),
            SessionEvent(
                id: "evt_004", sessionId: sid, deviceId: did,
                eventType: "assistant_responding", timestamp: ts(-1794),
                payload: nil,
                content: ["assistantSnippet": "I can see the current implementation returns all sessions without pagination. I'll refactor this to support cursor-based pagination with a configurable page size.\n\nHere's my plan:\n1. Add `limit` and `cursor` query parameters\n2. Update the SQL query to use `WHERE id < cursor ORDER BY id DESC LIMIT ?`\n3. Return a `nextCursor` field in the response\n4. Default limit to 20, max 100"],
                seq: 4
            ),

            // Turn 2: Write the refactored code
            SessionEvent(
                id: "evt_005", sessionId: sid, deviceId: did,
                eventType: "turn_started", timestamp: ts(-1200),
                payload: ["turnIndex": "2"],
                content: nil,
                seq: 5
            ),
            SessionEvent(
                id: "evt_006", sessionId: sid, deviceId: did,
                eventType: "tool_started", timestamp: ts(-1198),
                payload: [
                    "toolName": "Edit", "toolUseId": "tool_002",
                    "toolCategory": "file", "toolIcon": "pencil",
                    "toolIconColor": "orange",
                    "toolDescription": "Editing sessions handler",
                ],
                content: [
                    "toolInputSummary": "{\"file_path\": \"/src/handlers/sessions.go\", \"old_string\": \"func HandleListSessions...\"}",
                    "toolInputFields": toolInputFields_write,
                ],
                seq: 6
            ),
            SessionEvent(
                id: "evt_007", sessionId: sid, deviceId: did,
                eventType: "tool_finished", timestamp: ts(-1196),
                payload: ["toolName": "Edit", "toolUseId": "tool_002", "toolCategory": "file"],
                content: ["toolResultSummary": "Successfully edited /src/handlers/sessions.go"],
                seq: 7
            ),
            SessionEvent(
                id: "evt_008", sessionId: sid, deviceId: did,
                eventType: "assistant_responding", timestamp: ts(-1194),
                payload: nil,
                content: ["assistantSnippet": "I've refactored the handler to support cursor-based pagination. The changes include:\n\n- Added `limit` parameter (default 20, max 100)\n- Added `cursor` parameter for pagination\n- Response now includes `nextCursor` when there are more results\n- Updated `ListSessionsPaginated` in the store layer\n\nLet me run the tests to make sure everything passes."],
                seq: 8
            ),

            // Turn 3: Run tests
            SessionEvent(
                id: "evt_009", sessionId: sid, deviceId: did,
                eventType: "turn_started", timestamp: ts(-600),
                payload: ["turnIndex": "3"],
                content: nil,
                seq: 9
            ),
            SessionEvent(
                id: "evt_010", sessionId: sid, deviceId: did,
                eventType: "tool_started", timestamp: ts(-598),
                payload: [
                    "toolName": "Bash", "toolUseId": "tool_003",
                    "toolCategory": "command", "toolIcon": "terminal",
                    "toolIconColor": "green",
                    "toolDescription": "Running test suite",
                ],
                content: [
                    "toolInputSummary": "{\"command\": \"go test ./... -count=1\"}",
                    "toolInputFields": toolInputFields_bash,
                ],
                seq: 10
            ),
            SessionEvent(
                id: "evt_011", sessionId: sid, deviceId: did,
                eventType: "tool_finished", timestamp: ts(-580),
                payload: ["toolName": "Bash", "toolUseId": "tool_003", "toolCategory": "command"],
                content: ["toolResultSummary": "ok  \tgithub.com/alex/vapor-api/handlers\t0.234s\nok  \tgithub.com/alex/vapor-api/store\t\t0.156s\nok  \tgithub.com/alex/vapor-api/middleware\t0.089s\n\nPASS - 42 tests passed, 0 failed"],
                seq: 11
            ),
            SessionEvent(
                id: "evt_012", sessionId: sid, deviceId: did,
                eventType: "assistant_responding", timestamp: ts(-578),
                payload: nil,
                content: ["assistantSnippet": "All 42 tests pass. The pagination refactor is complete. You can now use the endpoint like:\n\n```\nGET /api/sessions?limit=20&cursor=sess_abc123\n```\n\nThe response includes a `nextCursor` field when more results are available."],
                seq: 12
            ),
        ]
    }

    private static func buildPermissionSessionEvents() -> [SessionEvent] {
        let sid = permissionSessionId
        let did = macDeviceId

        return [
            SessionEvent(
                id: "evt_p001", sessionId: sid, deviceId: did,
                eventType: "turn_started", timestamp: ts(-3600),
                payload: ["turnIndex": "1"],
                content: ["userSnippet": "Refactor the database middleware to use connection pooling. The current per-request connection model is causing latency spikes under load."],
                seq: 1
            ),
            SessionEvent(
                id: "evt_p002", sessionId: sid, deviceId: did,
                eventType: "assistant_responding", timestamp: ts(-3590),
                payload: nil,
                content: ["assistantSnippet": "I'll refactor the database middleware to use connection pooling. Let me first examine the current middleware implementation to understand the connection lifecycle."],
                seq: 2
            ),
            SessionEvent(
                id: "evt_p003", sessionId: sid, deviceId: did,
                eventType: "tool_started", timestamp: ts(-3588),
                payload: [
                    "toolName": "Read", "toolUseId": "tool_p001",
                    "toolCategory": "file", "toolIcon": "doc.text",
                    "toolIconColor": "blue",
                    "toolDescription": "Reading database middleware",
                ],
                content: [
                    "toolInputSummary": "{\"file_path\": \"/src/middleware/database.swift\"}",
                    "toolInputFields": "[{\"label\":\"file_path\",\"value\":\"/src/middleware/database.swift\",\"style\":\"path\"}]",
                ],
                seq: 3
            ),
            SessionEvent(
                id: "evt_p004", sessionId: sid, deviceId: did,
                eventType: "tool_finished", timestamp: ts(-3586),
                payload: ["toolName": "Read", "toolUseId": "tool_p001", "toolCategory": "file"],
                content: ["toolResultSummary": "struct DatabaseMiddleware: AsyncMiddleware {\n    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {\n        let conn = try await pool.connection()\n        defer { conn.release() }\n        request.db = conn\n        return try await next.respond(to: request)\n    }\n}"],
                seq: 4
            ),
        ]
    }

    // MARK: - Helpers

    /// Returns an ISO 8601 timestamp offset from now by the given seconds.
    private static func ts(_ offsetFromNow: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date().addingTimeInterval(offsetFromNow))
    }
}

// swiftlint:enable file_length type_body_length
