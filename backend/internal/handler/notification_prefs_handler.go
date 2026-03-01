package handler

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"regexp"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
)

var timeFormatRe = regexp.MustCompile(`^([01]\d|2[0-3]):[0-5]\d$`)

type NotificationPrefsHandler struct {
	DB *sql.DB
}

func (h *NotificationPrefsHandler) HandleGet(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	prefs, err := db.GetNotificationPrefs(h.DB, userID)
	if err != nil {
		writeError(w, "failed to get notification preferences", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, prefs)
}

func (h *NotificationPrefsHandler) HandleUpdate(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 64*1024) // 64 KB
	var prefs model.NotificationPrefs
	if err := json.NewDecoder(r.Body).Decode(&prefs); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	// Validate quiet hours format (HH:MM).
	if prefs.QuietHoursStart != "" && !timeFormatRe.MatchString(prefs.QuietHoursStart) {
		writeError(w, "quietHoursStart must be in HH:MM format", http.StatusBadRequest)
		return
	}
	if prefs.QuietHoursEnd != "" && !timeFormatRe.MatchString(prefs.QuietHoursEnd) {
		writeError(w, "quietHoursEnd must be in HH:MM format", http.StatusBadRequest)
		return
	}

	if err := db.UpsertNotificationPrefs(h.DB, userID, &prefs); err != nil {
		writeError(w, "failed to update notification preferences", http.StatusInternalServerError)
		return
	}

	// Return the saved prefs.
	saved, err := db.GetNotificationPrefs(h.DB, userID)
	if err != nil {
		writeError(w, "failed to get notification preferences", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, saved)
}
