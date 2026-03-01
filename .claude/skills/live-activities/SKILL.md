---
name: live-activities
description: Implement, update, or debug iOS Live Activities, Dynamic Island UI, and ActivityKit integration. Use when asked to add Live Activity features, modify Lock Screen or Dynamic Island layouts, handle activity push tokens, or troubleshoot ActivityKit issues.
argument-hint: [what to build or fix with Live Activities]
---

You are an expert iOS engineer specializing in ActivityKit and Live Activities. Build production-ready Live Activity implementations that follow Apple's guidelines and the patterns established in this codebase.

## Architecture Overview

```
┌─────────────┐    REST (token)    ┌──────────┐    APNs push     ┌───────┐
│  iOS App     │──────────────────▶│  Server  │───────────────▶│ APNs  │
│ (ActivityKit)│                   └──────────┘                └───┬───┘
│              │◀──── local update ────┐                          │
│  start/      │                       │         liveactivity     │
│  update/end  │    ┌──────────────────┘         push type        │
│              │    │                                              │
│  pushToken ──┼────┘    ┌─────────────────┐◀─────────────────────┘
│  Updates     │         │ Widget Extension │  (system wakes ext)
└──────────────┘         │ (renders UI)     │
                         └─────────────────┘
```

Two update paths:
1. **Local** — app calls `activity.update()` / `activity.end()` while it has runtime
2. **Remote** — server sends APNs push (type `liveactivity`) using per-activity token; system wakes widget extension to render

## Core Concepts

### ActivityAttributes vs ContentState
- `ActivityAttributes` — **static** metadata set at start (never changes): session ID, project name, device name
- `ContentState` (nested in attributes) — **dynamic** fields that change on each update: status, current tool, turn count, elapsed time

### Activity Lifecycle
| Action | Local | Remote (APNs) |
|--------|-------|---------------|
| Start | `Activity.request(attributes:content:pushType:)` | Push-to-start token (iOS 17.2+) |
| Update | `activity.update(ActivityContent(state:staleDate:))` | APNs payload with `content-state` |
| End | `activity.end(content:dismissalPolicy:)` | APNs payload with `event: "end"` + `dismissal-date` |

### System Controls
- **`relevanceScore`** — Float, higher = more important. System uses this to pick which activity shows in Dynamic Island when multiple exist
- **`staleDate`** — Date after which content is considered stale. Check `context.isStale` in widget to show "Updating..." UI
- **`dismissalPolicy`** — `.default` (4hr), `.after(Date)`, `.immediate`. Controls how long ended activity stays visible on Lock Screen

### Authorization
```swift
let info = ActivityAuthorizationInfo()
info.areActivitiesEnabled        // user allows Live Activities
info.frequentPushesEnabled       // user allows frequent updates
// Observe changes:
for await enabled in info.activityEnablementUpdates { ... }
```

## Implementation Checklist

### 1. Xcode Setup
- Add **Widget Extension** target (if not present): File → New → Target → Widget Extension
- Enable **Push Notifications** capability on the main app target
- Add `NSSupportsLiveActivitiesFrequentUpdates = YES` to widget extension's `Info.plist` if needed
- The widget extension must import both `WidgetKit` and `ActivityKit`

### 2. Define Attributes + ContentState
```swift
import ActivityKit

struct SessionActivityAttributes: ActivityAttributes {
    // Static — set once at start
    let sessionId: String
    let projectName: String
    let deviceName: String

    struct ContentState: Codable, Hashable {
        let status: String        // running, waiting_permission, error, completed
        let currentTool: String?
        let turnCount: Int
        let elapsedSeconds: Int
        let agentCount: Int
    }
}
```
**Important:** `ContentState` must be `Codable & Hashable`. Keep it small — APNs payload limit is 4KB.

### 3. Start a Live Activity
```swift
let attributes = SessionActivityAttributes(
    sessionId: id, projectName: name, deviceName: device
)
let initialState = SessionActivityAttributes.ContentState(
    status: "running", currentTool: nil, turnCount: 0,
    elapsedSeconds: 0, agentCount: 1
)
let content = ActivityContent(state: initialState, staleDate: nil)

let activity = try Activity.request(
    attributes: attributes,
    content: content,
    pushType: .token   // enables remote updates
)

// Observe push token (async stream — token can change)
Task {
    for await tokenData in activity.pushTokenUpdates {
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        await apiClient.registerLiveActivityToken(sessionId: id, pushToken: token)
    }
}
```

### 4. Update Locally
```swift
let newState = SessionActivityAttributes.ContentState(
    status: "running", currentTool: "Read", turnCount: 5,
    elapsedSeconds: 120, agentCount: 1
)
let content = ActivityContent(
    state: newState,
    staleDate: Date().addingTimeInterval(300) // stale after 5min of no update
)
await activity.update(content)
```
**Throttle updates** — max ~1/second. Bypass throttle only for status changes.

### 5. End Locally
```swift
let finalState = SessionActivityAttributes.ContentState(
    status: "completed", currentTool: nil, turnCount: 12,
    elapsedSeconds: 340, agentCount: 1
)
let content = ActivityContent(state: finalState, staleDate: nil)
await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(300)))
```

### 6. Push Token Handling
- Token is an async stream — **it can change** during the activity's lifetime
- Always observe `activity.pushTokenUpdates` and forward new tokens to your server
- Token is `nil` until APNs assigns it; don't send updates before you have one
- On iOS 17.2+, also observe `Activity<T>.pushToStartTokenUpdates` for server-initiated starts

### 7. APNs Payload Structure

**Update payload:**
```json
{
    "aps": {
        "timestamp": 1234567890,
        "event": "update",
        "content-state": {
            "status": "running",
            "currentTool": "Edit",
            "turnCount": 7,
            "elapsedSeconds": 200,
            "agentCount": 1
        },
        "stale-date": 1234568190,
        "relevance-score": 100
    }
}
```

**End payload:**
```json
{
    "aps": {
        "timestamp": 1234567890,
        "event": "end",
        "dismissal-date": 1234568190,
        "content-state": {
            "status": "completed",
            "currentTool": null,
            "turnCount": 12,
            "elapsedSeconds": 340,
            "agentCount": 1
        }
    }
}
```

**APNs headers for liveactivity push:**
- `apns-push-type: liveactivity`
- `apns-topic: <bundle-id>.push-type.liveactivity`
- `apns-priority: 10` (high) or `5` (low/battery-friendly)

### 8. Priority & Throttling
- **High priority (10)**: immediate delivery, but Apple budgets these — can be throttled
- **Low priority (5)**: opportunistic, better for battery, effectively unlimited
- Use high priority for status changes, low for incremental progress
- If `NSSupportsLiveActivitiesFrequentUpdates` is enabled and user allows it, higher budget for high-priority pushes
- Check `ActivityAuthorizationInfo().frequentPushesEnabled` and adapt server send rate

## Widget Extension: Rendering UI

### ActivityConfiguration Structure
```swift
struct SessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            // LOCK SCREEN view
            lockScreenView(context: context)
                .activityBackgroundTint(.black.opacity(0.7))
                .widgetURL(URL(string: "afk://session/\(context.attributes.sessionId)")!)

        } dynamicIsland: { context in
            DynamicIsland {
                // EXPANDED regions
                DynamicIslandExpandedRegion(.leading) { /* project name */ }
                DynamicIslandExpandedRegion(.trailing) { /* status pill */ }
                DynamicIslandExpandedRegion(.bottom) { /* tool, stats */ }
            } compactLeading: {
                // Compact left — icon or short label
            } compactTrailing: {
                // Compact right — status indicator
            } minimal: {
                // Minimal — single icon/indicator (when multiple activities exist)
            }
        }
    }
}
```

### Dynamic Island Regions
| Region | Purpose | Size constraint |
|--------|---------|-----------------|
| `expanded.leading` | Primary label (project name) | ~half width |
| `expanded.trailing` | Status indicator | ~half width |
| `expanded.bottom` | Details (tool, stats, device) | Full width |
| `expanded.center` | Hero content (rarely used) | Full width |
| `compactLeading` | Left pill — icon or 1-2 chars | Very small |
| `compactTrailing` | Right pill — short status | Very small |
| `minimal` | Single activity indicator | Tiny circle |

### Status-Based Styling
Use semantic colors for status:
- Running → `.green`
- Waiting (permission/input) → `.orange`
- Error → `.red`
- Completed → `.gray`

### Stale Content Handling
```swift
if context.isStale {
    Text("Updating...")
        .foregroundStyle(.secondary)
}
```

## Broadcast Updates (iOS 18+)

For mass fan-out to many devices watching the same event:

```swift
// Client subscribes to a channel
let activity = try Activity.request(
    attributes: attributes,
    content: content,
    pushType: .channel("match-12345")
)
```

- One APNs request updates all subscribed activities
- Channels have storage policies: "No Storage" (live only) vs "Most Recent Message"
- Delete unused channels to stay within limits
- Use when: many users watch the same event (sports scores, flight status)
- Use per-activity tokens when: each user sees unique data

## Common Gotchas

1. **Push token is nil at first** — it's async. Don't try to send it before observing `pushTokenUpdates`
2. **Token rotation** — tokens can change mid-activity. Always observe the stream, not just the first value
3. **4KB payload limit** — `content-state` must be small. Don't embed large strings
4. **Throttling** — too many high-priority pushes get throttled silently. Use low priority for non-critical updates
5. **Widget extension is a separate target** — it can't access main app's classes directly. Share code via a shared framework or duplicate the `ActivityAttributes` definition
6. **`timestamp` is required** in APNs payload — system uses it to order updates and discard stale ones
7. **Activities expire after 8 hours** (12 hours on iOS 16.1) if not ended — system ends them automatically
8. **Max ~5 active activities** per app — system may deny new ones if limit exceeded
9. **User can disable** Live Activities per-app in Settings → always check `areActivitiesEnabled`
10. **Simulator limitations** — Dynamic Island only renders on supported device simulators (iPhone 14 Pro+)

## Reference Implementation (This Project)

- **Attributes**: `ios/AFK/Model/SessionActivityAttributes.swift`
- **Manager**: `ios/AFK/Services/LiveActivityManager.swift` — lifecycle, throttling, push token registration
- **Widget UI**: `ios/AFKWidgets/AFKWidgetsLiveActivity.swift` — Lock Screen + Dynamic Island layouts
- **Widget Bundle**: `ios/AFKWidgets/AFKWidgetsBundle.swift`
- **Integration**: `ios/AFK/Services/SessionStore.swift` — wires session status changes to Live Activity updates
- **App entry**: `ios/AFK/AFKApp.swift` — initializes manager, observes push-to-start tokens

## What to Build

$ARGUMENTS
