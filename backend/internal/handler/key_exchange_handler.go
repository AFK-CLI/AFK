package handler

import (
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
	"github.com/AFK/afk-cloud/internal/ws"
)

// keyFingerprintHex returns the first 8 hex characters of the SHA256 of a base64-encoded public key.
func keyFingerprintHex(publicKeyBase64 string) string {
	raw, err := base64.StdEncoding.DecodeString(publicKeyBase64)
	if err != nil {
		return "invalid"
	}
	hash := sha256.Sum256(raw)
	return hex.EncodeToString(hash[:4])
}

type KeyExchangeHandler struct {
	DB  *sql.DB
	Hub *ws.Hub
}

type RegisterKeyRequest struct {
	DeviceID  string `json:"deviceId"`
	PublicKey string `json:"publicKey"`
}

type GetPeerKeyResponse struct {
	DeviceID  string `json:"deviceId"`
	PublicKey string `json:"publicKey"`
}

// HandleRegisterKey registers a KeyAgreement public key for a device.
// POST /v1/devices/{id}/key-agreement
func (h *KeyExchangeHandler) HandleRegisterKey(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	deviceID := r.PathValue("id")
	if deviceID == "" {
		writeError(w, "device id required", http.StatusBadRequest)
		return
	}

	// Verify device belongs to this user.
	device, err := db.GetDevice(h.DB, deviceID)
	if err != nil {
		writeError(w, "device not found", http.StatusNotFound)
		return
	}
	if device.UserID != userID {
		writeError(w, "forbidden", http.StatusForbidden)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 64*1024) // 64 KB
	var req RegisterKeyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if req.PublicKey == "" {
		writeError(w, "publicKey is required", http.StatusBadRequest)
		return
	}

	// Validate base64 format and Curve25519 key length (32 bytes).
	keyBytes, err := base64.StdEncoding.DecodeString(req.PublicKey)
	if err != nil {
		writeError(w, "publicKey must be valid base64", http.StatusBadRequest)
		return
	}
	if len(keyBytes) != 32 {
		writeError(w, "publicKey must be exactly 32 bytes (Curve25519)", http.StatusBadRequest)
		return
	}

	// Idempotent: if the key hasn't changed, return current version without revocation or version bump.
	if device.KeyAgreementPublicKey == req.PublicKey {
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"version":   device.KeyVersion,
			"publicKey": req.PublicKey,
			"unchanged": true,
		})
		return
	}

	// Revoke old keys and insert new one.
	_ = db.RevokeDeviceKeys(h.DB, deviceID)

	newVersion := device.KeyVersion + 1
	if err := db.UpdateDeviceKeyAgreement(h.DB, deviceID, req.PublicKey, newVersion); err != nil {
		writeError(w, "failed to update key", http.StatusInternalServerError)
		return
	}

	dk := &model.DeviceKey{
		DeviceID:  deviceID,
		KeyType:   "key_agreement",
		PublicKey: req.PublicKey,
		Version:   newVersion,
		Active:    true,
	}
	if err := db.InsertDeviceKey(h.DB, dk); err != nil {
		slog.Error("failed to insert device key record", "device_id", deviceID, "error", err)
	}

	// Audit log with key fingerprint.
	keyFingerprint := keyFingerprintHex(req.PublicKey)
	_ = db.InsertAuditLog(h.DB, &model.AuditLogEntry{
		UserID:   userID,
		DeviceID: deviceID,
		Action:   "key_agreement_registered",
		Details:  fmt.Sprintf(`{"version":%d,"fingerprint":"%s"}`, newVersion, keyFingerprint),
	})

	slog.Info("registered key agreement key", "device_id", deviceID, "fingerprint", keyFingerprint, "version", newVersion)

	// Auto-upgrade privacy mode to encrypted when E2EE key is registered.
	if device.PrivacyMode != "encrypted" {
		_ = db.UpdateDevicePrivacyMode(h.DB, deviceID, "encrypted")
		slog.Info("auto-upgraded privacy mode to encrypted", "device_id", deviceID)
	}

	// Broadcast key rotation to ALL peers (iOS + agents) so they invalidate cached keys.
	if h.Hub != nil {
		rotatedMsg, err := ws.NewWSMessage("device.key_rotated", model.DeviceKeyRotated{
			DeviceID:   deviceID,
			KeyVersion: newVersion,
			PublicKey:  req.PublicKey,
		})
		if err == nil {
			h.Hub.BroadcastToAll(userID, rotatedMsg)
		}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"version":   newVersion,
		"publicKey": req.PublicKey,
	})
}

// HandleGetPeerKey returns a peer device's KeyAgreement public key for ECDH.
// GET /v1/devices/{id}/key-agreement
func (h *KeyExchangeHandler) HandleGetPeerKey(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	peerDeviceID := r.PathValue("id")
	if peerDeviceID == "" {
		writeError(w, "device id required", http.StatusBadRequest)
		return
	}

	pubKey, err := db.GetPeerKeyAgreementKey(h.DB, userID, peerDeviceID)
	if err != nil {
		writeError(w, "peer key not found", http.StatusNotFound)
		return
	}

	writeJSON(w, http.StatusOK, GetPeerKeyResponse{
		DeviceID:  peerDeviceID,
		PublicKey: pubKey,
	})
}

// HandleGetPeerKeyByVersion returns a historical KeyAgreement public key by version.
// GET /v1/devices/{id}/key-agreement/{version}
func (h *KeyExchangeHandler) HandleGetPeerKeyByVersion(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	peerDeviceID := r.PathValue("id")
	if peerDeviceID == "" {
		writeError(w, "device id required", http.StatusBadRequest)
		return
	}

	versionStr := r.PathValue("version")
	if versionStr == "" {
		writeError(w, "version required", http.StatusBadRequest)
		return
	}

	version, err := strconv.Atoi(versionStr)
	if err != nil || version < 1 {
		writeError(w, "invalid version", http.StatusBadRequest)
		return
	}

	// Verify peer device belongs to the same user.
	peerDevice, err := db.GetDevice(h.DB, peerDeviceID)
	if err != nil || peerDevice.UserID != userID {
		writeError(w, "device not found", http.StatusNotFound)
		return
	}

	key, err := db.GetDeviceKeyByVersion(h.DB, peerDeviceID, version)
	if err != nil {
		writeError(w, "key version not found", http.StatusNotFound)
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"deviceId":  peerDeviceID,
		"publicKey": key.PublicKey,
		"version":   key.Version,
		"active":    key.Active,
	})
}
