package push

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
)

// HasActiveIOSConns is a function provided by the hub to check if a user has active iOS WS connections.
type HasActiveIOSConnsFunc func(userID string) bool

const liveActivityRateLimit = 10 * time.Second

// Notifier evaluates when to send push notifications and dispatches them.
type Notifier struct {
	apns              *APNsClient
	database          *sql.DB
	hasActiveIOSConns HasActiveIOSConnsFunc

	// Rate limiting: max 1 push per session per 30s for non-permission events.
	mu        sync.Mutex
	lastPush  map[string]time.Time // sessionID -> last push time

	// Live Activity push tokens (in-memory, ephemeral).
	laMu       sync.RWMutex
	laTokens   map[string]string    // sessionID -> LA push token
	laLastPush map[string]time.Time // sessionID -> last LA push time

	// Push-to-start tracking: prevents re-sending for the same session.
	ptsMu        sync.Mutex
	ptsAttempted map[string]bool // sessionID -> attempted
}

// NewNotifier creates a new push notification evaluator.
func NewNotifier(apns *APNsClient, database *sql.DB, hasActiveConns HasActiveIOSConnsFunc) *Notifier {
	return &Notifier{
		apns:              apns,
		database:          database,
		hasActiveIOSConns: hasActiveConns,
		lastPush:          make(map[string]time.Time),
		laTokens:          make(map[string]string),
		laLastPush:        make(map[string]time.Time),
		ptsAttempted:      make(map[string]bool),
	}
}

// NotifyPermissionRequest sends a push for permission requests (always, time-sensitive).
func (n *Notifier) NotifyPermissionRequest(userID string, req model.PermissionRequest) {
	// Check notification preferences.
	prefs, err := db.GetNotificationPrefs(n.database, userID)
	if err != nil {
		slog.Warn("failed to get notification prefs", "user_id", userID, "error", err)
		// Continue anyway — permission requests are critical.
	} else if !prefs.PermissionRequests {
		slog.Info("permission request notifications disabled", "user_id", userID)
		return
	}

	if n.isQuietHours(prefs) {
		slog.Info("quiet hours active, still sending permission push", "user_id", userID)
		// Still send for permission requests — they're time-sensitive.
	}

	tokens, err := db.ListPushTokensByUser(n.database, userID)
	if err != nil {
		slog.Error("failed to list push tokens", "user_id", userID, "error", err)
		return
	}

	// Include full permission request data so the app can reconstruct the overlay on tap.
	toolInputJSON, _ := json.Marshal(req.ToolInput)
	data := map[string]string{
		"sessionId": req.SessionID,
		"deepLink":  fmt.Sprintf("afk://session/%s", req.SessionID),
		"nonce":     req.Nonce,
		"toolName":  req.ToolName,
		"toolInput": string(toolInputJSON),
		"expiresAt": fmt.Sprintf("%d", req.ExpiresAt),
		"deviceId":  req.DeviceID,
		"toolUseId": req.ToolUseID,
	}
	if req.Challenge != "" {
		data["challenge"] = req.Challenge
	}

	// AskUserQuestion: show the question text, not "approve/deny"
	var title, body, category string
	if req.ToolName == "AskUserQuestion" {
		title = "Question from Claude"
		// Extract the first question text from toolInput
		if questions, ok := req.ToolInput["questions"]; ok {
			var qs []struct{ Question string `json:"question"` }
			if err := json.Unmarshal([]byte(questions), &qs); err == nil && len(qs) > 0 {
				body = qs[0].Question
			}
		}
		if body == "" {
			body = "Claude has a question for you"
		}
		category = "ask_user_question"
	} else {
		title = "Permission Required"
		body = fmt.Sprintf("%s needs approval", req.ToolName)
		category = "permission_request"
	}

	// Thread-id groups notifications per session on iOS lock screen.
	threadID := ""
	if sid, ok := data["sessionId"]; ok {
		threadID = sid
	}

	for _, token := range tokens {
		if err := n.apns.SendNotification(token.DeviceToken, title, body, category, threadID, data); err != nil {
			if apnsErr, ok := err.(*APNsError); ok && (apnsErr.StatusCode == 410 || apnsErr.StatusCode == 400) {
				slog.Warn("removing invalid push token", "device_token", token.DeviceToken[:8], "status", apnsErr.StatusCode)
				_ = db.DeletePushTokenByToken(n.database, token.DeviceToken)
			} else {
				slog.Error("failed to send push notification", "device_token", token.DeviceToken[:8], "error", err)
			}
		}
	}
}

// NotifySessionError sends a push for session errors (only if no active iOS WS connections).
func (n *Notifier) NotifySessionError(userID, sessionID, errorMsg string) {
	if n.hasActiveIOSConns(userID) {
		return
	}

	if !n.checkPrefsAndRate(userID, sessionID, func(p *model.NotificationPrefs) bool { return p.SessionErrors }) {
		return
	}

	tokens, err := db.ListPushTokensByUser(n.database, userID)
	if err != nil {
		slog.Error("failed to list push tokens", "user_id", userID, "error", err)
		return
	}

	title := "Session Error"
	body := errorMsg
	if len(body) > 100 {
		body = body[:100] + "..."
	}
	data := map[string]string{
		"sessionId": sessionID,
		"deepLink":  fmt.Sprintf("afk://session/%s", sessionID),
	}

	n.sendToAll(tokens, title, body, "session_error", data)
}

// NotifySessionCompleted sends a push when a session completes (only if no active iOS WS connections).
func (n *Notifier) NotifySessionCompleted(userID, sessionID string) {
	if n.hasActiveIOSConns(userID) {
		return
	}

	if !n.checkPrefsAndRate(userID, sessionID, func(p *model.NotificationPrefs) bool { return p.SessionCompletions }) {
		return
	}

	tokens, err := db.ListPushTokensByUser(n.database, userID)
	if err != nil {
		slog.Error("failed to list push tokens", "user_id", userID, "error", err)
		return
	}

	title := "Session Completed"
	body := "Your Claude session has finished"
	data := map[string]string{
		"sessionId": sessionID,
		"deepLink":  fmt.Sprintf("afk://session/%s", sessionID),
	}

	n.sendToAll(tokens, title, body, "session_completed", data)
}

func (n *Notifier) NotifySessionStopped(userID, sessionID, lastMessage string) {
	if n.hasActiveIOSConns(userID) {
		return
	}

	if !n.checkPrefsAndRate(userID, sessionID, func(p *model.NotificationPrefs) bool { return p.SessionCompletions }) {
		return
	}

	tokens, err := db.ListPushTokensByUser(n.database, userID)
	if err != nil {
		slog.Error("failed to list push tokens", "user_id", userID, "error", err)
		return
	}

	title := "Claude Stopped"
	body := "Claude has finished responding"
	if lastMessage != "" {
		// Truncate to keep push payload small
		if len(lastMessage) > 200 {
			lastMessage = lastMessage[:200] + "..."
		}
		body = lastMessage
	}
	data := map[string]string{
		"sessionId": sessionID,
		"deepLink":  fmt.Sprintf("afk://session/%s", sessionID),
	}
	n.sendToAll(tokens, title, body, "session_stopped", data)
}

func (n *Notifier) NotifyIdlePrompt(userID, sessionID, message string) {
	if n.hasActiveIOSConns(userID) {
		return
	}

	if !n.checkPrefsAndRate(userID, sessionID, func(p *model.NotificationPrefs) bool { return p.PermissionRequests }) {
		return
	}

	tokens, err := db.ListPushTokensByUser(n.database, userID)
	if err != nil {
		slog.Error("failed to list push tokens", "user_id", userID, "error", err)
		return
	}

	title := "Claude Needs Attention"
	body := message
	if body == "" {
		body = "Claude is waiting for input"
	}
	data := map[string]string{
		"sessionId": sessionID,
		"deepLink":  fmt.Sprintf("afk://session/%s", sessionID),
	}
	n.sendToAll(tokens, title, body, "idle_prompt", data)
}

// checkPrefsAndRate checks notification preferences and rate limiting.
func (n *Notifier) checkPrefsAndRate(userID, sessionID string, prefCheck func(*model.NotificationPrefs) bool) bool {
	prefs, err := db.GetNotificationPrefs(n.database, userID)
	if err != nil {
		slog.Warn("failed to get notification prefs", "user_id", userID, "error", err)
		return true // Default to sending on error.
	}

	if !prefCheck(prefs) {
		return false
	}

	if n.isQuietHours(prefs) {
		return false
	}

	// Rate limit: max 1 push per session per 30s.
	n.mu.Lock()
	defer n.mu.Unlock()
	if last, ok := n.lastPush[sessionID]; ok && time.Since(last) < 30*time.Second {
		return false
	}
	n.lastPush[sessionID] = time.Now()
	return true
}

func (n *Notifier) isQuietHours(prefs *model.NotificationPrefs) bool {
	if prefs == nil || prefs.QuietHoursStart == "" || prefs.QuietHoursEnd == "" {
		return false
	}

	now := time.Now()
	start, err1 := time.Parse("15:04", prefs.QuietHoursStart)
	end, err2 := time.Parse("15:04", prefs.QuietHoursEnd)
	if err1 != nil || err2 != nil {
		return false
	}

	currentMinutes := now.Hour()*60 + now.Minute()
	startMinutes := start.Hour()*60 + start.Minute()
	endMinutes := end.Hour()*60 + end.Minute()

	if startMinutes <= endMinutes {
		// Same day range (e.g., 08:00 - 22:00)
		return currentMinutes >= startMinutes && currentMinutes < endMinutes
	}
	// Overnight range (e.g., 22:00 - 08:00)
	return currentMinutes >= startMinutes || currentMinutes < endMinutes
}

func (n *Notifier) sendToAll(tokens []model.PushToken, title, body, category string, data map[string]string) {
	threadID := ""
	if sid, ok := data["sessionId"]; ok {
		threadID = sid
	}
	n.sendToAllThreaded(tokens, title, body, category, data, threadID)
}

func (n *Notifier) sendToAllThreaded(tokens []model.PushToken, title, body, category string, data map[string]string, threadID string) {
	for _, token := range tokens {
		if err := n.apns.SendNotification(token.DeviceToken, title, body, category, threadID, data); err != nil {
			if apnsErr, ok := err.(*APNsError); ok && (apnsErr.StatusCode == 410 || apnsErr.StatusCode == 400) {
				slog.Warn("removing invalid push token", "device_token", token.DeviceToken[:8], "status", apnsErr.StatusCode)
				_ = db.DeletePushTokenByToken(n.database, token.DeviceToken)
			} else {
				slog.Error("failed to send push notification", "device_token", token.DeviceToken[:8], "error", err)
			}
		}
	}
}

// CheckSessionActivityPrefs checks whether session activity notifications are
// enabled for the given user and whether quiet hours are active.
func (n *Notifier) CheckSessionActivityPrefs(userID string) bool {
	prefs, err := db.GetNotificationPrefs(n.database, userID)
	if err != nil {
		slog.Warn("failed to get notification prefs for session activity", "user_id", userID, "error", err)
		return false // Default to NOT sending session activity on error (it's noisy).
	}
	if !prefs.SessionActivity {
		return false
	}
	if n.isQuietHours(prefs) {
		return false
	}
	return true
}

// RegisterLiveActivityToken stores a Live Activity push token for a session.
func (n *Notifier) RegisterLiveActivityToken(sessionID, pushToken string) {
	n.laMu.Lock()
	defer n.laMu.Unlock()
	n.laTokens[sessionID] = pushToken
	slog.Info("registered live activity token", "session_id", sessionID)
}

// DeregisterLiveActivityToken removes a Live Activity push token for a session.
func (n *Notifier) DeregisterLiveActivityToken(sessionID string) {
	n.laMu.Lock()
	delete(n.laTokens, sessionID)
	delete(n.laLastPush, sessionID)
	n.laMu.Unlock()

	n.ptsMu.Lock()
	delete(n.ptsAttempted, sessionID)
	n.ptsMu.Unlock()
}

// TryPushToStartLiveActivity sends a push-to-start Live Activity if:
// - Not already attempted for this session
// - No per-activity LA token registered (app hasn't started it locally)
// - User has a push-to-start token in DB
func (n *Notifier) TryPushToStartLiveActivity(userID, sessionID, projectName, deviceName string) {
	// Skip if already attempted for this session.
	n.ptsMu.Lock()
	if n.ptsAttempted[sessionID] {
		n.ptsMu.Unlock()
		return
	}
	n.ptsAttempted[sessionID] = true
	n.ptsMu.Unlock()

	// Skip if per-activity LA token already registered (app started it locally).
	n.laMu.RLock()
	_, hasLAToken := n.laTokens[sessionID]
	n.laMu.RUnlock()
	if hasLAToken {
		slog.Debug("push-to-start skipped, per-activity token exists", "session_id", sessionID)
		return
	}

	// Look up user's push-to-start token from DB.
	token, err := db.GetPushToStartToken(n.database, userID)
	if err != nil {
		slog.Warn("no push-to-start token found", "user_id", userID, "error", err)
		return
	}

	slog.Info("sending push-to-start live activity", "session_id", sessionID, "user_id", userID)
	if err := n.apns.SendLiveActivityStart(token, sessionID, projectName, deviceName); err != nil {
		if apnsErr, ok := err.(*APNsError); ok && apnsErr.StatusCode == 410 {
			slog.Warn("push-to-start token expired, removing", "user_id", userID)
			_ = db.DeletePushToStartToken(n.database, userID)
		} else {
			slog.Error("push-to-start live activity failed", "session_id", sessionID, "error", err)
		}
	}
}

// NotifyLiveActivityUpdate sends a push to update a Live Activity for a session.
func (n *Notifier) NotifyLiveActivityUpdate(sessionID, status, currentTool string, turnCount, elapsedSeconds int) {
	n.laMu.RLock()
	token, exists := n.laTokens[sessionID]
	n.laMu.RUnlock()
	if !exists {
		return
	}

	// Rate limit: max 1 push per session per 10 seconds.
	n.laMu.Lock()
	if last, ok := n.laLastPush[sessionID]; ok && time.Since(last) < liveActivityRateLimit {
		n.laMu.Unlock()
		return
	}
	n.laLastPush[sessionID] = time.Now()
	n.laMu.Unlock()

	contentState := map[string]interface{}{
		"status":         status,
		"currentTool":    currentTool,
		"turnCount":      turnCount,
		"elapsedSeconds": elapsedSeconds,
	}

	isEnd := status == "completed" || status == "error"
	var err error
	if isEnd {
		err = n.apns.SendLiveActivityEnd(token, contentState)
		n.DeregisterLiveActivityToken(sessionID)
	} else {
		err = n.apns.SendLiveActivityUpdate(token, contentState)
	}

	if err != nil {
		if apnsErr, ok := err.(*APNsError); ok && apnsErr.StatusCode == 410 {
			slog.Warn("live activity token expired, removing", "session_id", sessionID)
			n.DeregisterLiveActivityToken(sessionID)
		} else {
			slog.Error("live activity push failed", "session_id", sessionID, "error", err)
		}
	}
}
