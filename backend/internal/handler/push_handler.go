package handler

import (
	"database/sql"
	"encoding/json"
	"net/http"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
)

type PushHandler struct {
	DB *sql.DB
}

func (h *PushHandler) HandleRegister(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 64*1024) // 64 KB
	var req model.RegisterPushTokenRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if req.DeviceToken == "" {
		writeError(w, "deviceToken is required", http.StatusBadRequest)
		return
	}
	if len(req.DeviceToken) > 200 {
		writeError(w, "deviceToken exceeds maximum length", http.StatusBadRequest)
		return
	}
	if len(req.BundleID) > 200 {
		writeError(w, "bundleId exceeds maximum length", http.StatusBadRequest)
		return
	}

	platform := req.Platform
	if platform == "" {
		platform = "ios"
	}
	if platform != "ios" && platform != "macos" {
		writeError(w, "platform must be ios or macos", http.StatusBadRequest)
		return
	}

	if err := db.UpsertPushToken(h.DB, userID, req.DeviceToken, platform, req.BundleID); err != nil {
		writeError(w, "failed to register push token", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (h *PushHandler) HandleDelete(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 64*1024) // 64 KB
	var req struct {
		DeviceToken string `json:"deviceToken"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if req.DeviceToken == "" {
		writeError(w, "deviceToken is required", http.StatusBadRequest)
		return
	}

	if err := db.DeletePushTokenForUser(h.DB, req.DeviceToken, userID); err != nil {
		writeError(w, "failed to delete push token", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
