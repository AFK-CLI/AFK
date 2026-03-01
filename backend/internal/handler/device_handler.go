package handler

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"

	"database/sql"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
	"github.com/AFK/afk-cloud/internal/ws"
)

type DeviceHandler struct {
	DB  *sql.DB
	Hub *ws.Hub
}

func (h *DeviceHandler) HandleCreate(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 64*1024) // 64 KB
	var req model.EnrollDeviceRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if req.Name == "" || req.PublicKey == "" {
		writeError(w, "name and publicKey are required", http.StatusBadRequest)
		return
	}
	if len(req.Name) > 100 {
		writeError(w, "name exceeds maximum length", http.StatusBadRequest)
		return
	}
	if len(req.PublicKey) > 256 {
		writeError(w, "publicKey exceeds maximum length", http.StatusBadRequest)
		return
	}
	if len(req.SystemInfo) > 1024 {
		writeError(w, "systemInfo exceeds maximum length", http.StatusBadRequest)
		return
	}
	if len(req.KeyAgreementPublicKey) > 256 {
		writeError(w, "keyAgreementPublicKey exceeds maximum length", http.StatusBadRequest)
		return
	}

	// Serialize capabilities to JSON string for DB storage.
	capJSON, _ := json.Marshal(req.Capabilities)
	if req.Capabilities == nil {
		capJSON = []byte("[]")
	}
	if len(capJSON) > 1024 {
		writeError(w, "capabilities exceeds maximum length", http.StatusBadRequest)
		return
	}
	capStr := string(capJSON)

	var device *model.Device
	var reused bool

	// Try to reuse an existing device by explicit ID or fingerprint match.
	if req.DeviceID != "" {
		existing, err := db.GetDevice(h.DB, req.DeviceID)
		if err == nil && existing.UserID == userID {
			device, err = db.ReactivateDevice(h.DB, req.DeviceID, req.Name, req.PublicKey, req.SystemInfo, capStr)
			if err == nil {
				reused = true
				slog.Info("reactivated existing device", "device_id", req.DeviceID, "user_id", userID)
			}
		}
	}

	// Fingerprint dedup fallback: same user + name + system_info
	if device == nil {
		existing, err := db.FindDeviceByFingerprint(h.DB, userID, req.Name, req.SystemInfo)
		if err == nil {
			device, err = db.ReactivateDevice(h.DB, existing.ID, req.Name, req.PublicKey, req.SystemInfo, capStr)
			if err == nil {
				reused = true
				slog.Info("dedup reuse device by fingerprint", "device_id", existing.ID, "user_id", userID)
			}
		}
	}

	// Enforce device limits for free-tier users (only for genuinely new devices).
	if device == nil && !reused {
		tier, err := db.GetUserTier(h.DB, userID)
		if err != nil {
			writeError(w, "failed to check subscription", http.StatusInternalServerError)
			return
		}
		if tier == "free" {
			agentCount, iosCount, err := db.CountActiveDevicesByType(h.DB, userID)
			if err != nil {
				writeError(w, "failed to count devices", http.StatusInternalServerError)
				return
			}
			isIOS := len(req.SystemInfo) >= 3 && req.SystemInfo[:3] == "iOS"
			if isIOS && iosCount >= 1 {
				writeJSON(w, http.StatusPaymentRequired, map[string]string{
					"error": "Free plan allows 1 iOS device. Upgrade to Pro for unlimited devices.",
					"code":  "tier_required",
				})
				return
			}
			if !isIOS && agentCount >= 1 {
				writeJSON(w, http.StatusPaymentRequired, map[string]string{
					"error": "Free plan allows 1 agent. Upgrade to Pro for unlimited devices.",
					"code":  "tier_required",
				})
				return
			}
		}
	}

	// Create new device if no reuse happened.
	if device == nil {
		var err error
		device, err = db.CreateDevice(h.DB, userID, req.Name, req.PublicKey, req.SystemInfo, capStr)
		if err != nil {
			writeError(w, "failed to create device", http.StatusInternalServerError)
			return
		}
	}

	// Store KeyAgreement public key if provided at enrollment.
	if req.KeyAgreementPublicKey != "" {
		// Idempotent: skip write if the key is already the same.
		if device.KeyAgreementPublicKey == req.KeyAgreementPublicKey {
			slog.Info("key agreement key unchanged, skipping update", "device_id", device.ID)
		} else {
			newVersion := device.KeyVersion + 1
			if newVersion <= 0 {
				newVersion = 1
			}
			if err := db.UpdateDeviceKeyAgreement(h.DB, device.ID, req.KeyAgreementPublicKey, newVersion); err != nil {
				slog.Error("failed to store key agreement public key", "error", err)
			} else {
				device.KeyAgreementPublicKey = req.KeyAgreementPublicKey
				device.KeyVersion = newVersion
				// Also insert a device_keys record for audit trail.
				_ = db.InsertDeviceKey(h.DB, &model.DeviceKey{
					DeviceID:  device.ID,
					KeyType:   "key_agreement",
					PublicKey: req.KeyAgreementPublicKey,
					Version:   newVersion,
					Active:    true,
				})
				// Broadcast to all peers so they pick up the new key immediately.
				if h.Hub != nil {
					rotatedMsg, err := ws.NewWSMessage("device.key_rotated", model.DeviceKeyRotated{
						DeviceID:   device.ID,
						KeyVersion: newVersion,
						PublicKey:  req.KeyAgreementPublicKey,
					})
					if err == nil {
						h.Hub.BroadcastToAll(userID, rotatedMsg)
					}
				}
			}
		}
	}

	// Audit log: record device creation or reuse.
	action := "device_created"
	if reused {
		action = "device_reactivated"
	}
	details := fmt.Sprintf(`{"device_id":%q,"device_name":%q,"reused":%t}`, device.ID, device.Name, reused)
	_ = db.InsertAuditLog(h.DB, &model.AuditLogEntry{
		UserID:   userID,
		DeviceID: device.ID,
		Action:   action,
		Details:  details,
	})

	writeJSON(w, http.StatusCreated, device)
}

func (h *DeviceHandler) HandleList(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	devices, err := db.ListDevices(h.DB, userID)
	if err != nil {
		writeError(w, "failed to list devices", http.StatusInternalServerError)
		return
	}

	if devices == nil {
		devices = []*model.Device{}
	}

	writeJSON(w, http.StatusOK, devices)
}

func (h *DeviceHandler) HandleDelete(w http.ResponseWriter, r *http.Request) {
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

	if err := db.DeleteDevice(h.DB, deviceID, userID); err != nil {
		writeError(w, "device not found", http.StatusNotFound)
		return
	}

	// Audit log: record device deletion.
	details := fmt.Sprintf(`{"device_id":%q}`, deviceID)
	_ = db.InsertAuditLog(h.DB, &model.AuditLogEntry{
		UserID:   userID,
		DeviceID: deviceID,
		Action:   "device_deleted",
		Details:  details,
	})

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// validPrivacyMode checks whether the given mode is an accepted privacy mode.
func validPrivacyMode(mode string) bool {
	switch mode {
	case "telemetry_only", "relay_only", "encrypted":
		return true
	}
	return false
}

func (h *DeviceHandler) HandleSetPrivacyMode(w http.ResponseWriter, r *http.Request) {
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

	r.Body = http.MaxBytesReader(w, r.Body, 64*1024) // 64 KB
	var req model.SetPrivacyModeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if !validPrivacyMode(req.PrivacyMode) {
		writeError(w, "invalid privacy mode: must be telemetry_only, relay_only, or encrypted", http.StatusBadRequest)
		return
	}

	// Verify the device belongs to the requesting user.
	device, err := db.GetDevice(h.DB, deviceID)
	if err != nil {
		writeError(w, "device not found", http.StatusNotFound)
		return
	}
	if device.UserID != userID {
		writeError(w, "device not found", http.StatusNotFound)
		return
	}

	oldMode := device.PrivacyMode

	if err := db.UpdateDevicePrivacyMode(h.DB, deviceID, req.PrivacyMode); err != nil {
		writeError(w, "failed to update privacy mode", http.StatusInternalServerError)
		return
	}

	// Write audit log entry.
	details := fmt.Sprintf(`{"old_mode":%q,"new_mode":%q}`, oldMode, req.PrivacyMode)
	_ = db.InsertAuditLog(h.DB, &model.AuditLogEntry{
		UserID:   userID,
		DeviceID: deviceID,
		Action:   "privacy_mode_changed",
		Details:  details,
	})

	// Notify the agent of the privacy mode change via WebSocket.
	if h.Hub != nil {
		privacyMsg, err := ws.NewWSMessage("server.privacy_mode", map[string]string{
			"mode": req.PrivacyMode,
		})
		if err == nil {
			if err := h.Hub.SendToAgent(deviceID, privacyMsg); err != nil {
				slog.Error("failed to send privacy mode update to agent", "device_id", deviceID, "error", err)
			}
		}
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (h *DeviceHandler) HandleSetProjectPrivacy(w http.ResponseWriter, r *http.Request) {
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

	r.Body = http.MaxBytesReader(w, r.Body, 64*1024) // 64 KB
	var req model.SetProjectPrivacyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if !validPrivacyMode(req.PrivacyMode) {
		writeError(w, "invalid privacy mode: must be telemetry_only, relay_only, or encrypted", http.StatusBadRequest)
		return
	}

	// Verify the device belongs to the requesting user.
	device, err := db.GetDevice(h.DB, deviceID)
	if err != nil {
		writeError(w, "device not found", http.StatusNotFound)
		return
	}
	if device.UserID != userID {
		writeError(w, "device not found", http.StatusNotFound)
		return
	}

	if err := db.UpsertProjectPrivacy(h.DB, auth.GenerateID(), userID, deviceID, req.ProjectPathHash, req.PrivacyMode); err != nil {
		writeError(w, "failed to update project privacy", http.StatusInternalServerError)
		return
	}

	// Write audit log entry.
	details := fmt.Sprintf(`{"project_path_hash":%q,"privacy_mode":%q}`, req.ProjectPathHash, req.PrivacyMode)
	_ = db.InsertAuditLog(h.DB, &model.AuditLogEntry{
		UserID:   userID,
		DeviceID: deviceID,
		Action:   "project_privacy_changed",
		Details:  details,
	})

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
