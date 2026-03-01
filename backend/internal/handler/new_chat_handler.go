package handler

import (
	"crypto/ed25519"
	"database/sql"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
	"github.com/AFK/afk-cloud/internal/ws"
)

// worktreeNameRe validates worktree names: alphanumeric + hyphens only, no path separators.
var worktreeNameRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9-]*$`)

// validPermissionModes defines the allowed values for permission mode.
var validPermissionModes = map[string]bool{
	"":            true, // empty is valid (default)
	"ask":         true,
	"acceptEdits": true,
	"plan":        true,
	"autoApprove": true,
}

func HandleNewChat(hub *ws.Hub, database *sql.DB, nonceStore *auth.NonceStore, serverPrivateKey ed25519.PrivateKey) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// 1. Auth check.
		userID := auth.UserIDFromContext(r.Context())
		if userID == "" {
			writeError(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		// 2. Decode NewChatRequest from body.
		r.Body = http.MaxBytesReader(w, r.Body, 1<<20) // 1 MB
		var req model.NewChatRequest
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
		if req.DeviceID == "" {
			writeError(w, "deviceId is required", http.StatusBadRequest)
			return
		}
		if req.ProjectPath == "" {
			writeError(w, "projectPath is required", http.StatusBadRequest)
			return
		}
		// Reject path traversal attempts and require absolute path.
		if !filepath.IsAbs(req.ProjectPath) {
			writeError(w, "projectPath must be an absolute path", http.StatusBadRequest)
			return
		}
		if strings.Contains(req.ProjectPath, "..") {
			writeError(w, "projectPath must not contain path traversal", http.StatusBadRequest)
			return
		}
		// Validate worktreeName if provided.
		if req.WorktreeName != "" {
			if len(req.WorktreeName) > 64 || !worktreeNameRe.MatchString(req.WorktreeName) {
				writeError(w, "worktreeName must be alphanumeric with hyphens, max 64 characters", http.StatusBadRequest)
				return
			}
		}
		// Validate permissionMode against allowlist.
		if !validPermissionModes[req.PermissionMode] {
			writeError(w, "invalid permissionMode", http.StatusBadRequest)
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

		// 3. Verify device belongs to the user.
		device, err := db.GetDevice(database, req.DeviceID)
		if err != nil {
			writeError(w, "device not found", http.StatusNotFound)
			return
		}
		if device.UserID != userID {
			writeError(w, "forbidden", http.StatusForbidden)
			return
		}

		// 4. Verify agent is online.
		agentConn := hub.GetAgentConn(req.DeviceID)
		if agentConn == nil {
			writeError(w, "device is offline", http.StatusConflict)
			return
		}

		// 5. Check nonce — reject if replayed.
		if err := nonceStore.Check(req.Nonce); err != nil {
			writeError(w, "nonce already used", http.StatusConflict)
			return
		}

		// 6. Create signed command (empty sessionId for new chat).
		commandID := auth.GenerateID()
		promptHash := auth.HashPrompt(req.Prompt)

		signedCmd := auth.SignedCommand{
			CommandID:  commandID,
			SessionID:  "", // empty for new chat
			PromptHash: promptHash,
			Nonce:      req.Nonce,
			ExpiresAt:  req.ExpiresAt,
		}
		auth.SignCommand(&signedCmd, serverPrivateKey)

		// 7. Store command in DB with empty session_id (updated later when agent reports new session).
		now := time.Now().UTC().Format(time.RFC3339)
		expiresAtStr := time.Unix(req.ExpiresAt, 0).UTC().Format(time.RFC3339)

		cmdRecord := &model.Command{
			ID:         commandID,
			SessionID:  "", // empty — will be updated when agent reports the new session
			UserID:     userID,
			DeviceID:   req.DeviceID,
			PromptHash: promptHash,
			Nonce:      req.Nonce,
			Status:     "pending",
			CreatedAt:  now,
			UpdatedAt:  now,
			ExpiresAt:  expiresAtStr,
		}

		if req.PromptEncrypted != "" {
			cmdRecord.PromptEncrypted = req.PromptEncrypted
		}

		if err := db.CreateCommand(database, cmdRecord); err != nil {
			slog.Error("failed to store new chat command", "command_id", commandID, "error", err)
			writeError(w, "failed to create command", http.StatusInternalServerError)
			return
		}

		// 8. Build ServerNewCommand WS message.
		serverCmd := model.ServerNewCommand{
			CommandID:       commandID,
			ProjectPath:     req.ProjectPath,
			Prompt:          req.Prompt,
			PromptEncrypted: req.PromptEncrypted,
			PromptHash:      promptHash,
			UseWorktree:     req.UseWorktree,
			WorktreeName:    req.WorktreeName,
			PermissionMode:  req.PermissionMode,
			Nonce:           req.Nonce,
			ExpiresAt:       req.ExpiresAt,
			Signature:       signedCmd.Signature,
		}

		wsMsg, err := ws.NewWSMessage("server.command.new", serverCmd)
		if err != nil {
			slog.Error("failed to marshal WS message", "command_id", commandID, "error", err)
			writeError(w, "internal error", http.StatusInternalServerError)
			return
		}

		// 9. Send to agent.
		if err := hub.SendToAgent(req.DeviceID, wsMsg); err != nil {
			slog.Error("failed to send new chat command to agent", "device_id", req.DeviceID, "command_id", commandID, "error", err)
			writeError(w, "failed to deliver command to agent", http.StatusBadGateway)
			return
		}

		// 10. Audit log.
		details := fmt.Sprintf(`{"command_id":%q,"device_id":%q,"project_path":%q,"use_worktree":%t}`,
			commandID, req.DeviceID, req.ProjectPath, req.UseWorktree)
		_ = db.InsertAuditLog(database, &model.AuditLogEntry{
			UserID:      userID,
			DeviceID:    req.DeviceID,
			Action:      "command_new_chat",
			Details:     details,
			ContentHash: promptHash,
		})

		slog.Info("sent new chat command", "command_id", commandID, "device_id", req.DeviceID, "project", req.ProjectPath, "use_worktree", req.UseWorktree)

		// 11. Return response.
		writeJSON(w, http.StatusOK, map[string]string{
			"commandId": commandID,
			"status":    "pending",
		})
	}
}
