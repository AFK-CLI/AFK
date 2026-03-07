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

type TodoHandler struct {
	DB              *sql.DB
	Hub             *ws.Hub
	NonceStore      *auth.NonceStore
	ServerPrivateKey ed25519.PrivateKey
}

func (h *TodoHandler) HandleList(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	todos, err := db.ListTodos(h.DB, userID)
	if err != nil {
		slog.Error("list todos failed", "user_id", userID, "error", err)
		writeError(w, "failed to list todos", http.StatusInternalServerError)
		return
	}

	if todos == nil {
		todos = []*model.TodoState{}
	}

	writeJSON(w, http.StatusOK, todos)
}

func (h *TodoHandler) HandleAppend(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 1<<16) // 64 KB
	var req model.TodoAppendRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}
	if req.ProjectID == "" {
		writeError(w, "projectId is required", http.StatusBadRequest)
		return
	}
	if req.Text == "" {
		writeError(w, "text is required", http.StatusBadRequest)
		return
	}
	if len(req.Text) > 4096 {
		writeError(w, "text exceeds maximum length", http.StatusBadRequest)
		return
	}

	// Look up project path. Try todos table first (already synced),
	// fall back to projects table (no todo.md yet — agent will create it).
	var projectPath string
	if td, err := db.GetTodoByProject(h.DB, userID, req.ProjectID); err == nil {
		projectPath = td.ProjectPath
	} else if p, err := db.GetProjectByID(h.DB, userID, req.ProjectID); err == nil {
		projectPath = p.Path
	} else {
		writeError(w, "project not found", http.StatusNotFound)
		return
	}

	// Find an online agent for this user.
	agentConn := h.Hub.GetOnlineAgentForUser(userID)
	if agentConn == nil {
		writeError(w, "no agent online", http.StatusConflict)
		return
	}

	// Send server.todo.append to the agent via WS.
	appendMsg := model.ServerTodoAppend{
		ProjectPath: projectPath,
		Text:        req.Text,
	}
	wsMsg, err := ws.NewWSMessage("server.todo.append", appendMsg)
	if err != nil {
		slog.Error("failed to marshal todo append WS message", "error", err)
		writeError(w, "internal error", http.StatusInternalServerError)
		return
	}

	if err := h.Hub.SendToAgent(agentConn.DeviceID, wsMsg); err != nil {
		slog.Error("failed to send todo append to agent", "device_id", agentConn.DeviceID, "error", err)
		writeError(w, "failed to deliver to agent", http.StatusBadGateway)
		return
	}

	slog.Info("sent todo append to agent", "device_id", agentConn.DeviceID, "project_path", projectPath)

	writeJSON(w, http.StatusOK, map[string]string{"status": "sent"})
}

func (h *TodoHandler) HandleToggle(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 1<<16)
	var req model.TodoToggleRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}
	if req.ProjectID == "" {
		writeError(w, "projectId is required", http.StatusBadRequest)
		return
	}
	if req.Line < 1 {
		writeError(w, "line must be >= 1", http.StatusBadRequest)
		return
	}

	var projectPath string
	if td, err := db.GetTodoByProject(h.DB, userID, req.ProjectID); err == nil {
		projectPath = td.ProjectPath
	} else if p, err := db.GetProjectByID(h.DB, userID, req.ProjectID); err == nil {
		projectPath = p.Path
	} else {
		writeError(w, "project not found", http.StatusNotFound)
		return
	}

	agentConn := h.Hub.GetOnlineAgentForUser(userID)
	if agentConn == nil {
		writeError(w, "no agent online", http.StatusConflict)
		return
	}

	toggleMsg := model.ServerTodoToggle{
		ProjectPath: projectPath,
		Line:        req.Line,
		Checked:     req.Checked,
	}
	wsMsg, err := ws.NewWSMessage("server.todo.toggle", toggleMsg)
	if err != nil {
		slog.Error("failed to marshal todo toggle WS message", "error", err)
		writeError(w, "internal error", http.StatusInternalServerError)
		return
	}

	if err := h.Hub.SendToAgent(agentConn.DeviceID, wsMsg); err != nil {
		slog.Error("failed to send todo toggle to agent", "device_id", agentConn.DeviceID, "error", err)
		writeError(w, "failed to deliver to agent", http.StatusBadGateway)
		return
	}

	slog.Info("sent todo toggle to agent", "device_id", agentConn.DeviceID, "project_path", projectPath, "line", req.Line, "checked", req.Checked)
	writeJSON(w, http.StatusOK, map[string]string{"status": "sent"})
}

func (h *TodoHandler) HandleStartSession(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 1<<16) // 64 KB
	var req model.TodoStartSessionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}
	if req.ProjectID == "" {
		writeError(w, "projectId is required", http.StatusBadRequest)
		return
	}
	if req.DeviceID == "" {
		writeError(w, "deviceId is required", http.StatusBadRequest)
		return
	}
	if req.TodoText == "" {
		writeError(w, "todoText is required", http.StatusBadRequest)
		return
	}
	if len(req.TodoText) > 4096 {
		writeError(w, "todoText exceeds maximum length", http.StatusBadRequest)
		return
	}

	// Validate permissionMode against allowlist.
	if !validPermissionModes[req.PermissionMode] {
		writeError(w, "invalid permissionMode", http.StatusBadRequest)
		return
	}

	// Verify device belongs to user.
	device, err := db.GetDevice(h.DB, req.DeviceID)
	if err != nil {
		writeError(w, "device not found", http.StatusNotFound)
		return
	}
	if device.UserID != userID {
		writeError(w, "forbidden", http.StatusForbidden)
		return
	}

	// Verify agent is online.
	agentConn := h.Hub.GetAgentConn(req.DeviceID)
	if agentConn == nil {
		writeError(w, "device is offline", http.StatusConflict)
		return
	}

	// Look up project path from todos or projects table.
	var projectPath string
	if td, tErr := db.GetTodoByProject(h.DB, userID, req.ProjectID); tErr == nil {
		projectPath = td.ProjectPath
	} else if p, pErr := db.GetProjectByID(h.DB, userID, req.ProjectID); pErr == nil {
		projectPath = p.Path
	} else {
		writeError(w, "project not found", http.StatusNotFound)
		return
	}

	// Build prompt from todo text.
	prompt := fmt.Sprintf("Work on this task from the project todo list: %s", req.TodoText)

	// Generate nonce and expiry for the command.
	nonce := auth.GenerateID()
	expiresAt := time.Now().Add(10 * time.Minute).Unix()

	// Check nonce.
	if err := h.NonceStore.Check(nonce); err != nil {
		writeError(w, "nonce conflict", http.StatusConflict)
		return
	}

	// Create signed command.
	commandID := auth.GenerateID()
	promptHash := auth.HashPrompt(prompt)

	signedCmd := auth.SignedCommand{
		CommandID:  commandID,
		SessionID:  "",
		PromptHash: promptHash,
		Nonce:      nonce,
		ExpiresAt:  expiresAt,
	}
	auth.SignCommand(&signedCmd, h.ServerPrivateKey)

	// Store command in DB.
	now := time.Now().UTC().Format(time.RFC3339)
	expiresAtStr := time.Unix(expiresAt, 0).UTC().Format(time.RFC3339)

	cmdRecord := &model.Command{
		ID:         commandID,
		SessionID:  "",
		UserID:     userID,
		DeviceID:   req.DeviceID,
		PromptHash: promptHash,
		Nonce:      nonce,
		Status:     "pending",
		CreatedAt:  now,
		UpdatedAt:  now,
		ExpiresAt:  expiresAtStr,
	}
	if err := db.CreateCommand(h.DB, cmdRecord); err != nil {
		slog.Error("failed to store todo session command", "command_id", commandID, "error", err)
		writeError(w, "failed to create command", http.StatusInternalServerError)
		return
	}

	// Build ServerNewCommand WS message.
	serverCmd := model.ServerNewCommand{
		CommandID:      commandID,
		ProjectPath:    projectPath,
		Prompt:         prompt,
		PromptHash:     promptHash,
		UseWorktree:    req.UseWorktree,
		PermissionMode: req.PermissionMode,
		TodoText:       req.TodoText,
		Nonce:          nonce,
		ExpiresAt:      expiresAt,
		Signature:      signedCmd.Signature,
	}

	wsMsg, err := ws.NewWSMessage("server.command.new", serverCmd)
	if err != nil {
		slog.Error("failed to marshal WS message for todo session", "command_id", commandID, "error", err)
		writeError(w, "internal error", http.StatusInternalServerError)
		return
	}

	if err := h.Hub.SendToAgent(req.DeviceID, wsMsg); err != nil {
		slog.Error("failed to send todo session command to agent", "device_id", req.DeviceID, "command_id", commandID, "error", err)
		writeError(w, "failed to deliver command to agent", http.StatusBadGateway)
		return
	}

	slog.Info("sent todo start-session command", "command_id", commandID, "device_id", req.DeviceID, "project", projectPath)

	writeJSON(w, http.StatusOK, map[string]string{
		"commandId": commandID,
		"status":    "pending",
	})
}
