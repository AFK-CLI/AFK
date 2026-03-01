package push

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/AFK/afk-cloud/internal/db"
)

// EventPriority determines how an event should be handled for push notifications.
type EventPriority int

const (
	PrioritySuppressed EventPriority = iota // Never push (usage_update, text_delta, progress)
	PriorityRoutine                         // Aggregate over window, never push individually
	PriorityImportant                       // Push unless user is actively viewing session
	PriorityCritical                        // Always push immediately
)

const (
	aggregateWindow    = 2 * time.Minute
	firstErrorCooldown = 5 * time.Minute
	ringSize           = 16
	burstThreshold     = 5               // max pushes per user in burst window
	burstWindow        = 30 * time.Second // window for burst detection
)

// ClassifyEvent returns the push priority for a given event type.
func ClassifyEvent(eventType string) EventPriority {
	switch eventType {
	case "permission_needed":
		return PriorityCritical
	case "error_raised":
		return PriorityCritical // subject to first-error-only rule
	case "session_completed":
		return PriorityImportant
	case "turn_completed", "tool_finished":
		return PriorityRoutine
	case "turn_started", "tool_started", "session_started", "session_idle":
		return PriorityRoutine
	default:
		// usage_update, assistant_responding, text_delta, etc.
		return PrioritySuppressed
	}
}

// DecisionEngine adds intelligence to push notification dispatch.
// It wraps the Notifier and decides when to actually send pushes.
type DecisionEngine struct {
	notifier          *Notifier
	hasActiveIOSConns HasActiveIOSConnsFunc

	mu sync.Mutex

	// First-error tracking: only push the first error per session within cooldown.
	firstError map[string]time.Time // sessionID -> last error push time

	// Aggregate buffers for routine events (flushed after window or on critical event).
	aggregates map[string]*eventAggregate // sessionID -> pending aggregate

	// Ring buffer of recent push timestamps per user (for burst detection).
	recentPushes map[string]*pushRing // userID -> ring
}

type eventAggregate struct {
	userID    string
	sessionID string
	count     int
	files     map[string]bool // unique file names
	tools     map[string]int  // toolName -> count
	timer     *time.Timer
}

type pushRing struct {
	times [ringSize]time.Time
	idx   int
	count int
}

func (r *pushRing) add(t time.Time) {
	r.times[r.idx] = t
	r.idx = (r.idx + 1) % ringSize
	if r.count < ringSize {
		r.count++
	}
}

func (r *pushRing) countSince(since time.Time) int {
	n := 0
	for i := 0; i < r.count; i++ {
		if r.times[i].After(since) {
			n++
		}
	}
	return n
}

// NewDecisionEngine creates a new push decision engine.
func NewDecisionEngine(notifier *Notifier, hasActiveConns HasActiveIOSConnsFunc) *DecisionEngine {
	return &DecisionEngine{
		notifier:          notifier,
		hasActiveIOSConns: hasActiveConns,
		firstError:        make(map[string]time.Time),
		aggregates:        make(map[string]*eventAggregate),
		recentPushes:      make(map[string]*pushRing),
	}
}

// HandleSessionEvent is the main entry point for the decision engine.
// It classifies the event, applies rules, and decides whether to push.
func (d *DecisionEngine) HandleSessionEvent(userID, sessionID, eventType, deviceName string, data json.RawMessage) {
	priority := ClassifyEvent(eventType)

	switch priority {
	case PrioritySuppressed:
		return

	case PriorityCritical:
		// Flush any pending aggregate for this session (give context before the critical event).
		d.flushAggregate(sessionID)
		d.handleCritical(userID, sessionID, eventType, data)

	case PriorityImportant:
		d.flushAggregate(sessionID)
		d.handleImportant(userID, sessionID, eventType)

	case PriorityRoutine:
		d.addToAggregate(userID, sessionID, eventType, data)
	}
}

func (d *DecisionEngine) handleCritical(userID, sessionID, eventType string, data json.RawMessage) {
	switch eventType {
	case "error_raised":
		// First-error-only: suppress subsequent errors in same session within cooldown.
		d.mu.Lock()
		lastError, exists := d.firstError[sessionID]
		now := time.Now()
		if exists && now.Sub(lastError) < firstErrorCooldown {
			d.mu.Unlock()
			slog.Debug("suppressing duplicate error push", "session_id", sessionID, "last_push_ago", now.Sub(lastError).Round(time.Second))
			return
		}
		d.firstError[sessionID] = now
		d.mu.Unlock()

		// Check burst limit.
		if d.isBurst(userID) {
			slog.Debug("burst limit reached, suppressing error push", "user_id", userID)
			return
		}
		d.recordPush(userID)

		// Extract error message and delegate to notifier.
		var errData struct {
			ToolName  string `json:"toolName"`
			TurnIndex string `json:"turnIndex"`
		}
		var errorMsg string
		if err := json.Unmarshal(data, &errData); err == nil && errData.ToolName != "" {
			errorMsg = fmt.Sprintf("Tool '%s' failed (turn %s)", errData.ToolName, errData.TurnIndex)
		} else {
			errorMsg = "A tool encountered an error"
		}
		d.notifier.NotifySessionError(userID, sessionID, errorMsg)

	case "permission_needed":
		// Permission requests are always sent (handled by NotifyPermissionRequest directly).
		// This case shouldn't normally be reached since permissions use a separate path.
		slog.Warn("unexpected permission_needed routed through HandleSessionEvent")
	}
}

func (d *DecisionEngine) handleImportant(userID, sessionID, eventType string) {
	// Skip if user is actively viewing on iOS.
	if d.hasActiveIOSConns(userID) {
		slog.Debug("skipping push, user has active iOS connection", "user_id", userID, "event_type", eventType)
		return
	}

	// Check burst limit.
	if d.isBurst(userID) {
		slog.Debug("burst limit reached, suppressing push", "user_id", userID, "event_type", eventType)
		return
	}
	d.recordPush(userID)

	switch eventType {
	case "session_completed":
		d.notifier.NotifySessionCompleted(userID, sessionID)
	}
}

func (d *DecisionEngine) addToAggregate(userID, sessionID, eventType string, data json.RawMessage) {
	d.mu.Lock()
	defer d.mu.Unlock()

	agg, exists := d.aggregates[sessionID]
	if !exists {
		agg = &eventAggregate{
			userID:    userID,
			sessionID: sessionID,
			files:     make(map[string]bool),
			tools:     make(map[string]int),
		}
		d.aggregates[sessionID] = agg

		// Start flush timer.
		agg.timer = time.AfterFunc(aggregateWindow, func() {
			d.flushAggregate(sessionID)
		})
	}

	agg.count++

	// Extract tool/file info from data if available.
	var toolData struct {
		ToolName string `json:"toolName"`
		FilePath string `json:"filePath"`
	}
	if err := json.Unmarshal(data, &toolData); err == nil {
		if toolData.ToolName != "" {
			agg.tools[toolData.ToolName]++
		}
		if toolData.FilePath != "" {
			// Extract just the filename.
			name := toolData.FilePath
			for i := len(name) - 1; i >= 0; i-- {
				if name[i] == '/' {
					name = name[i+1:]
					break
				}
			}
			agg.files[name] = true
		}
	}
}

func (d *DecisionEngine) flushAggregate(sessionID string) {
	d.mu.Lock()
	agg, exists := d.aggregates[sessionID]
	if !exists {
		d.mu.Unlock()
		return
	}
	delete(d.aggregates, sessionID)
	if agg.timer != nil {
		agg.timer.Stop()
	}
	d.mu.Unlock()

	// Don't push routine aggregates if user is actively connected.
	if d.hasActiveIOSConns(agg.userID) {
		return
	}

	// Don't push if nothing meaningful accumulated.
	if agg.count == 0 {
		return
	}

	// Check session activity preference and quiet hours.
	if !d.notifier.CheckSessionActivityPrefs(agg.userID) {
		return
	}

	// Check burst limit.
	if d.isBurst(agg.userID) {
		return
	}

	// Build aggregate notification.
	body := d.composeAggregateBody(agg)
	if body == "" {
		return
	}

	d.recordPush(agg.userID)

	tokens, err := db.ListPushTokensByUser(d.notifier.database, agg.userID)
	if err != nil {
		slog.Error("failed to list push tokens for aggregate", "user_id", agg.userID, "error", err)
		return
	}

	data := map[string]string{
		"sessionId": agg.sessionID,
		"deepLink":  fmt.Sprintf("afk://session/%s", agg.sessionID),
	}
	d.notifier.sendToAllThreaded(tokens, "Session Activity", body, "session_activity", data, agg.sessionID)
}

func (d *DecisionEngine) composeAggregateBody(agg *eventAggregate) string {
	if agg.count < 5 {
		// Too few events to aggregate — not worth a push.
		return ""
	}

	// Compose something like: "5 tool completions — file1.swift, file2.go"
	var parts []string

	// Summarize tools.
	totalTools := 0
	for _, count := range agg.tools {
		totalTools += count
	}
	if totalTools > 0 {
		parts = append(parts, fmt.Sprintf("%d tool completions", totalTools))
	} else {
		parts = append(parts, fmt.Sprintf("%d events", agg.count))
	}

	// List files (max 3).
	if len(agg.files) > 0 {
		fileList := make([]string, 0, len(agg.files))
		for f := range agg.files {
			fileList = append(fileList, f)
			if len(fileList) >= 3 {
				break
			}
		}
		fileSummary := ""
		for i, f := range fileList {
			if i > 0 {
				fileSummary += ", "
			}
			fileSummary += f
		}
		if len(agg.files) > 3 {
			fileSummary += fmt.Sprintf(", +%d more", len(agg.files)-3)
		}
		parts = append(parts, fileSummary)
	}

	result := ""
	for i, p := range parts {
		if i > 0 {
			result += " — "
		}
		result += p
	}
	return result
}

func (d *DecisionEngine) isBurst(userID string) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	ring, exists := d.recentPushes[userID]
	if !exists {
		return false
	}
	return ring.countSince(time.Now().Add(-burstWindow)) >= burstThreshold
}

func (d *DecisionEngine) recordPush(userID string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	ring, exists := d.recentPushes[userID]
	if !exists {
		ring = &pushRing{}
		d.recentPushes[userID] = ring
	}
	ring.add(time.Now())
}

// CleanupSession removes all tracked state for a session (call on session completion).
func (d *DecisionEngine) CleanupSession(sessionID string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	delete(d.firstError, sessionID)
	if agg, exists := d.aggregates[sessionID]; exists {
		if agg.timer != nil {
			agg.timer.Stop()
		}
		delete(d.aggregates, sessionID)
	}
}
