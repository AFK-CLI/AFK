package handler

import (
	"crypto/ed25519"
	"database/sql"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
	"github.com/AFK/afk-cloud/internal/ws"
)

func HandleContinue(hub *ws.Hub, database *sql.DB, nonceStore *auth.NonceStore, serverPrivateKey ed25519.PrivateKey) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// 1. Auth check.
		userID := auth.UserIDFromContext(r.Context())
		if userID == "" {
			writeError(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		// 2. Parse session ID from URL path.
		sessionID := r.PathValue("id")
		if sessionID == "" {
			writeError(w, "session id is required", http.StatusBadRequest)
			return
		}

		// 3. Decode ContinueRequest from body.
		r.Body = http.MaxBytesReader(w, r.Body, 5<<20) // 5 MB (images can be large)
		var req model.ContinueRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, "invalid request body", http.StatusBadRequest)
			return
		}
		if req.Prompt == "" {
			writeError(w, "prompt is required", http.StatusBadRequest)
			return
		}
		if len(req.Prompt) > 100*1024 {
			writeError(w, "prompt exceeds maximum length", http.StatusBadRequest)
			return
		}
		if len(req.Images) > 5 {
			writeError(w, "too many images (max 5)", http.StatusBadRequest)
			return
		}
		if req.Nonce == "" {
			writeError(w, "nonce is required", http.StatusBadRequest)
			return
		}
		if req.ExpiresAt == 0 {
			writeError(w, "expiresAt is required", http.StatusBadRequest)
			return
		}

		// Reject already-expired commands.
		if time.Now().Unix() > req.ExpiresAt {
			writeError(w, "command already expired", http.StatusBadRequest)
			return
		}

		// 4. Look up session — verify ownership.
		session, err := db.GetSession(database, sessionID)
		if err != nil {
			writeError(w, "session not found", http.StatusNotFound)
			return
		}
		if session.UserID != userID {
			writeError(w, "forbidden", http.StatusForbidden)
			return
		}

		// 5. Verify agent is online.
		agentConn := hub.GetAgentConn(session.DeviceID)
		if agentConn == nil {
			writeError(w, "device is offline", http.StatusConflict)
			return
		}

		// 6. Check nonce — reject if replayed.
		if err := nonceStore.Check(req.Nonce); err != nil {
			writeError(w, "nonce already used", http.StatusConflict)
			return
		}

		// 7. Check privacy mode.
		privacyMode, err := db.GetDevicePrivacyMode(database, session.DeviceID)
		if err != nil {
			slog.Warn("failed to get privacy mode, using default", "device_id", session.DeviceID, "error", err)
			privacyMode = "telemetry_only"
		}

		// 8. Create signed command.
		commandID := auth.GenerateID()
		promptHash := auth.HashPrompt(req.Prompt)

		signedCmd := auth.SignedCommand{
			CommandID:  commandID,
			SessionID:  sessionID,
			PromptHash: promptHash,
			Nonce:      req.Nonce,
			ExpiresAt:  req.ExpiresAt,
		}
		auth.SignCommand(&signedCmd, serverPrivateKey)

		// 9. Store command in DB.
		now := time.Now().UTC().Format(time.RFC3339)
		expiresAtStr := time.Unix(req.ExpiresAt, 0).UTC().Format(time.RFC3339)

		cmdRecord := &model.Command{
			ID:         commandID,
			SessionID:  sessionID,
			UserID:     userID,
			DeviceID:   session.DeviceID,
			PromptHash: promptHash,
			Nonce:      req.Nonce,
			Status:     "pending",
			CreatedAt:  now,
			UpdatedAt:  now,
			ExpiresAt:  expiresAtStr,
		}

		// Store encrypted prompt if provided (E2EE mode).
		if req.PromptEncrypted != "" {
			cmdRecord.PromptEncrypted = req.PromptEncrypted
		} else if privacyMode == "encrypted" {
			// Fallback: if privacy mode is encrypted but no E2EE prompt was sent,
			// store the plaintext prompt as-is (pre-E2EE migration path).
			cmdRecord.PromptEncrypted = req.Prompt
		}

		if err := db.CreateCommand(database, cmdRecord); err != nil {
			slog.Error("failed to store command", "command_id", commandID, "error", err)
			writeError(w, "failed to create command", http.StatusInternalServerError)
			return
		}

		// 10. Build ServerCommand WS message with raw prompt (held in memory only).
		serverCmd := model.ServerCommand{
			CommandID:       commandID,
			SessionID:       sessionID,
			Prompt:          req.Prompt,
			PromptEncrypted: req.PromptEncrypted,
			Images:          req.Images,
			ImagesEncrypted: req.ImagesEncrypted,
			PromptHash:      promptHash,
			Nonce:           req.Nonce,
			ExpiresAt:       req.ExpiresAt,
			Signature:       signedCmd.Signature,
		}

		wsMsg, err := ws.NewWSMessage("server.command.continue", serverCmd)
		if err != nil {
			slog.Error("failed to marshal WS message", "command_id", commandID, "error", err)
			writeError(w, "internal error", http.StatusInternalServerError)
			return
		}

		// 11. Send to agent.
		if err := hub.SendToAgent(session.DeviceID, wsMsg); err != nil {
			slog.Error("failed to send command to agent", "device_id", session.DeviceID, "command_id", commandID, "error", err)
			writeError(w, "failed to deliver command to agent", http.StatusBadGateway)
			return
		}

		// 12. Audit log with content_hash.
		details := fmt.Sprintf(`{"session_id":%q,"command_id":%q,"privacy_mode":%q}`, sessionID, commandID, privacyMode)
		_ = db.InsertAuditLog(database, &model.AuditLogEntry{
			UserID:      userID,
			DeviceID:    session.DeviceID,
			Action:      "command_continue",
			Details:     details,
			ContentHash: promptHash,
		})

		slog.Info("sent continue command", "command_id", commandID, "device_id", session.DeviceID, "session_id", sessionID)

		// 13. Return response.
		writeJSON(w, http.StatusOK, map[string]string{
			"commandId": commandID,
			"status":    "pending",
		})
	}
}
