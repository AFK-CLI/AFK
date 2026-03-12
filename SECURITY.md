# Security

## Reporting Vulnerabilities

Do not open a public GitHub issue for security vulnerabilities.

Email security concerns to the maintainers directly. Include:

- A description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

We acknowledge receipt within 48 hours and aim to provide a fix within 7 days for critical issues.

## Threat Model

AFK relays Claude Code session data between a macOS agent and an iOS app through a server. The threat model assumes:

**Trusted**: The macOS agent and iOS app are running on devices the user controls. The user has physical access to both devices.

**Untrusted**: The network between devices and the server. In E2EE mode, the server itself is untrusted for content confidentiality — it can see metadata (session IDs, timestamps, event types) but not session content.

**Out of scope**: Compromise of the macOS or iOS device itself (keychain extraction, memory inspection). If an attacker has root on your Mac, they can read Claude Code's output directly.

### What AFK Protects Against

- **Passive network observers**: All traffic is over TLS. In E2EE mode, content is additionally encrypted end-to-end.
- **Server compromise (with E2EE)**: An attacker with full database access sees encrypted blobs for session content. They can see metadata: which user, which session, when, event types, token counts — but not what Claude Code said or did.
- **Command forgery**: Remote prompts are signed with Ed25519. The agent verifies the server's signature before executing any command. Nonces prevent replay attacks.
- **Permission response tampering**: Permission approve/deny responses are HMAC-SHA256 signed with an E2EE-derived key. The agent verifies the HMAC before forwarding the decision to Claude Code.
- **Token theft on WebSocket**: WebSocket connections use short-lived (30s), single-use tickets instead of long-lived JWT tokens. Tickets are consumed on use.

### What AFK Does Not Protect Against

- **Metadata analysis**: Even with E2EE, the server sees event types, session timing, tool names, token counts, and project paths (as hashes in some modes). An observer can infer activity patterns.
- **Forward secrecy (`e1:` only)**: Messages using the `e1:` wire format use long-term Curve25519 keys. If a device's long-term private key is compromised, all past `e1:` messages encrypted with that key can be decrypted. The `e2:` wire format provides forward secrecy via per-message ephemeral Curve25519 keys — compromising the long-term key does not reveal `e2:` message content. Key rotation limits the blast radius of `e1:` messages going forward.
- **Key loss**: If the iOS device's private key is lost (device wipe without backup), all content encrypted to that key becomes permanently unreadable. The agent-side Keychain key is device-bound and not backed up either.
- **Multi-device correlation**: The server knows which devices belong to the same user and can correlate their activity.
- **Denial of service**: No protection against an attacker flooding the server with requests (beyond basic rate limiting).

## Authentication

**Apple Sign-In**: Identity tokens are verified against Apple's JWKS endpoint. The server checks the audience claim matches the configured bundle IDs, the issuer is `https://appleid.apple.com`, and the token hasn't expired.

**Email/password**: Passwords are bcrypt-hashed with cost 12. Login is rate-limited per IP (10 requests burst, refill 1 per 6 seconds) and per email (max 5 failures per 15 minutes). Email auth requires HTTPS in production.

**JWT tokens**: Access tokens expire after 15 minutes. Refresh tokens expire after 30 days and are stored as SHA-256 hashes in the database. Refresh token rotation: each use revokes the old token and issues a new pair.

## Command Signing (Ed25519)

Every remote command (continue, new chat, cancel) is signed by the server before being sent to the agent:

```
canonical = "commandId|sessionId|promptHash|nonce|expiresAt"
signature = Ed25519.Sign(serverPrivateKey, SHA-512(canonical))
```

- `promptHash` is SHA-256 of the prompt text (hex-encoded)
- `nonce` is a UUID, tracked in an in-memory store with 10-minute TTL
- `expiresAt` is a Unix timestamp, typically 5 minutes from issuance

The agent rejects commands with invalid signatures, reused nonces, or expired timestamps.

The server's Ed25519 key pair can be provided via `AFK_SERVER_PRIVATE_KEY` / `AFK_SERVER_PUBLIC_KEY` environment variables. If not set, an ephemeral key pair is generated on startup — this means command signatures become invalid after a server restart.

## End-to-End Encryption

### Key Agreement

Each device generates a Curve25519 key pair using Apple CryptoKit (`Curve25519.KeyAgreement`). The public key is registered with the server on enrollment. Encryption keys are derived per-session:

```
sharedSecret = ECDH(myPrivateKey, peerPublicKey)       // 32 bytes
sessionKey   = HKDF-SHA256(sharedSecret, sessionId, "afk-e2ee-content-v1")  // 32 bytes
```

Content is encrypted with AES-256-GCM. Two wire formats are supported:

**`e1:` (long-term keys)**:
```
e1:<keyVersion>:<senderDeviceId>:<base64(nonce || ciphertext || tag)>
```

**`e2:` (forward secrecy)**:
```
e2:<keyVersion>:<senderDeviceId>:<ephemeralPublicKey-base64>:<base64(nonce || ciphertext || tag)>
```

`e2:` generates a fresh ephemeral Curve25519 key pair per message. The encryption key is derived from `ECDH(ephemeralPrivate, peerLongTermPublic)`. The ephemeral private key is discarded after encryption. The receiver uses the ephemeral public key from the envelope plus their long-term private key to derive the decryption key.

### What E2EE Encrypts

Session **content** fields: assistant text snippets, user message snippets, tool inputs, tool outputs. These are the fields in the `content` JSON of `session_event` messages.

### What E2EE Does Not Encrypt

Session **metadata**: event type, timestamp, sequence number, session ID, device ID, project path, git branch, token counts, turn counts, tool names (without arguments), session status. This data is in the `data` JSON and is always plaintext.

### Key Storage

- **iOS**: Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. A backup key is stored separately for recovery from primary key corruption.
- **Agent (macOS)**: Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. No backup key (macOS Keychain is more stable).

Both are device-bound — they do not sync via iCloud Keychain and are not included in unencrypted backups.

### Key Rotation

Either device can rotate its key pair at any time. The server atomically revokes the old key, increments the version, and broadcasts `device.key_rotated` to all connected peers. Old keys are archived in the `device_keys` table for historical decryption.

## Permission HMAC

Permission responses (approve/deny) are signed with a domain-separated HMAC key:

```
permKey = HKDF-SHA256(sharedSecret, agentDeviceId, "afk-permission-hmac-v1")
hmac    = HMAC-SHA256(permKey, "nonce|action|expiresAt")
```

This prevents the server from forging permission responses, even though it relays them.

## Privacy Modes

| Mode | Content in Transit | Content at Rest | Metadata at Rest |
|------|--------------------|-----------------|------------------|
| `telemetry_only` | TLS | Plaintext in DB | Plaintext in DB |
| `relay_only` | TLS | Not stored | SHA-256 hash in audit log |
| `encrypted` | TLS + E2EE | Encrypted blob in DB | Plaintext in DB |

`telemetry_only` is the default. `relay_only` prevents the server from writing event content to disk — it only forwards via WebSocket and logs a content hash for auditability. `encrypted` stores content but the server cannot read it.

Privacy mode is set per device and can be overridden per project path.

## Dependencies

The attack surface is kept small:

- **Go backend**: `gorilla/websocket`, `pgx/v5` (PostgreSQL, pure Go), `golang-jwt/jwt`, `golang.org/x/crypto` (bcrypt only), `godotenv`. No web framework.
- **iOS and agent**: Apple frameworks only — `CryptoKit`, `SwiftData`, `ActivityKit`, `AuthenticationServices`. No third-party crypto libraries.

## Supported Versions

Security updates are provided for the latest release only.
