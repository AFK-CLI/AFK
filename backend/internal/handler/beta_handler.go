package handler

import (
	"database/sql"
	"encoding/json"
	"html"
	"net/http"
	"net/mail"
	"strings"

	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
)

type BetaHandler struct {
	DB *sql.DB
}

// HandleBetaRequest handles POST /v1/beta/request (unauthenticated, rate-limited).
func (h *BetaHandler) HandleBetaRequest(w http.ResponseWriter, r *http.Request) {
	// Require JSON content type.
	ct := r.Header.Get("Content-Type")
	if !strings.HasPrefix(ct, "application/json") {
		writeError(w, "Content-Type must be application/json", http.StatusUnsupportedMediaType)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 4*1024) // 4 KB max

	var req struct {
		Email string `json:"email"`
		Name  string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	// Validate email.
	email := strings.TrimSpace(strings.ToLower(req.Email))
	if email == "" {
		writeError(w, "email is required", http.StatusBadRequest)
		return
	}
	if len(email) > 254 {
		writeError(w, "email too long", http.StatusBadRequest)
		return
	}
	if _, err := mail.ParseAddress(email); err != nil {
		writeError(w, "invalid email address", http.StatusBadRequest)
		return
	}

	// Sanitize name.
	name := strings.TrimSpace(req.Name)
	if len(name) > 100 {
		name = name[:100]
	}
	name = html.EscapeString(name)

	betaReq := &model.BetaRequest{
		Email: email,
		Name:  name,
	}

	if err := db.CreateBetaRequest(h.DB, betaReq); err != nil {
		if strings.Contains(err.Error(), "already registered") {
			writeJSON(w, http.StatusConflict, map[string]string{"error": "already registered"})
			return
		}
		writeError(w, "failed to submit request", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
