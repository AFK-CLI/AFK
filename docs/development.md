# Development

## Prerequisites

- **macOS 15+** (Sequoia) — required for the agent and iOS Simulator
- **Xcode 16+** — builds the agent and iOS app
- **Go 1.24+** — builds the backend. CGO must be enabled (SQLite driver uses cgo)
- **Claude Code** — the CLI tool that AFK monitors. Install: `npm install -g @anthropic-ai/claude-code`
- **Docker** (optional) — for running the full stack locally via `docker compose`

## Project Structure

```
AFK/
  backend/              Go server
    cmd/server/         Entry point (main.go, route registration)
    internal/
      auth/             JWT, Apple Sign-In, email/password, WS tickets
      config/           Environment variable loading
      db/               SQLite queries and migrations
      hub/              WebSocket hub (agent + iOS connection pools)
      model/            Data types (Session, Event, Device, Command, etc.)
      monitor/          Stuck session detector
      push/             APNs client and decision engine
    internal/db/        SQLite queries and embedded migrations (migrations.go)
  agent/AFK-Agent/      macOS .app bundle
    Session/            SessionWatcher (JSONL polling), EventNormalizer
    Network/            WebSocketClient
    Security/           E2EEncryption, ContentRedactor, CommandVerifier
    Command/            CommandExecutor, CommandValidator
    Auth/               KeyAgreementIdentity, DeviceIdentity
    Setup/              HookInstaller (PreToolUse/PostToolUse hooks)
    Config/             AgentConfig
  ios/AFK/              SwiftUI app
    Views/              All UI (Auth/, Home/, Sessions/, Settings/, Devices/, NewChat/)
    Services/           APIClient, WebSocketService, SessionStore, AuthService, SyncService
    Security/           E2EEService, DeviceKeyPair
    Model/              Data types, SwiftData models, SessionActivityAttributes
    Persistence/        LocalStore (SwiftData)
  config/               Shared xcconfig files (gitignored secrets)
  nginx/                Reverse proxy config
  docs/                 Documentation
```

## Backend

### Setup

```bash
cd backend
cp .env.example .env
```

Edit `.env`. The only required variable for local development is `AFK_JWT_SECRET`:

```env
AFK_JWT_SECRET=$(openssl rand -hex 32)
AFK_LOG_FORMAT=text
AFK_LOG_LEVEL=debug
```

`AFK_LOG_FORMAT=text` enables human-readable log output instead of JSON.

### Build and Run

```bash
cd backend
go build ./cmd/server
./server
```

The server listens on `http://localhost:9847`. Verify: `curl http://localhost:9847/healthz`

CGO is required because the SQLite driver (`github.com/mattn/go-sqlite3`) uses cgo. If you get linker errors, ensure you have a C compiler installed:

```bash
# macOS — Xcode command line tools
xcode-select --install

# Verify
CGO_ENABLED=1 go build ./cmd/server
```

### Tests

```bash
cd backend
go test ./...           # all tests
go test -race ./...     # with race detection
go test ./internal/hub  # specific package
```

### Key Dependencies

| Package | Purpose |
|---------|---------|
| `github.com/gorilla/websocket` | WebSocket server |
| `github.com/mattn/go-sqlite3` | SQLite driver (CGO) |
| `github.com/golang-jwt/jwt/v5` | JWT signing/verification |
| `golang.org/x/crypto` | bcrypt for password hashing |
| `github.com/joho/godotenv` | `.env` file loading |

No web framework. Routes are registered directly on `http.ServeMux` in `cmd/server/main.go`.

## Agent

### Setup

```bash
# Copy the example config
cp config/AgentSecrets.xcconfig.example config/AgentSecrets.xcconfig
```

Edit `config/AgentSecrets.xcconfig`:

```
AFK_SERVER_URL = https://localhost:9847
```

For local development without TLS, use `http://localhost:9847`. The agent auto-derives the WebSocket URL by replacing `https://` with `wss://` (or `http://` with `ws://`).

### Build

Open in Xcode:

```bash
open agent/AFK-Agent.xcodeproj
```

Or build from the command line:

```bash
cd agent
xcodebuild -scheme AFK-Agent -destination 'platform=macOS' -allowProvisioningUpdates build
```

The agent is a macOS `.app` bundle with `LSUIElement=YES` — it appears in the menu bar, not the Dock. It needs:

- A running backend to connect to
- Claude Code installed and resolvable via `/usr/bin/which claude`
- Keychain access for device keys (prompted on first launch)

### How It Works

1. On launch, the agent polls `~/.claude/projects/` every 2 seconds for modified `.jsonl` files.
2. New JSONL lines are parsed by `EventNormalizer` into structured events with separate `data` (telemetry) and `content` (sensitive text) fields.
3. Events are sent to the backend over WebSocket as `agent.session.event` messages.
4. The agent installs a `PreToolUse` hook into Claude Code's `~/.claude/settings.json` that relays permission requests through a Unix socket at `~/.afk-agent/run/agent.sock`.

## iOS App

### Setup

```bash
cp config/Secrets.xcconfig.example config/Secrets.xcconfig
```

Edit `config/Secrets.xcconfig`:

```
AFK_SERVER_URL = https://localhost:9847
```

For the Simulator, `http://` works. For a physical device, you need a reachable server with valid TLS.

### Build

```bash
open ios/AFK.xcodeproj
# Select a Simulator target → Cmd+R
```

From the command line:

```bash
cd ios
xcodebuild build -scheme AFK -destination 'platform=iOS Simulator,name=iPhone 16'
```

For physical devices, update the bundle identifier and signing team in Xcode.

### Simulator Authentication

In the Simulator, use email/password sign-in to authenticate. Register a test account via `POST /v1/auth/register` or the iOS sign-in screen.

## Environment Variables

### Backend (.env)

See [docs/self-hosting.md](self-hosting.md#configuration-reference) for the full reference. For local dev, the minimum is:

```env
AFK_JWT_SECRET=<any-hex-string>
```

### Agent (config/AgentSecrets.xcconfig)

```
AFK_SERVER_URL = http://localhost:9847
```

### iOS (config/Secrets.xcconfig)

```
AFK_SERVER_URL = http://localhost:9847
```

## Running Tests

### Backend

```bash
cd backend && go test ./...
```

### iOS

```bash
xcodebuild test -scheme AFK -destination 'platform=iOS Simulator,name=iPhone 16'
```

### Agent

```bash
xcodebuild test -scheme AFK-Agent -destination 'platform=macOS'
```

## Project Conventions

- **Go**: `gofmt` formatting. `go vet ./...` should pass. No web framework — handlers are plain `http.HandlerFunc`.
- **Swift**: Swift API Design Guidelines. Use `actor` for thread-safe state. Use `@Observable` (not `ObservableObject`) for SwiftUI models.
- **Xcode projects** use `PBXFileSystemSynchronizedRootGroup` — adding new Swift files to the filesystem automatically includes them in the build. No manual `.pbxproj` edits needed.
- **Commit messages**: [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`).
- **No third-party crypto**: iOS and agent use Apple CryptoKit exclusively. Backend uses Go's `crypto/*` standard library.

## Adding a New WebSocket Message Type

End-to-end example: adding a new `agent.session.summary` message type.

### 1. Define the payload (Backend)

Add the message type constant and payload struct in `backend/internal/model/`:

```go
// In websocket.go or a new file
const MsgAgentSessionSummary = "agent.session.summary"

type SessionSummaryPayload struct {
    SessionID string `json:"sessionId"`
    Summary   string `json:"summary"`
}
```

### 2. Handle in the Hub (Backend)

In `backend/internal/ws/agent_conn.go`, add a case to the agent message handler:

```go
case model.MsgAgentSessionSummary:
    var p model.SessionSummaryPayload
    json.Unmarshal(msg.Payload, &p)
    // Store, transform, or relay
    hub.BroadcastToUser(userID, msg)
```

### 3. Send from the Agent (Swift)

In the agent, use `MessageEncoder` to build the message and send it via the WebSocket client:

```swift
// MessageEncoder builds the WSMessage envelope with type + payload + timestamp
let msg = try MessageEncoder.encode(
    type: "agent.session.summary",
    payload: ["sessionId": sessionId, "summary": summary]
)
try await wsClient.send(msg)
```

### 4. Handle on iOS (Swift)

In `WebSocketService.swift`, add a case to the message handler:

```swift
case "session.summary":
    let summary = payload["summary"] as? String ?? ""
    await sessionStore.handleSummary(sessionId: sessionId, summary: summary)
```

### 5. Update the push decision engine (if needed)

In `backend/internal/push/decision.go`, classify the new event type:

```go
case "session_summary":
    return PriorityRoutine
```

## Adding a New API Endpoint

Example: adding `GET /v1/sessions/{id}/summary`.

### 1. Add the handler (Backend)

Create the handler in `backend/internal/` (either in an existing handler file or a new one):

```go
func (s *Server) handleGetSessionSummary(w http.ResponseWriter, r *http.Request) {
    sessionID := r.PathValue("id")
    userID := r.Context().Value(userIDKey).(string)
    // Query DB, write JSON response
}
```

### 2. Register the route

In `backend/cmd/server/main.go`, add the route with the auth middleware:

```go
mux.HandleFunc("GET /v1/sessions/{id}/summary", s.authMiddleware(s.handleGetSessionSummary))
```

### 3. Add the API call (iOS)

In `ios/AFK/Services/APIClient.swift`:

```swift
func getSessionSummary(sessionId: String) async throws -> SessionSummary {
    return try await get("/v1/sessions/\(sessionId)/summary")
}
```

## Debugging Tips

- **Backend WebSocket traffic**: Set `AFK_LOG_LEVEL=debug` to see every WebSocket message in the server logs.
- **Agent logs**: Open Console.app on macOS and filter by process `AFK-Agent`. The agent logs WebSocket connection state, event processing, and hook activity.
- **iOS WebSocket**: The `DiagnosticsView` in the iOS app (Settings → Diagnostics) shows WebSocket connection status, message counts, and latency.
- **SQLite inspection**: `docker compose exec afk-cloud sqlite3 /data/afk.db` or directly open the local `afk.db` with any SQLite client.
- **Permission hook debugging**: The hook script logs to stderr, visible in the Claude Code terminal. Check `~/.afk-agent/run/` for socket and flag files.
- **E2EE debugging**: Both the agent and iOS log key fingerprints on enrollment. Compare them to verify both sides have the correct peer key. Look for "key agreement" and "fingerprint" in logs.
