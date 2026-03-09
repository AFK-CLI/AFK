package ws

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
	"github.com/gorilla/websocket"
)

const (
	agentWriteWait  = 10 * time.Second
	agentPongWait   = 60 * time.Second
	agentPingPeriod = (agentPongWait * 9) / 10
	maxMessageSize  = 512 * 1024
)

// allowedWSOrigins holds configured origins for WebSocket connections.
// Set via AFK_WS_ALLOWED_ORIGINS env var (comma-separated).
// Empty origin (native apps) is always accepted.
var allowedWSOrigins []string

// InitWSOrigins sets the allowed WebSocket origins from a comma-separated string.
func InitWSOrigins(origins string) {
	if origins == "" {
		return
	}
	for _, o := range strings.Split(origins, ",") {
		if t := strings.TrimSpace(o); t != "" {
			allowedWSOrigins = append(allowedWSOrigins, t)
		}
	}
}

var upgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
	CheckOrigin: func(r *http.Request) bool {
		origin := r.Header.Get("Origin")
		// Native apps (iOS, macOS agent) typically send no Origin header.
		if origin == "" {
			return true
		}
		// Check against configured allowed origins.
		for _, allowed := range allowedWSOrigins {
			if origin == allowed {
				return true
			}
		}
		slog.Warn("WebSocket connection rejected: origin not allowed", "origin", origin)
		return false
	},
}

func ServeAgentWS(hub *Hub, database *sql.DB, secret string, ticketStore *auth.TicketStore) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var userID, deviceID string

		// Authenticate via ws_ticket only.
		wsTicket := r.URL.Query().Get("ws_ticket")
		if wsTicket == "" {
			http.Error(w, `{"error":"missing ws_ticket"}`, http.StatusUnauthorized)
			return
		}
		ticket, err := ticketStore.Redeem(wsTicket)
		if err != nil {
			http.Error(w, `{"error":"invalid or expired ws_ticket"}`, http.StatusUnauthorized)
			return
		}
		userID = ticket.UserID
		deviceID = ticket.DeviceID

		// Verify device exists and is not revoked.
		device, err := db.GetDevice(database, deviceID)
		if err != nil || device.IsRevoked {
			http.Error(w, `{"error":"device not found or revoked"}`, http.StatusForbidden)
			return
		}

		// Use the device's actual owner (handles dev→Apple user migration).
		if device.UserID != userID {
			slog.Warn("agent device JWT user differs from device owner, using device owner",
				"device_id", deviceID, "jwt_user_id", userID, "device_owner_id", device.UserID)
			userID = device.UserID
		}

		slog.Info("upgrading agent connection", "device_id", deviceID, "user_id", userID)
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			slog.Error("ws upgrade failed", "error", err)
			return
		}

		slog.Info("agent connected", "device_id", deviceID)
		ac := hub.RegisterAgent(deviceID, userID, conn)

		// Mark device online.
		_ = db.UpdateDeviceStatus(database, deviceID, true, time.Now())

		// Broadcast device online to iOS clients.
		statusMsg, _ := NewWSMessage("device.status", model.DeviceStatusNotification{
			DeviceID:   deviceID,
			DeviceName: device.Name,
			IsOnline:   true,
		})
		hub.BroadcastToUser(userID, statusMsg)

		go agentWritePump(ac)
		go agentReadPump(hub, ac, database, userID, deviceID, device.Name)
	}
}

func agentReadPump(hub *Hub, ac *AgentConn, database *sql.DB, userID, deviceID, deviceName string) {
	slog.Info("read pump started", "device_id", deviceID)
	defer func() {
		hub.UnregisterAgent(deviceID)
		ac.Conn.Close()

		// Mark device offline.
		_ = db.UpdateDeviceStatus(database, deviceID, false, time.Now())

		// Broadcast device offline.
		statusMsg, _ := NewWSMessage("device.status", model.DeviceStatusNotification{
			DeviceID:   deviceID,
			DeviceName: deviceName,
			IsOnline:   false,
		})
		hub.BroadcastToUser(userID, statusMsg)

		// Mark all running sessions for this device as idle.
		// Use idle (not completed) because the session may resume when
		// the agent reconnects.
		runningSessions, err := db.ListRunningSessionsByDevice(database, deviceID)
		if err == nil && len(runningSessions) > 0 {
			slog.Info("agent disconnected, marking running sessions idle",
				"device_id", deviceID, "count", len(runningSessions))
			for _, sid := range runningSessions {
				if err := db.UpdateSessionStatus(database, sid, model.StatusIdle); err != nil {
					slog.Error("failed to mark session idle on disconnect",
						"session_id", sid, "device_id", deviceID, "error", err)
					continue
				}
				// Broadcast updated session to iOS clients.
				if session, err := db.GetSession(database, sid); err == nil {
					notification, _ := NewWSMessage("session.update", model.SessionUpdateNotification{
						Session:    session,
						DeviceName: deviceName,
					})
					hub.BroadcastToUser(userID, notification)
				}
			}
		}
	}()

	ac.Conn.SetReadLimit(maxMessageSize)
	ac.Conn.SetReadDeadline(time.Now().Add(agentPongWait))
	ac.Conn.SetPongHandler(func(string) error {
		ac.Conn.SetReadDeadline(time.Now().Add(agentPongWait))
		return nil
	})

	for {
		_, data, err := ac.Conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
				slog.Error("ws read error", "device_id", deviceID, "error", err)
			}
			slog.Info("read pump ending", "device_id", deviceID)
			return
		}

		slog.Debug("ws message received", "device_id", deviceID, "bytes", len(data))

		msg, err := ParseWSMessage(data)
		if err != nil {
			slog.Error("ws message parse error", "device_id", deviceID, "error", err)
			continue
		}

		handleAgentMessage(hub, database, userID, deviceID, deviceName, msg)
	}
}

func handleAgentMessage(hub *Hub, database *sql.DB, userID, deviceID, deviceName string, msg *model.WSMessage) {
	switch msg.Type {
	case "agent.heartbeat":
		var hb model.AgentHeartbeat
		if err := json.Unmarshal(msg.Payload, &hb); err != nil {
			slog.Error("parse heartbeat failed", "device_id", deviceID, "error", err)
			return
		}
		_ = db.UpdateDeviceStatus(database, deviceID, true, time.Now())

		// Reconcile: mark sessions idle if agent no longer reports them as active.
		reconcileSessionsFromHeartbeat(database, deviceID, hb.ActiveSessions)

	case "agent.session.update":
		var update model.AgentSessionUpdate
		if err := json.Unmarshal(msg.Payload, &update); err != nil {
			slog.Error("parse session update failed", "device_id", deviceID, "error", err)
			return
		}

		// Enforce length limits on agent-provided fields.
		if len(update.ProjectPath) > 1024 {
			update.ProjectPath = update.ProjectPath[:1024]
		}
		if len(update.GitBranch) > 256 {
			update.GitBranch = update.GitBranch[:256]
		}
		if len(update.CWD) > 1024 {
			update.CWD = update.CWD[:1024]
		}
		if len(update.Description) > 4096 {
			update.Description = update.Description[:4096]
		}

		now := time.Now()

		// Auto-create project from project_path if available.
		projectID := db.EnsureProjectForSession(database, userID, update.ProjectPath)

		session := &model.Session{
			ID:                 update.SessionID,
			DeviceID:           deviceID,
			UserID:             userID,
			ProjectPath:        update.ProjectPath,
			GitBranch:          update.GitBranch,
			CWD:                update.CWD,
			Status:             model.SessionStatus(update.Status),
			StartedAt:          now,
			UpdatedAt:          now,
			TokensIn:           update.TokensIn,
			TokensOut:          update.TokensOut,
			TurnCount:          update.TurnCount,
			ProjectID:          projectID,
			Description:        update.Description,
			EphemeralPublicKey: update.EphemeralPublicKey,
			LastInputTokens:    update.LastInputTokens,
		}
		if err := db.UpsertSession(database, session); err != nil {
			slog.Error("upsert session failed", "session_id", session.ID, "device_id", deviceID, "error", err)
			return
		}
		slog.Info("session upserted",
			"session_id", session.ID, "status", session.Status, "project_path", update.ProjectPath,
			"project_id", projectID, "user_id", userID, "device_id", deviceID)

		// Fan out to iOS.
		notification, _ := NewWSMessage("session.update", model.SessionUpdateNotification{
			Session:    session,
			DeviceName: deviceName,
		})
		hub.BroadcastToUser(userID, notification)

		// Live Activity push update on session status changes.
		if hub.Notifier != nil {
			elapsed := int(time.Since(session.StartedAt).Seconds())
			go hub.Notifier.NotifyLiveActivityUpdate(
				update.SessionID, update.Status, "", update.TurnCount, elapsed,
			)

			// Push-to-start: when a session starts running, try to create a
			// Live Activity remotely (for when the iOS app is not open).
			if update.Status == "running" {
				projectName := update.ProjectPath
				for i := len(projectName) - 1; i >= 0; i-- {
					if projectName[i] == '/' {
						projectName = projectName[i+1:]
						break
					}
				}
				go hub.Notifier.TryPushToStartLiveActivity(userID, update.SessionID, projectName, deviceName)
			}
		}

	case "agent.session.event":
		// Validate event payload before processing.
		if err := ValidateEventPayload(msg.Payload); err != nil {
			slog.Error("event validation failed", "device_id", deviceID, "error", err)
			return
		}

		var evt model.AgentSessionEvent
		if err := json.Unmarshal(msg.Payload, &evt); err != nil {
			slog.Error("parse session event failed", "device_id", deviceID, "error", err)
			return
		}

		// Ensure session row exists before inserting event (FK constraint).
		// Use EnsureSession (INSERT OR IGNORE) to avoid overwriting
		// metadata that was set by a prior session.update message.
		now := time.Now()
		_ = db.EnsureSession(database, &model.Session{
			ID:        evt.SessionID,
			DeviceID:  deviceID,
			UserID:    userID,
			Status:    model.StatusRunning,
			StartedAt: now,
			UpdatedAt: now,
		})

		// Privacy mode enforcement.
		privacyMode, err := db.GetDevicePrivacyMode(database, deviceID)
		if err != nil {
			slog.Warn("failed to get privacy mode, defaulting to full storage", "device_id", deviceID, "error", err)
			privacyMode = ""
		}

		skipDB := false
		dbPayload := evt.Data    // payload to store in DB (may be stripped for telemetry_only)
		var dbContent json.RawMessage // content to store in DB (nil for telemetry_only)

		switch privacyMode {
		case "relay_only":
			// Forward to iOS but do NOT persist to DB.
			skipDB = true
			slog.Info("privacy relay_only: skipping DB storage for event", "device_id", deviceID)

		case "telemetry_only":
			// Agent puts metadata in Data, redacted snippets in Content.
			// Content is already secret-stripped by the agent's redaction pipeline —
			// safe to store for REST retrieval.
			dbContent = evt.Content

		case "encrypted":
			// Store as-is; agent handles encryption on its end.
			dbContent = evt.Content
			slog.Debug("privacy encrypted: storing encrypted payload as-is", "device_id", deviceID)

		default:
			// No privacy mode set or unknown — store everything including content.
			dbContent = evt.Content
		}

		var eventID string
		var eventSeq int
		if !skipDB {
			event := &model.SessionEvent{
				ID:        auth.GenerateID(),
				SessionID: evt.SessionID,
				DeviceID:  deviceID,
				EventType: evt.EventType,
				Timestamp: now,
				Payload:   dbPayload,
				Content:   dbContent,
				Seq:       evt.Seq,
				CreatedAt: now,
			}
			if err := db.InsertEvent(database, event); err != nil {
				slog.Error("insert event failed", "session_id", evt.SessionID, "device_id", deviceID, "error", err)
			}
			eventID = event.ID
			eventSeq = event.Seq
		} else {
			eventID = auth.GenerateID()
		}

		// Forward full (unstripped) event to iOS, including Content field.
		// Include event ID and seq so iOS can deduplicate against REST-fetched events.
		notification, _ := NewWSMessage("session.event", model.SessionEventNotification{
			ID:         eventID,
			Seq:        eventSeq,
			SessionID:  evt.SessionID,
			EventType:  evt.EventType,
			Data:       evt.Data,
			Content:    evt.Content,
			DeviceName: deviceName,
		})
		hub.BroadcastToUser(userID, notification)

		// LiveActivity update for tool_started events.
		if evt.EventType == "tool_started" && hub.Notifier != nil {
			var toolData struct {
				ToolName        string `json:"toolName"`
				ToolDescription string `json:"toolDescription"`
			}
			if err := json.Unmarshal(evt.Data, &toolData); err == nil && toolData.ToolName != "" {
				// Use agent-computed description (no server-side parsing needed)
				desc := toolData.ToolDescription
				if desc == "" {
					desc = toolData.ToolName
				}
				elapsed := 0
				if session, err := db.GetSession(database, evt.SessionID); err == nil {
					elapsed = int(time.Since(session.StartedAt).Seconds())
				}
				go hub.Notifier.NotifyLiveActivityUpdate(evt.SessionID, "running", desc, 0, elapsed)
			}
		}

		// Push notification for error events — routed through decision engine.
		if evt.EventType == "error_raised" && hub.Notifier != nil {
			go hub.Notifier.NotifyLiveActivityUpdate(evt.SessionID, "error", "", 0, 0)
		}

		// Extract task state from TaskCreate/TaskUpdate tool events.
		if evt.EventType == "tool_started" {
			go ProcessTaskEvent(hub, database, userID, evt.SessionID, evt.Data, evt.Content)
		}

		// Route all session events through decision engine for intelligent push.
		if hub.Decision != nil {
			go hub.Decision.HandleSessionEvent(userID, evt.SessionID, evt.EventType, deviceName, evt.Data)
		}

		// Audit log: record content relay with hash of payload (never raw content).
		if privacyMode == "relay_only" || privacyMode == "telemetry_only" {
			hash := sha256.Sum256(evt.Data)
			contentHash := hex.EncodeToString(hash[:])
			details := fmt.Sprintf(`{"session_id":%q,"event_type":%q,"privacy_mode":%q}`, evt.SessionID, evt.EventType, privacyMode)
			_ = db.InsertAuditLog(database, &model.AuditLogEntry{
				UserID:      userID,
				DeviceID:    deviceID,
				Action:      "content_relay",
				Details:     details,
				ContentHash: contentHash,
			})
		}

	case "agent.usage.update":
		var usage model.AgentUsageUpdate
		if err := json.Unmarshal(msg.Payload, &usage); err != nil {
			slog.Error("parse usage update failed", "device_id", deviceID, "error", err)
			return
		}
		usage.DeviceID = deviceID
		notification, err := NewWSMessage("agent.usage.update", struct {
			model.AgentUsageUpdate
			DeviceName string `json:"deviceName"`
		}{usage, deviceName})
		if err != nil {
			slog.Error("marshal usage update failed", "device_id", deviceID, "error", err)
			return
		}
		hub.BroadcastToUser(userID, notification)
		hub.CacheUsageState(deviceID, notification)
		slog.Info("broadcast usage update", "device_id", deviceID, "session_pct", usage.SessionPercentage, "weekly_pct", usage.WeeklyPercentage)

	case "agent.control_state":
		var state model.AgentControlState
		if err := json.Unmarshal(msg.Payload, &state); err != nil {
			slog.Error("parse agent control state failed", "device_id", deviceID, "error", err)
			return
		}
		state.DeviceID = deviceID
		notification, err := NewWSMessage("agent.control_state", state)
		if err != nil {
			slog.Error("marshal agent control state failed", "device_id", deviceID, "error", err)
			return
		}
		hub.BroadcastToUser(userID, notification)
		hub.CacheControlState(deviceID, notification)
		slog.Info("broadcast agent control state", "device_id", deviceID, "remote_approval", state.RemoteApproval, "auto_plan_exit", state.AutoPlanExit)

	case "agent.permission_request":
		var req model.PermissionRequest
		if err := json.Unmarshal(msg.Payload, &req); err != nil {
			slog.Error("parse permission request failed", "device_id", deviceID, "error", err)
			return
		}
		// Forward to all iOS clients for this user
		notification, err := NewWSMessage("session.permission_request", req)
		if err != nil {
			slog.Error("marshal permission request failed", "device_id", deviceID, "error", err)
			return
		}
		hub.BroadcastToUser(userID, notification)
		slog.Info("forwarded permission request to iOS", "tool_name", req.ToolName, "nonce", req.Nonce)

		// Send push notification for permission requests.
		if hub.Notifier != nil {
			go hub.Notifier.NotifyPermissionRequest(userID, req)
		}

	case "agent.notification":
		var notif struct {
			SessionID        string `json:"sessionId"`
			NotificationType string `json:"notificationType"`
			Message          string `json:"message,omitempty"`
		}
		if err := json.Unmarshal(msg.Payload, &notif); err != nil {
			slog.Error("parse agent notification failed", "device_id", deviceID, "error", err)
			return
		}
		notification, _ := NewWSMessage("session.notification", notif)
		hub.BroadcastToUser(userID, notification)
		slog.Info("agent notification forwarded", "type", notif.NotificationType, "session_id", notif.SessionID)

		// Idle/permission prompts must bypass DecisionEngine (which suppresses unknown event types).
		if hub.Notifier != nil && (notif.NotificationType == "idle_prompt" || notif.NotificationType == "permission_prompt") {
			go hub.Notifier.NotifyIdlePrompt(userID, notif.SessionID, notif.Message)
		} else if hub.Decision != nil {
			data, _ := json.Marshal(map[string]string{"notificationType": notif.NotificationType, "message": notif.Message})
			go hub.Decision.HandleSessionEvent(userID, notif.SessionID, "notification", deviceName, data)
		}

	case "agent.session.stopped":
		var stopped struct {
			SessionID           string `json:"sessionId"`
			LastAssistantMessage string `json:"lastAssistantMessage,omitempty"`
		}
		if err := json.Unmarshal(msg.Payload, &stopped); err != nil {
			slog.Error("parse session stopped failed", "device_id", deviceID, "error", err)
			return
		}
		notification, _ := NewWSMessage("session.stopped", stopped)
		hub.BroadcastToUser(userID, notification)
		slog.Info("session stopped", "session_id", stopped.SessionID)

		if hub.Decision != nil {
			dataMap := map[string]string{}
			if stopped.LastAssistantMessage != "" {
				dataMap["lastAssistantMessage"] = stopped.LastAssistantMessage
			}
			data, _ := json.Marshal(dataMap)
			go hub.Decision.HandleSessionEvent(userID, stopped.SessionID, "session_stopped", deviceName, data)
		} else if hub.Notifier != nil {
			go hub.Notifier.NotifySessionStopped(userID, stopped.SessionID, stopped.LastAssistantMessage)
		}

	case "agent.session.completed":
		// Parse only sessionId — the completed message has no metadata fields.
		var partial struct {
			SessionID string `json:"sessionId"`
		}
		if err := json.Unmarshal(msg.Payload, &partial); err != nil {
			slog.Error("parse session completed failed", "device_id", deviceID, "error", err)
			return
		}

		// Update only the status column, preserving existing metadata.
		if err := db.UpdateSessionStatus(database, partial.SessionID, model.StatusCompleted); err != nil {
			slog.Error("update session status to completed failed", "session_id", partial.SessionID, "error", err)
			return
		}

		// Fetch the full session (with preserved metadata) for the iOS broadcast.
		session, err := db.GetSession(database, partial.SessionID)
		if err != nil {
			slog.Error("get session after completion failed", "session_id", partial.SessionID, "error", err)
			return
		}

		notification, _ := NewWSMessage("session.update", model.SessionUpdateNotification{
			Session:    session,
			DeviceName: deviceName,
		})
		hub.BroadcastToUser(userID, notification)

		// Push notification for session completion — routed through decision engine.
		if hub.Notifier != nil {
			go hub.Notifier.NotifyLiveActivityUpdate(partial.SessionID, "completed", "", 0, 0)
		}
		if hub.Decision != nil {
			go hub.Decision.HandleSessionEvent(userID, partial.SessionID, "session_completed", deviceName, nil)
			go hub.Decision.CleanupSession(partial.SessionID)
		} else if hub.Notifier != nil {
			go hub.Notifier.NotifySessionCompleted(userID, partial.SessionID)
		}

	case "agent.command.ack":
		var ack model.CommandAck
		if err := json.Unmarshal(msg.Payload, &ack); err != nil {
			slog.Error("parse command ack failed", "device_id", deviceID, "error", err)
			return
		}
		if err := db.UpdateCommandStatus(database, ack.CommandID, "running"); err != nil {
			slog.Error("update command status to running failed", "command_id", ack.CommandID, "error", err)
		}
		notification, _ := NewWSMessage("command.running", ack)
		hub.BroadcastToUser(userID, notification)
		slog.Info("command ack received, now running", "command_id", ack.CommandID, "session_id", ack.SessionID)

	case "agent.command.chunk":
		var chunk model.CommandChunk
		if err := json.Unmarshal(msg.Payload, &chunk); err != nil {
			slog.Error("parse command chunk failed", "device_id", deviceID, "error", err)
			return
		}
		// Stream directly to iOS — no DB storage for streaming chunks.
		notification, _ := NewWSMessage("command.chunk", chunk)
		hub.BroadcastToUser(userID, notification)

	case "agent.command.done":
		var done model.CommandDone
		if err := json.Unmarshal(msg.Payload, &done); err != nil {
			slog.Error("parse command done failed", "device_id", deviceID, "error", err)
			return
		}
		if err := db.UpdateCommandStatus(database, done.CommandID, "completed"); err != nil {
			slog.Error("update command status to completed failed", "command_id", done.CommandID, "error", err)
		}
		notification, _ := NewWSMessage("command.done", done)
		hub.BroadcastToUser(userID, notification)
		slog.Info("command done", "command_id", done.CommandID, "session_id", done.SessionID)

	case "agent.command.failed":
		var failed model.CommandFailed
		if err := json.Unmarshal(msg.Payload, &failed); err != nil {
			slog.Error("parse command failed message failed", "device_id", deviceID, "error", err)
			return
		}
		if err := db.UpdateCommandStatus(database, failed.CommandID, "failed"); err != nil {
			slog.Error("update command status to failed failed", "command_id", failed.CommandID, "error", err)
		}
		notification, _ := NewWSMessage("command.failed", failed)
		hub.BroadcastToUser(userID, notification)
		slog.Warn("command failed", "command_id", failed.CommandID, "session_id", failed.SessionID, "error", failed.Error)

	case "agent.command.cancelled":
		var cancelled model.CommandCancelled
		if err := json.Unmarshal(msg.Payload, &cancelled); err != nil {
			slog.Error("parse command cancelled failed", "device_id", deviceID, "error", err)
			return
		}
		if err := db.UpdateCommandStatus(database, cancelled.CommandID, "cancelled"); err != nil {
			slog.Error("update command status to cancelled failed", "command_id", cancelled.CommandID, "error", err)
		}
		notification, _ := NewWSMessage("command.cancelled", cancelled)
		hub.BroadcastToUser(userID, notification)
		slog.Info("command cancelled", "command_id", cancelled.CommandID, "session_id", cancelled.SessionID)

	case "agent.todo.sync":
		var todoSync model.TodoSync
		if err := json.Unmarshal(msg.Payload, &todoSync); err != nil {
			slog.Error("parse todo sync failed", "device_id", deviceID, "error", err)
			return
		}

		// Enforce length limits.
		if len(todoSync.ProjectPath) > 1024 {
			todoSync.ProjectPath = todoSync.ProjectPath[:1024]
		}
		if len(todoSync.RawContent) > 64*1024 {
			todoSync.RawContent = todoSync.RawContent[:64*1024]
		}

		// Look up or create project from projectPath.
		projectID := db.EnsureProjectForSession(database, userID, todoSync.ProjectPath)

		// Marshal items to JSON for DB storage.
		itemsJSON, err := json.Marshal(todoSync.Items)
		if err != nil {
			slog.Error("marshal todo items failed", "device_id", deviceID, "error", err)
			return
		}

		if err := db.UpsertTodo(database, userID, todoSync.ProjectPath, projectID, todoSync.ContentHash, todoSync.RawContent, string(itemsJSON)); err != nil {
			slog.Error("upsert todo failed", "device_id", deviceID, "project_path", todoSync.ProjectPath, "error", err)
			return
		}

		slog.Info("todo synced", "device_id", deviceID, "project_path", todoSync.ProjectPath, "items", len(todoSync.Items))

		// Broadcast todo.updated to iOS clients.
		projectName := todoSync.ProjectPath
		for i := len(projectName) - 1; i >= 0; i-- {
			if projectName[i] == '/' {
				projectName = projectName[i+1:]
				break
			}
		}

		todoState := model.TodoState{
			ProjectID:   projectID,
			ProjectPath: todoSync.ProjectPath,
			ProjectName: projectName,
			RawContent:  todoSync.RawContent,
			Items:       todoSync.Items,
			UpdatedAt:   time.Now().UTC().Format(time.RFC3339),
		}
		notification, _ := NewWSMessage("todo.updated", struct {
			ProjectTodos model.TodoState `json:"projectTodos"`
		}{todoState})
		hub.BroadcastToUser(userID, notification)

	case "agent.session.metrics":
		var metrics model.AgentSessionMetrics
		if err := json.Unmarshal(msg.Payload, &metrics); err != nil {
			slog.Error("parse session metrics failed", "device_id", deviceID, "error", err)
			return
		}
		if err := db.AccumulateSessionCost(database, metrics.SessionID, metrics.CostUsd); err != nil {
			slog.Error("accumulate session cost failed", "session_id", metrics.SessionID, "error", err)
		}
		// Broadcast to iOS
		notification, _ := NewWSMessage("session.metrics", metrics)
		hub.BroadcastToUser(userID, notification)
		slog.Info("session metrics received",
			"session_id", metrics.SessionID, "model", metrics.Model,
			"cost_usd", metrics.CostUsd, "input_tokens", metrics.InputTokens,
			"output_tokens", metrics.OutputTokens)

	default:
		slog.Warn("unknown agent message type", "type", msg.Type, "device_id", deviceID)
	}
}

// reconcileSessionsFromHeartbeat marks sessions as idle if the agent reports
// them as no longer active. This prevents sessions from staying "running"
// in the DB after the agent has moved on.
func reconcileSessionsFromHeartbeat(database *sql.DB, deviceID string, activeSessions []string) {
	dbRunning, err := db.ListRunningSessionsByDevice(database, deviceID)
	if err != nil || len(dbRunning) == 0 {
		return
	}

	activeSet := make(map[string]bool, len(activeSessions))
	for _, id := range activeSessions {
		activeSet[id] = true
	}

	for _, sessionID := range dbRunning {
		if !activeSet[sessionID] {
			slog.Info("reconcile: session not in agent active list, marking idle", "session_id", sessionID, "device_id", deviceID)
			_ = db.UpdateSessionStatus(database, sessionID, "idle")
		}
	}
}

func agentWritePump(ac *AgentConn) {
	ticker := time.NewTicker(agentPingPeriod)
	defer func() {
		ticker.Stop()
		ac.Conn.Close()
	}()

	for {
		select {
		case message, ok := <-ac.Send:
			ac.Conn.SetWriteDeadline(time.Now().Add(agentWriteWait))
			if !ok {
				ac.Conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
			if err := ac.Conn.WriteMessage(websocket.TextMessage, message); err != nil {
				return
			}
		case <-ticker.C:
			ac.Conn.SetWriteDeadline(time.Now().Add(agentWriteWait))
			if err := ac.Conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}
