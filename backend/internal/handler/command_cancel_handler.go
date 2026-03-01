package handler

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
	"github.com/AFK/afk-cloud/internal/ws"
)

func HandleCancelCommand(hub *ws.Hub, database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID := auth.UserIDFromContext(r.Context())
		if userID == "" {
			writeError(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		sessionID := r.PathValue("id")
		if sessionID == "" {
			writeError(w, "session id is required", http.StatusBadRequest)
			return
		}

		r.Body = http.MaxBytesReader(w, r.Body, 64*1024) // 64 KB
		var req model.CancelRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, "invalid request body", http.StatusBadRequest)
			return
		}
		if req.CommandID == "" {
			writeError(w, "commandId is required", http.StatusBadRequest)
			return
		}

		// Verify session ownership.
		session, err := db.GetSession(database, sessionID)
		if err != nil {
			writeError(w, "session not found", http.StatusNotFound)
			return
		}
		if session.UserID != userID {
			writeError(w, "forbidden", http.StatusForbidden)
			return
		}

		// Verify command exists and is running.
		cmd, err := db.GetCommand(database, req.CommandID)
		if err != nil {
			writeError(w, "command not found", http.StatusNotFound)
			return
		}
		if cmd.SessionID != sessionID {
			writeError(w, "command does not belong to this session", http.StatusForbidden)
			return
		}
		if cmd.Status != "running" && cmd.Status != "pending" {
			writeError(w, "command is not running", http.StatusConflict)
			return
		}

		// Verify agent is online.
		agentConn := hub.GetAgentConn(session.DeviceID)
		if agentConn == nil {
			writeError(w, "device is offline", http.StatusConflict)
			return
		}

		// Send cancel to agent.
		cancelPayload := model.CancelRequest{CommandID: req.CommandID}
		wsMsg, err := ws.NewWSMessage("server.command.cancel", cancelPayload)
		if err != nil {
			writeError(w, "internal error", http.StatusInternalServerError)
			return
		}

		if err := hub.SendToAgent(session.DeviceID, wsMsg); err != nil {
			slog.Error("failed to send cancel to agent", "device_id", session.DeviceID, "command_id", req.CommandID, "error", err)
			writeError(w, "failed to deliver cancel to agent", http.StatusBadGateway)
			return
		}

		// Update command status to cancelled.
		if err := db.UpdateCommandStatus(database, req.CommandID, "cancelled"); err != nil {
			slog.Error("failed to update command status", "command_id", req.CommandID, "error", err)
		}

		// Audit log.
		details := fmt.Sprintf(`{"session_id":%q,"command_id":%q}`, sessionID, req.CommandID)
		_ = db.InsertAuditLog(database, &model.AuditLogEntry{
			UserID:   userID,
			DeviceID: session.DeviceID,
			Action:   "command_cancel",
			Details:  details,
		})

		slog.Info("cancelled command", "command_id", req.CommandID, "session_id", sessionID)

		writeJSON(w, http.StatusOK, map[string]string{
			"commandId": req.CommandID,
			"status":    "cancelled",
		})
	}
}
