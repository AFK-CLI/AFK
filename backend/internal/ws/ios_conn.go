package ws

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
	"github.com/gorilla/websocket"
)

const (
	iosWriteWait  = 10 * time.Second
	iosPongWait   = 60 * time.Second
	iosPingPeriod = (iosPongWait * 9) / 10
)

func ServeIOSWS(hub *Hub, database *sql.DB, secret string, ticketStore *auth.TicketStore) http.HandlerFunc {
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

		slog.Info("upgrading iOS connection", "user_id", userID, "device_id", deviceID)
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			slog.Error("iOS ws upgrade failed", "error", err)
			return
		}

		slog.Info("iOS app connected", "user_id", userID, "device_id", deviceID)
		ic := hub.RegisterIOS(userID, deviceID, conn)

		// Mark iOS device online.
		if deviceID != "" {
			_ = db.UpdateDeviceStatus(database, deviceID, true, time.Now())

			device, _ := db.GetDevice(database, deviceID)
			deviceName := ""
			if device != nil {
				deviceName = device.Name
			}
			statusMsg, _ := NewWSMessage("device.status", model.DeviceStatusNotification{
				DeviceID:   deviceID,
				DeviceName: deviceName,
				IsOnline:   true,
			})
			hub.BroadcastToUser(userID, statusMsg)
		}

		// Replay cached agent control states so iOS immediately knows each agent's state.
		hub.SendCachedControlStates(userID, ic)

		// Replay cached usage states so iOS shows usage immediately.
		hub.SendCachedUsageStates(userID, ic)

		go iosWritePump(ic)
		go iosReadPump(hub, ic, database, userID, deviceID)
	}
}

func iosReadPump(hub *Hub, ic *IOSConn, database *sql.DB, userID, deviceID string) {
	defer func() {
		hub.UnregisterIOS(userID, ic)
		ic.Conn.Close()

		// Only mark device offline if no other connection from the same device exists.
		if deviceID != "" && !hub.HasIOSDeviceConn(userID, deviceID) {
			_ = db.UpdateDeviceStatus(database, deviceID, false, time.Now())

			device, _ := db.GetDevice(database, deviceID)
			deviceName := ""
			if device != nil {
				deviceName = device.Name
			}
			statusMsg, _ := NewWSMessage("device.status", model.DeviceStatusNotification{
				DeviceID:   deviceID,
				DeviceName: deviceName,
				IsOnline:   false,
			})
			hub.BroadcastToUser(userID, statusMsg)
		}

		// If no iOS connections remain, disable remote approval on all agents
		// so they don't block waiting for approvals that can never come.
		if !hub.HasActiveIOSConns(userID) {
			ra := false
			disableMsg, err := NewWSMessage("agent_control", struct {
				RemoteApproval *bool `json:"remoteApproval"`
			}{&ra})
			if err == nil {
				hub.SendToUserAgents(userID, disableMsg)
				slog.Info("last iOS client disconnected, disabled remote approval for all agents", "user_id", userID)
			}
		}
	}()

	ic.Conn.SetReadLimit(maxMessageSize)
	ic.Conn.SetReadDeadline(time.Now().Add(iosPongWait))
	ic.Conn.SetPongHandler(func(string) error {
		ic.Conn.SetReadDeadline(time.Now().Add(iosPongWait))
		return nil
	})

	for {
		_, data, err := ic.Conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
				slog.Error("iOS ws read error", "error", err)
			}
			return
		}

		msg, err := ParseWSMessage(data)
		if err != nil {
			slog.Error("iOS ws message parse failed", "error", err)
			continue
		}

		handleIOSMessage(hub, ic, database, msg)
	}
}

func handleIOSMessage(hub *Hub, ic *IOSConn, database *sql.DB, msg *model.WSMessage) {
	switch msg.Type {
	case "app.subscribe":
		var sub model.AppSubscribe
		if err := json.Unmarshal(msg.Payload, &sub); err != nil {
			slog.Error("failed to parse subscribe message", "error", err)
			return
		}

		ic.mu.Lock()
		// Reset subscriptions.
		ic.Subscriptions = make(map[string]bool)
		for _, sid := range sub.SessionIDs {
			ic.Subscriptions[sid] = true
		}
		ic.mu.Unlock()

	case "app.permission.response":
		var resp model.AppPermissionResponse
		if err := json.Unmarshal(msg.Payload, &resp); err != nil {
			slog.Error("failed to parse permission response", "error", err)
			return
		}

		// We need the deviceId to route to the correct agent.
		// Extract it from the payload (iOS includes it).
		type responseWithDevice struct {
			model.AppPermissionResponse
			DeviceID string `json:"deviceId"`
		}
		var respDev responseWithDevice
		if err := json.Unmarshal(msg.Payload, &respDev); err != nil {
			slog.Error("failed to parse permission response device", "error", err)
			return
		}

		// Forward to the correct agent (with ownership check).
		agentConn := hub.GetAgentConn(respDev.DeviceID)
		if agentConn == nil {
			slog.Warn("no agent connection for device", "device_id", respDev.DeviceID)
			return
		}
		if agentConn.UserID != ic.UserID {
			slog.Warn("cross-user permission response rejected",
				"ios_user", ic.UserID, "agent_user", agentConn.UserID, "device_id", respDev.DeviceID)
			return
		}

		fwd, err := NewWSMessage("permission.response", resp)
		if err != nil {
			slog.Error("failed to marshal permission response", "error", err)
			return
		}
		data, err := marshalMsg(fwd)
		if err != nil {
			slog.Error("failed to marshal permission response message", "error", err)
			return
		}
		select {
		case agentConn.Send <- data:
			slog.Info("forwarded permission response", "nonce", resp.Nonce, "device_id", respDev.DeviceID)
		default:
			slog.Warn("agent send buffer full, dropping permission response", "device_id", respDev.DeviceID)
		}

		// Audit log: record permission response.
		details := fmt.Sprintf(`{"nonce":%q,"action":%q,"device_id":%q}`, resp.Nonce, resp.Action, respDev.DeviceID)
		_ = db.InsertAuditLog(database, &model.AuditLogEntry{
			UserID:   ic.UserID,
			DeviceID: respDev.DeviceID,
			Action:   "permission_response",
			Details:  details,
		})

	case "app.permission_mode":
		var req model.AppPermissionMode
		if err := json.Unmarshal(msg.Payload, &req); err != nil {
			slog.Error("failed to parse permission mode", "error", err)
			return
		}
		// Ownership check: verify the agent belongs to this iOS user.
		if ac := hub.GetAgentConn(req.DeviceID); ac != nil && ac.UserID != ic.UserID {
			slog.Warn("cross-user permission_mode rejected",
				"ios_user", ic.UserID, "agent_user", ac.UserID, "device_id", req.DeviceID)
			return
		}
		fwd, err := NewWSMessage("permission_mode", struct {
			Mode string `json:"mode"`
		}{req.Mode})
		if err != nil {
			slog.Error("failed to marshal permission mode", "error", err)
			return
		}
		if err := hub.SendToAgent(req.DeviceID, fwd); err != nil {
			slog.Error("failed to forward permission mode", "device_id", req.DeviceID, "error", err)
		} else {
			slog.Info("forwarded permission mode", "mode", req.Mode, "device_id", req.DeviceID)
		}

	case "app.agent_control":
		var req model.AppAgentControl
		if err := json.Unmarshal(msg.Payload, &req); err != nil {
			slog.Error("failed to parse agent control", "error", err)
			return
		}
		// Ownership check: verify the agent belongs to this iOS user.
		if ac := hub.GetAgentConn(req.DeviceID); ac != nil && ac.UserID != ic.UserID {
			slog.Warn("cross-user agent_control rejected",
				"ios_user", ic.UserID, "agent_user", ac.UserID, "device_id", req.DeviceID)
			return
		}
		fwd, err := NewWSMessage("agent_control", struct {
			RemoteApproval *bool `json:"remoteApproval,omitempty"`
			AutoPlanExit   *bool `json:"autoPlanExit,omitempty"`
		}{req.RemoteApproval, req.AutoPlanExit})
		if err != nil {
			slog.Error("failed to marshal agent control", "error", err)
			return
		}
		if err := hub.SendToAgent(req.DeviceID, fwd); err != nil {
			slog.Error("failed to forward agent control", "device_id", req.DeviceID, "error", err)
		} else {
			slog.Info("forwarded agent control", "device_id", req.DeviceID)
		}

	case "app.session.stop":
		var req model.AppSessionStop
		if err := json.Unmarshal(msg.Payload, &req); err != nil {
			slog.Error("failed to parse session stop", "error", err)
			return
		}
		// Ownership check: verify the agent belongs to this iOS user.
		if ac := hub.GetAgentConn(req.DeviceID); ac != nil && ac.UserID != ic.UserID {
			slog.Warn("cross-user session.stop rejected",
				"ios_user", ic.UserID, "agent_user", ac.UserID, "device_id", req.DeviceID)
			return
		}
		fwd, err := NewWSMessage("server.session.stop", struct {
			SessionID string `json:"sessionId"`
		}{req.SessionID})
		if err != nil {
			slog.Error("failed to marshal session stop", "error", err)
			return
		}
		if err := hub.SendToAgent(req.DeviceID, fwd); err != nil {
			slog.Error("failed to forward session stop", "device_id", req.DeviceID, "error", err)
		} else {
			slog.Info("forwarded session stop", "session_id", req.SessionID, "device_id", req.DeviceID)
		}

	case "app.plan.restart":
		var req model.AppPlanRestart
		if err := json.Unmarshal(msg.Payload, &req); err != nil {
			slog.Error("failed to parse plan restart", "error", err)
			return
		}
		// Ownership check: verify the agent belongs to this iOS user.
		if ac := hub.GetAgentConn(req.DeviceID); ac != nil && ac.UserID != ic.UserID {
			slog.Warn("cross-user plan.restart rejected",
				"ios_user", ic.UserID, "agent_user", ac.UserID, "device_id", req.DeviceID)
			return
		}
		fwd, err := NewWSMessage("server.plan.restart", req)
		if err != nil {
			slog.Error("failed to marshal plan restart", "error", err)
			return
		}
		if err := hub.SendToAgent(req.DeviceID, fwd); err != nil {
			slog.Error("failed to forward plan restart", "device_id", req.DeviceID, "error", err)
		} else {
			slog.Info("forwarded plan restart", "session_id", req.SessionID, "device_id", req.DeviceID, "permission_mode", req.PermissionMode)
		}
	}
}

func iosWritePump(ic *IOSConn) {
	ticker := time.NewTicker(iosPingPeriod)
	defer func() {
		ticker.Stop()
		ic.Conn.Close()
	}()

	for {
		select {
		case message, ok := <-ic.Send:
			ic.Conn.SetWriteDeadline(time.Now().Add(iosWriteWait))
			if !ok {
				ic.Conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
			if err := ic.Conn.WriteMessage(websocket.TextMessage, message); err != nil {
				return
			}
		case <-ticker.C:
			ic.Conn.SetWriteDeadline(time.Now().Add(iosWriteWait))
			if err := ic.Conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}
