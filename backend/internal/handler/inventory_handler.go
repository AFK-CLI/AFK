package handler

import (
	"database/sql"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
	"github.com/AFK/afk-cloud/internal/ws"
)

// InventoryHandler handles device inventory and skill sharing endpoints.
type InventoryHandler struct {
	DB  *sql.DB
	Hub *ws.Hub
}

// HandleGetDeviceInventory returns the inventory for a single device.
// GET /v1/devices/{id}/inventory
func (h *InventoryHandler) HandleGetDeviceInventory(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	deviceID := r.PathValue("id")
	if deviceID == "" {
		writeError(w, "device id is required", http.StatusBadRequest)
		return
	}

	// Verify device belongs to user.
	device, err := db.GetDevice(h.DB, deviceID)
	if err != nil {
		writeError(w, "device not found", http.StatusNotFound)
		return
	}
	if device.UserID != userID {
		writeError(w, "forbidden", http.StatusForbidden)
		return
	}

	inventoryJSON, hash, updatedAt, err := db.GetDeviceInventory(h.DB, deviceID)
	if err != nil {
		slog.Error("get device inventory failed", "device_id", deviceID, "error", err)
		writeError(w, "inventory not found", http.StatusNotFound)
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"deviceId":    deviceID,
		"inventory":   json.RawMessage(inventoryJSON),
		"contentHash": hash,
		"updatedAt":   updatedAt.Format(time.RFC3339),
	})
}

// HandleGetAllInventory returns the inventory for all devices belonging to the user.
// GET /v1/inventory
func (h *InventoryHandler) HandleGetAllInventory(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	rows, err := db.ListUserInventory(h.DB, userID)
	if err != nil {
		slog.Error("list user inventory failed", "user_id", userID, "error", err)
		writeError(w, "failed to list inventory", http.StatusInternalServerError)
		return
	}

	if rows == nil {
		rows = []db.DeviceInventoryRow{}
	}

	// Build response with inventory as raw JSON.
	type inventoryResponse struct {
		DeviceID    string          `json:"deviceId"`
		DeviceName  string          `json:"deviceName"`
		IsOnline    bool            `json:"isOnline"`
		Inventory   json.RawMessage `json:"inventory"`
		ContentHash string          `json:"contentHash"`
		UpdatedAt   string          `json:"updatedAt"`
	}

	result := make([]inventoryResponse, len(rows))
	for i, row := range rows {
		result[i] = inventoryResponse{
			DeviceID:    row.DeviceID,
			DeviceName:  row.DeviceName,
			IsOnline:    row.IsOnline,
			Inventory:   json.RawMessage(row.InventoryJSON),
			ContentHash: row.ContentHash,
			UpdatedAt:   row.UpdatedAt.Format(time.RFC3339),
		}
	}

	writeJSON(w, http.StatusOK, result)
}

// HandleInstallSkill sends an encrypted slash command to a target agent device.
// Stores in pending_skill_installs for offline delivery. If agent is online, delivers immediately.
// POST /v1/inventory/install-skill
func (h *InventoryHandler) HandleInstallSkill(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 256*1024)
	var req struct {
		TargetDeviceID   string `json:"targetDeviceId"`
		SenderDeviceID   string `json:"senderDeviceId"`
		EncryptedPayload string `json:"encryptedPayload"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}
	if req.TargetDeviceID == "" || req.SenderDeviceID == "" || req.EncryptedPayload == "" {
		writeError(w, "targetDeviceId, senderDeviceId, and encryptedPayload are required", http.StatusBadRequest)
		return
	}

	// Verify target device belongs to user.
	targetDevice, err := db.GetDevice(h.DB, req.TargetDeviceID)
	if err != nil {
		writeError(w, "target device not found", http.StatusNotFound)
		return
	}
	if targetDevice.UserID != userID {
		writeError(w, "forbidden", http.StatusForbidden)
		return
	}

	// Store encrypted payload for offline delivery.
	pendingID, err := db.InsertPendingSkillInstall(h.DB, req.TargetDeviceID, req.SenderDeviceID, userID, req.EncryptedPayload)
	if err != nil {
		slog.Error("insert pending skill install failed", "error", err)
		writeError(w, "failed to store skill install", http.StatusInternalServerError)
		return
	}

	// Try immediate delivery if agent is online.
	delivered := false
	payload, _ := json.Marshal(map[string]string{
		"id":               pendingID,
		"senderDeviceId":   req.SenderDeviceID,
		"encryptedPayload": req.EncryptedPayload,
	})
	wsMsg := &model.WSMessage{
		Type:    "server.install.skill",
		Payload: json.RawMessage(payload),
	}
	if err := h.Hub.SendToAgent(req.TargetDeviceID, wsMsg); err == nil {
		delivered = true
	}

	status := "queued"
	if delivered {
		status = "delivered"
	}

	slog.Info("install-skill", "target", req.TargetDeviceID, "status", status, "user", userID)
	writeJSON(w, http.StatusOK, map[string]string{"status": status})
}

// HandleGetSharedSkills returns aggregated slash commands from all devices for pro/contributor users.
// GET /v1/inventory/shared-skills
func (h *InventoryHandler) HandleGetSharedSkills(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	// Check tier.
	tier, err := db.GetUserTier(h.DB, userID)
	if err != nil {
		slog.Error("get user tier failed", "user_id", userID, "error", err)
		writeError(w, "failed to check subscription", http.StatusInternalServerError)
		return
	}
	if tier != "pro" && tier != "contributor" {
		writeJSON(w, http.StatusPaymentRequired, map[string]string{"error": "pro_required"})
		return
	}

	rows, err := db.ListUserInventory(h.DB, userID)
	if err != nil {
		slog.Error("list user inventory for shared skills failed", "user_id", userID, "error", err)
		writeError(w, "failed to list inventory", http.StatusInternalServerError)
		return
	}

	type sharedCommand struct {
		Name             string `json:"name"`
		Description      string `json:"description"`
		Content          string `json:"content"`
		SourceDeviceID   string `json:"sourceDeviceId"`
		SourceDeviceName string `json:"sourceDeviceName"`
	}

	// Deduplicate by command name, keeping the most recent source.
	seen := make(map[string]bool)
	var commands []sharedCommand

	for _, row := range rows {
		var inv struct {
			GlobalCommands []struct {
				Name        string `json:"name"`
				Description string `json:"description"`
				Content     string `json:"content"`
			} `json:"globalCommands"`
		}
		if err := json.Unmarshal([]byte(row.InventoryJSON), &inv); err != nil {
			continue
		}
		for _, cmd := range inv.GlobalCommands {
			if seen[cmd.Name] {
				continue
			}
			seen[cmd.Name] = true
			commands = append(commands, sharedCommand{
				Name:             cmd.Name,
				Description:      cmd.Description,
				Content:          cmd.Content,
				SourceDeviceID:   row.DeviceID,
				SourceDeviceName: row.DeviceName,
			})
		}
	}

	if commands == nil {
		commands = []sharedCommand{}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"commands": commands,
	})
}
