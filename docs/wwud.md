# WWUD (What Would User Do?) — Smart Permission Mode

WWUD is a pattern-based permission learning system that runs entirely on-device. It observes how users respond to Claude Code tool permission requests, builds per-project patterns, and eventually auto-decides with configurable confidence thresholds. Users can override wrong decisions from iOS, which retrains the model with 3x weight.

## Architecture

```
iOS App                          Backend (Go)                     macOS Agent
-----------                      ---------------                  ----------------
PermissionModeMenu               Zero logic.                      PermissionSocket
  "Smart Mode" toggle            Pure relay:                        mode == .wwud
                                                                     |
WWUDDigestView                   agent.wwud.auto_decision         WWUDEngine (actor)
  transparency feed              --> wwud.auto_decision              evaluate()
  override buttons                                                   recordDecision()
                                 agent.wwud.stats                    recordOverride()
PermissionOverlay                --> wwud.stats                      getStats()
  "will teach Smart Mode"
                                 app.wwud.override                WWUDPatternMatcher
SessionStore                     --> server.wwud.override            extractPatterns()
  wwudAutoDecisions[]                                                matches()
  wwudStats                                                          createDecision()

                                                                  WWUDStore
                                                                    ~/.afk-agent/wwud/
                                                                    <sha256>/decisions.json
```

All intelligence runs on the agent. The backend is a dumb relay. No decision data is stored server-side.

## How It Works

### 1. Recording Decisions

Every permission decision is recorded as a `WWUDDecision` with rich context extracted from the tool call:

| Tool | Extracted Context |
|------|------------------|
| Bash | Command prefix (first 2 tokens): `npm test`, `git push` |
| Write/Edit | File path, extension (`.swift`), directory (`src/lib`) |
| WebFetch/WebSearch | Target domain (`github.com`) |
| All | Project path, timestamp, source, weight |

Decisions come from three sources:

| Source | Weight | Description |
|--------|--------|-------------|
| `user` | 1.0 | User approved/denied from iOS |
| `auto` | 1.0 | WWUD auto-decided |
| `override` | 3.0 | User corrected a wrong auto-decision |
| `terminal` | 1.0 | Tool executed via terminal (PostToolUse hook) |

### 2. Pattern Matching

When a new permission request arrives, the engine generates patterns at four specificity levels and tries each in order:

| Level | Pattern | Example | Auto-decides? |
|-------|---------|---------|---------------|
| 1 | Tool + project + exact input | `Bash 'npm test' in AFK` | Yes |
| 2 | Tool + project + broad input | `Bash 'npm *' in AFK` | Yes |
| 3 | Tool + project only | `Bash in AFK` | Yes |
| 4 | Tool only (cross-project) | `Bash anywhere` | No (informational) |

Level 4 never auto-decides to prevent cross-project leakage.

### 3. Confidence Calculation

For each pattern level, three gates must pass:

1. **Minimum weighted decisions** (default: 5.0) — enough data to be meaningful
2. **Confidence threshold** (default: 80%) — dominant action ratio must exceed this
3. **Recent unanimity** (default: last 3) — the most recent 3 user decisions must all agree with the dominant action

If all three gates pass, the engine auto-allows or auto-denies. Otherwise it falls through to the next specificity level, and ultimately forwards to iOS if no pattern is confident enough.

### 4. Weight Decay

Decisions lose relevance over time:

| Age | Weight Multiplier |
|-----|------------------|
| 0 to 30 days | 1.0x (full) |
| 30 to 90 days | 0.5x (half) |
| 90+ days | Expired, pruned from disk |

### 5. Override Correction

When WWUD makes a wrong auto-decision:

1. iOS shows the decision in the transparency feed (WWUDDigestView)
2. User taps "Should Deny" or "Should Allow"
3. iOS sends `app.wwud.override` through the backend
4. Agent records a new decision with 3x weight and the corrected action
5. Future evaluations shift quickly toward the corrected behavior

One override is equivalent to three normal decisions.

## Data Storage

Decisions are stored per-project in JSON files:

```
~/.afk-agent/wwud/
  <sha256-of-project-path>/
    decisions.json
```

The SHA256 hash prevents filesystem issues with long/special-character paths. Files use atomic write-to-tmp + rename for crash safety.

## iOS UI

### Permission Mode Menu

Smart Mode appears as a purple brain icon in the permission mode picker, alongside Ask, Accept Edits, Plan, and Auto-Approve.

### Transparency Feed (WWUDDigestView)

Shown in SessionDetailView when Smart Mode is active. Displays:

- Header with auto-approved/auto-denied counts
- Expandable rows for each auto-decision (tool name, input preview, confidence %, relative time)
- Override buttons ("Should Deny" / "Should Allow") in expanded state
- Empty state: "Learning from your decisions..."

### Permission Overlay

When Smart Mode is active and a permission is forwarded to iOS (uncertain), the overlay shows a purple indicator: "Your decision will teach Smart Mode".

## WebSocket Messages

### Agent to Backend

| Type | Payload | Description |
|------|---------|-------------|
| `agent.wwud.auto_decision` | `sessionId`, `toolName`, `toolInputPreview`, `action`, `confidence`, `patternDescription`, `timestamp`, `decisionId` | Transparency notification |
| `agent.wwud.stats` | `totalDecisions`, `autoApproved`, `autoDenied`, `forwarded`, `topPatterns[]` | Aggregate stats |

### iOS to Backend

| Type | Payload | Description |
|------|---------|-------------|
| `app.wwud.override` | `deviceId`, `decisionId`, `correctedAction` | User correction |

### Backend to Agent

| Type | Payload | Description |
|------|---------|-------------|
| `server.wwud.override` | `decisionId`, `correctedAction` | Forwarded correction |

### Backend to iOS

| Type | Payload | Description |
|------|---------|-------------|
| `wwud.auto_decision` | (same as agent payload) | Forwarded transparency event |
| `wwud.stats` | (same as agent payload) | Forwarded stats |

## Configuration

Default engine parameters (set in `WWUDEngine.init`):

| Parameter | Default | Description |
|-----------|---------|-------------|
| `minDecisions` | 5.0 | Minimum weighted decisions before auto-deciding |
| `confidenceThreshold` | 0.80 | Required ratio for dominant action |
| `recentUnanimousCount` | 3 | Last N user decisions must agree |

## Security Notes

- All WWUD data stays on-device. The backend never stores or inspects decision history.
- WWUD respects E2EE boundaries. Tool input previews sent to iOS for transparency are truncated to 200 characters.
- Level 4 patterns (tool-only, no project scope) are never used for auto-decisions, preventing a decision in one project from affecting another.
- Override weight (3x) ensures rapid correction when the engine gets it wrong.
