# Architecture

AFK has three components: a macOS menu bar agent that watches Claude Code output, a Go backend that relays events and stores state, and an iOS app that displays sessions and sends commands. All session content can be end-to-end encrypted between the agent and iOS app — the backend acts as a zero-knowledge relay.

## Components

### Backend (`backend/`)

Go server. Listens on a single port (default 9847). Handles both HTTP REST and WebSocket upgrades.

- **WebSocket hub** — maintains persistent connections to agents (`/v1/ws/agent`) and iOS clients (`/v1/ws/app`). Broadcasts session events from agents to subscribed iOS connections. Manages per-user connection pools with automatic cleanup on disconnect.
- **REST API** — device enrollment, session queries with cursor-based pagination, command submission (rate-limited), key exchange endpoints, push token registration, notification preferences, audit log.
- **PostgreSQL** — stores users, devices, sessions, events, commands, audit log, device keys, push tokens, notification preferences. Migrations run automatically on startup.
- **APNs client** — HTTP/2 token-based auth with ES256 JWT. Sends visible alerts (priority 10) and silent pushes (priority 5). Handles Live Activity updates and push-to-start (iOS 17.2+). Auto-removes invalid tokens on 410 responses.
- **Push decision engine** — classifies events by priority, suppresses bursts, aggregates routine events, and skips pushes when the iOS app has an active WebSocket connection.
- **Prometheus metrics** — exposed at `/metrics`. Tracks HTTP requests, WebSocket connections, message throughput, command lifecycle, rate limit hits.
- **Stuck session detector** — background goroutine that runs every 2 minutes. Marks sessions as `stuck` if no update received for 5 minutes.

### Agent (`agent/AFK-Agent/`)

macOS `.app` bundle with `LSUIElement=YES` (menu bar only, no Dock icon). Written in Swift.

- **JSONL watcher** — `actor`-based poller that scans `~/.claude/projects/` every 2 seconds for modified `.jsonl` files. Tracks file modification dates to avoid replaying history on startup.
- **Event normalizer** — parses raw Claude Code JSONL entries into structured events. Extracts two field sets per event: `data` (plaintext telemetry — tool names, turn counts, token usage) and `content` (sensitive text — encrypted in E2EE mode). Detects permission stalls (tool pending >10s) and emits `permission_needed` events.
- **WebSocket client** — `actor`-based, uses `URLSessionWebSocketTask`. Authenticates via short-lived WS ticket. Reconnects with exponential backoff (1s → 60s). Queues up to 1000 messages while offline. Sends heartbeats every 30s with active session list for server-side reconciliation.
- **Command executor** — receives remote prompts, verifies Ed25519 server signature + nonce, validates arguments against allowlist, resolves `claude` binary, invokes `claude --resume <id> --fork-session -p <prompt> --output-format json`. Streams output back through WebSocket.
- **Permission hook** — installs a `PreToolUse` hook script into Claude Code's `~/.claude/settings.json`. When Claude Code calls a tool, the hook connects to the agent's Unix socket at `~/.afk-agent/run/agent.sock`, the agent relays the request to iOS, waits for an HMAC-signed response, and returns allow/deny to Claude Code. A `PostToolUse` hook also fires after each tool execution, recording the allowed tool call in the WWUD engine for pattern learning.
- **WWUD engine** — on-device pattern-based permission learning system. Observes user decisions (from iOS and terminal), builds per-project patterns at multiple specificity levels, and auto-decides with configurable confidence thresholds. See [wwud.md](wwud.md) for details.

### iOS App (`ios/AFK/`)

SwiftUI. Targets iOS 17+.

- **Session list** — grouped by project, filterable by status, searchable by path or branch. Shows device online indicators and stuck session badges.
- **Conversation view** — message bubbles for user/assistant turns, rich tool call cards with structured display of tool inputs and outputs, streaming output view for active commands.
- **Remote continue** — prompt composer with slash command menu and prompt templates. Command history. FaceID/TouchID gate before sending. Commands sent via REST POST (not WebSocket).
- **Permission overlay** — approve/deny sheet with tool details. HMAC-signed responses. Supports plan approval for `ExitPlanMode`.
- **Live Activities** — Lock Screen widget showing active session progress, current tool, turn count.
- **Offline-first** — SwiftData local cache with background refresh via `BGAppRefreshTask`. Loads from local store on launch, syncs via REST.

## Data Flow

### Event Lifecycle

1. Claude Code writes a JSONL line to its output file.
2. The agent's file watcher detects the modification and reads new lines.
3. The event normalizer parses the line, extracts telemetry into `data` and sensitive content into `content`.
4. If E2EE is active, `content` fields are encrypted per-peer using each connected device's ECDH-derived session key. The result is a map of `<deviceId>:<fieldName>` → ciphertext.
5. The agent sends `agent.session.event` over WebSocket.
6. The backend stores the event (unless `relay_only` privacy mode). In `encrypted` mode, it stores the encrypted blobs verbatim.
7. The backend forwards the event to all iOS WebSocket connections subscribed to that session.
8. If no iOS connection is active, the push decision engine evaluates the event and may send an APNs notification.
9. The iOS app decrypts `content` fields using its own ECDH-derived session key and updates the UI.

### Remote Command Flow

1. User types a prompt in the iOS app.
2. If E2EE is active, the prompt is encrypted with the agent's ECDH-derived session key.
3. The app sends `POST /v2/sessions/{id}/continue` with the prompt, a SHA-256 hash, a nonce, and an expiry timestamp.
4. The backend stores the command, signs it with Ed25519 (`commandId|sessionId|promptHash|nonce|expiresAt`), and sends `server.command` to the agent over WebSocket.
5. The agent verifies the signature, checks the nonce hasn't been used, decrypts the prompt (if encrypted), and invokes Claude Code.
6. Output streams back: `agent.command.ack` → `agent.command.chunk` (repeated) → `agent.command.done`.
7. The backend forwards each chunk to the iOS app's WebSocket connection as `command.chunk`.

### Permission Request Flow

1. Claude Code invokes a tool and the `PreToolUse` hook fires.
2. The hook script connects to the agent's Unix socket and sends the tool details.
3. The agent sends `agent.permission_request` to the backend via WebSocket.
4. The backend forwards `session.permission_request` to iOS and sends an APNs push (priority critical).
5. The user taps Approve or Deny in the iOS app (or in the push notification action buttons).
6. iOS sends `app.permission.response` with an HMAC-SHA256 signature over `nonce|action|expiresAt`.
7. The backend forwards `permission.response` to the agent.
8. The agent verifies the HMAC, then returns `{"allow": true}` or `{"deny": true}` to Claude Code via the hook.

## WebSocket Protocol

All messages use this envelope:

```json
{"type": "string", "payload": {}, "ts": 1234567890123}
```

`ts` is Unix milliseconds. `type` identifies the message. `payload` contains type-specific data.

### Agent → Backend

| Type | Key Payload Fields | Description |
|------|-------------------|-------------|
| `agent.heartbeat` | `deviceId`, `uptime`, `activeSessions` | Keep-alive. Backend reconciles session status against the reported active list. |
| `agent.session.update` | `sessionId`, `projectPath`, `status`, `tokensIn`, `tokensOut` | Session metadata upsert. |
| `agent.session.event` | `sessionId`, `eventType`, `data`, `content?`, `seq` | Session event. `data` is plaintext telemetry. `content` is encrypted or plaintext depending on privacy mode. |
| `agent.session.completed` | `sessionId` | Session finished. |
| `agent.permission_request` | `sessionId`, `toolName`, `toolInput`, `toolUseId`, `nonce`, `expiresAt` | Tool permission request from Claude Code. |
| `agent.command.ack` | `commandId`, `sessionId` | Command received, execution starting. |
| `agent.command.chunk` | `commandId`, `sessionId`, `text`, `seq` | Streaming output chunk. |
| `agent.command.done` | `commandId`, `sessionId`, `durationMs?`, `costUsd?`, `newSessionId?` | Command complete. `newSessionId` set when fork created. |
| `agent.command.failed` | `commandId`, `sessionId`, `error` | Command failed. |
| `agent.command.cancelled` | `commandId`, `sessionId` | Command cancelled. |

### Backend → Agent

| Type | Key Payload Fields | Description |
|------|-------------------|-------------|
| `server.command.continue` | `commandId`, `sessionId`, `prompt`, `promptEncrypted?`, `promptHash`, `nonce`, `expiresAt`, `signature` | Remote continue. Ed25519-signed. |
| `server.command.new` | `commandId`, `projectPath`, `prompt`, `promptEncrypted?`, `promptHash`, `useWorktree`, `nonce`, `expiresAt`, `signature` | New chat command. |
| `server.command.cancel` | `commandId` | Cancel active command. |
| `permission.response` | `nonce`, `action`, `signature`, `fallbackSignature?` | Permission decision from iOS. HMAC-signed. |
| `permission_mode` | `mode` | Change permission mode (`ask`, `acceptEdits`, `plan`, `autoApprove`). |
| `device.key_rotated` | `deviceId`, `keyVersion`, `publicKey` | Peer E2EE key rotation notification. |

### Backend → iOS

| Type | Key Payload Fields | Description |
|------|-------------------|-------------|
| `session.update` | `session`, `deviceName` | Session metadata update. |
| `session.event` | `id`, `seq`, `sessionId`, `eventType`, `data`, `content?`, `deviceName` | Live session event. |
| `session.permission_request` | `sessionId`, `toolName`, `toolInput`, `toolUseId`, `nonce`, `expiresAt`, `deviceId` | Permission to approve. |
| `device.status` | `deviceId`, `deviceName`, `isOnline` | Agent online/offline status change. |
| `command.running` | `commandId`, `sessionId` | Command acknowledged by agent. |
| `command.chunk` | `commandId`, `sessionId`, `text`, `seq` | Streaming output. |
| `command.done` | `commandId`, `sessionId`, `durationMs?`, `costUsd?`, `newSessionId?` | Command finished. |
| `command.failed` | `commandId`, `sessionId`, `error` | Command error. |
| `device.key_rotated` | `deviceId`, `keyVersion`, `publicKey` | Peer key rotation. |

### iOS → Backend

| Type | Key Payload Fields | Description |
|------|-------------------|-------------|
| `app.subscribe` | `sessionIds` | Subscribe to events for these sessions. |
| `app.permission.response` | `nonce`, `action`, `signature`, `deviceId` | Permission decision. HMAC-signed. |
| `app.permission_mode` | `deviceId`, `mode` | Change agent's permission mode. |

## E2EE Design

### Key Exchange

Each device (agent and iOS app) generates a Curve25519 key pair on first launch. The public key is registered with the backend via `POST /v1/devices` (on enrollment) or `POST /v1/devices/{id}/key-agreement` (on rotation).

When encrypting, a device fetches the peer's public key from the backend and computes:

```
sharedSecret = ECDH(myPrivateKey, peerPublicKey)  // 32 bytes
```

Both sides compute the same shared secret because `ECDH(A_priv, B_pub) == ECDH(B_priv, A_pub)`.

### Encryption Envelope

Session content is encrypted with per-session keys derived via HKDF:

```
sessionKey = HKDF-SHA256(
    ikm:  sharedSecret,
    salt: sessionId (UTF-8),
    info: "afk-e2ee-content-v1" (UTF-8),
    len:  32
)
```

Encryption uses AES-256-GCM. The sealed output is `nonce (12 bytes) || ciphertext || tag (16 bytes)`.

Wire formats:

**`e1:` (long-term keys)**:
```
e1:<senderKeyVersion>:<senderDeviceId>:<base64(nonce||ciphertext||tag)>
```

**`e2:` (forward secrecy)**:
```
e2:<senderKeyVersion>:<senderDeviceId>:<ephemeralPublicKey-base64>:<base64(nonce||ciphertext||tag)>
```

`e2:` derives a per-message shared secret using an ephemeral Curve25519 key pair. The sender generates a fresh key pair for each message, computes `ECDH(ephemeralPrivate, peerLongTermPublic)`, and includes the ephemeral public key in the envelope. The receiver uses the ephemeral public key plus their long-term private key to derive the same decryption key. The ephemeral private key is discarded after encryption, providing forward secrecy.

**Legacy** (no metadata): plain `base64(nonce||ciphertext||tag)`. Still accepted for backward compatibility.

For multi-device scenarios, the sender encrypts separately for each peer device. The event's `content` field becomes a map:

```json
{
  "<deviceId1>:<fieldName>": "e1:2:sender-id:...",
  "<deviceId2>:<fieldName>": "e1:2:sender-id:..."
}
```

### Permission HMAC

Permission responses use a domain-separated key to prevent cross-protocol attacks:

```
permKey = HKDF-SHA256(
    ikm:  sharedSecret,
    salt: agentDeviceId (UTF-8),
    info: "afk-permission-hmac-v1" (UTF-8),
    len:  32
)
```

The HMAC covers the canonical string `nonce|action|expiresAt`.

### Key Rotation and Archival

When a device rotates its key pair:

1. New key pair generated, registered via `POST /v1/devices/{id}/key-agreement`.
2. Backend atomically revokes the old key, increments `key_version`, inserts the new key, and writes an audit log entry.
3. Backend broadcasts `device.key_rotated` to all of the user's connections.
4. Peers invalidate cached session keys and re-derive from the new public key.

Old keys are archived in the `device_keys` table with their version number. When decryption fails with the current key, the receiver parses the sender's key version from the wire format and fetches the historical key via `GET /v1/devices/{id}/key-agreement/{version}`.

Fallback stages: cached key → refetch current peer key → historical key by version from wire format → give up (show `[encrypted]`).

### Limitations

- **Forward secrecy (`e1:` only)**: Messages using the `e1:` wire format share the same long-term ECDH secret until a key rotation occurs. If a device's long-term private key is compromised, all `e1:` messages encrypted with that key can be decrypted. The `e2:` wire format provides forward secrecy via per-message ephemeral Curve25519 keys — compromising the long-term key does not reveal `e2:` message content.
- If the iOS private key is lost (e.g., device wipe without backup), all historical content encrypted to that key is permanently unreadable.
- The `e1:` wire format records the sender's key version but not the receiver's, so programmatic recovery when the receiver's key changed is not possible.

## Authentication

### Apple Sign-In

Primary auth method. The iOS app uses `AuthenticationServices` to get an Apple identity token. The backend verifies the token against Apple's JWKS endpoint, upserts a user record, and issues a JWT access token (24h expiry) with a refresh token (30d, SHA-256 hashed in DB).

### Email/Password

Secondary method. Passwords are bcrypt-hashed (cost 12). Login is rate-limited per IP (10 req/burst, refill 1 per 6s) and per email (5 failures per 15 minutes). Requires HTTPS in production.

### WebSocket Authentication

WebSocket connections use a ticket system to avoid sending long-lived tokens in query strings. The client calls `POST /v1/auth/ws-ticket` with its JWT, receives a 30-second single-use ticket, and connects to the WebSocket endpoint with `?ws_ticket=<ticket>`.

### Agent Migration

When the agent enrolls before any iOS user exists, it creates a dev placeholder user. On the first Apple Sign-In from iOS, `MigrateDevUser` moves all devices and sessions to the real user and force-disconnects the agent's WebSocket so it reconnects under the new user ID.

## Push Notification Pipeline

### Decision Engine

The push decision engine classifies every event into one of four priorities:

| Priority | Events | Behavior |
|----------|--------|----------|
| **Critical** | `permission_needed`, `error_raised` | Push immediately. Flushes any pending aggregation buffer first. |
| **Important** | `session_completed` | Push unless the user has an active WebSocket connection. |
| **Routine** | `turn_started`, `turn_completed`, `tool_started`, `tool_finished`, `session_started`, `session_idle` | Aggregated over a 30-second window into a single summary notification. |
| **Suppressed** | `usage_update`, `text_delta`, `assistant_responding` | Never pushed. |

### Suppression Rules

- **Burst limit**: max 5 pushes per user per 30 seconds, tracked via a ring buffer of 16 timestamps.
- **First-error-only**: after the first error push for a session, subsequent errors in the same session are suppressed for 5 minutes.
- **Active connection skip**: important-priority events are not pushed when the iOS app has an active WebSocket connection.
- **Aggregate flush on critical**: if a critical event arrives while routine events are being aggregated, the aggregate is flushed first to give context before the alert.

### Notification Categories (iOS)

| Category | Actions | Auth Required |
|----------|---------|---------------|
| `permission_request` | Approve, Deny | Yes (Approve) |
| `ask_user_question` | Tap to open | No |
| `session_error` | Open Session | No |
| `session_completed` | Open Session | No |
| `session_activity` | Open Session | No |
