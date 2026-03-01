package handler

import (
	"database/sql"
	"net/http"
	"strconv"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
)

type AuditHandler struct {
	DB *sql.DB
}

// HandleList handles GET /v1/audit?limit=50&offset=0
func (h *AuditHandler) HandleList(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	// Parse limit with default 50 and max 200.
	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil && parsed > 0 {
			limit = parsed
		}
	}
	if limit > 200 {
		limit = 200
	}

	// Parse offset with default 0.
	offset := 0
	if v := r.URL.Query().Get("offset"); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil && parsed >= 0 {
			offset = parsed
		}
	}

	entries, err := db.ListAuditLog(h.DB, userID, limit, offset)
	if err != nil {
		writeError(w, "failed to list audit log", http.StatusInternalServerError)
		return
	}

	if entries == nil {
		entries = []*model.AuditLogEntry{}
	}

	writeJSON(w, http.StatusOK, entries)
}
