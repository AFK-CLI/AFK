package handler

import (
	"crypto/subtle"
	"database/sql"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"

	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
)

// redactEmail returns a privacy-safe representation: first char + "***@" + domain.
func redactEmail(email string) string {
	parts := strings.SplitN(email, "@", 2)
	if len(parts) != 2 || len(parts[0]) == 0 {
		return "***"
	}
	return string(parts[0][0]) + "***@" + parts[1]
}

type AdminHandler struct {
	DB          *sql.DB
	AdminSecret string
}

// HandleGrantContributor grants lifetime contributor tier to a user.
// POST /v1/admin/grant-contributor
// Authenticated via X-Admin-Secret header (CLI/curl use, not from iOS app).
func (h *AdminHandler) HandleGrantContributor(w http.ResponseWriter, r *http.Request) {
	if h.AdminSecret == "" {
		writeError(w, "admin API not configured", http.StatusServiceUnavailable)
		return
	}

	secret := r.Header.Get("X-Admin-Secret")
	if subtle.ConstantTimeCompare([]byte(secret), []byte(h.AdminSecret)) != 1 {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 64*1024) // 64 KB
	var req struct {
		Email  string `json:"email"`
		UserID string `json:"userId"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if req.Email == "" && req.UserID == "" {
		writeError(w, "email or userId is required", http.StatusBadRequest)
		return
	}

	// Look up user by email or ID.
	var user *model.User
	var err error
	if req.UserID != "" {
		user, err = db.GetUser(h.DB, req.UserID)
	} else {
		user, err = db.GetUserByEmail(h.DB, req.Email)
	}
	if err != nil {
		writeError(w, "user not found", http.StatusNotFound)
		return
	}

	// Set contributor tier with no expiry (lifetime).
	if err := db.UpdateUserSubscription(h.DB, user.ID, "contributor", "", "", nil); err != nil {
		slog.Error("failed to grant contributor tier", "user_id", user.ID, "error", err)
		writeError(w, "failed to update subscription", http.StatusInternalServerError)
		return
	}

	slog.Info("contributor tier granted", "user_id", user.ID, "email", redactEmail(user.Email))

	// Audit log.
	details, _ := json.Marshal(map[string]string{
		"user_id": user.ID,
		"email":   user.Email,
		"tier":    "contributor",
	})
	_ = db.InsertAuditLog(h.DB, &model.AuditLogEntry{
		UserID:  user.ID,
		Action:  "contributor_granted",
		Details: string(details),
	})

	// Return updated user info.
	user.SubscriptionTier = "contributor"
	user.SubscriptionExpiresAt = nil
	writeJSON(w, http.StatusOK, user)
}
