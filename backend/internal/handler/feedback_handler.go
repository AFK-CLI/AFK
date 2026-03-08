package handler

import (
	"database/sql"
	"encoding/json"
	"html"
	"net/http"
	"strconv"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
)

type FeedbackHandler struct {
	DB *sql.DB
}

// HandleList handles GET /v1/feedback?limit=50&offset=0
func (h *FeedbackHandler) HandleList(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil && parsed > 0 {
			limit = parsed
		}
	}
	if limit > 200 {
		limit = 200
	}

	offset := 0
	if v := r.URL.Query().Get("offset"); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil && parsed >= 0 {
			offset = parsed
		}
	}

	entries, err := db.ListFeedback(h.DB, userID, limit, offset)
	if err != nil {
		writeError(w, "failed to list feedback", http.StatusInternalServerError)
		return
	}

	if entries == nil {
		entries = []*model.Feedback{}
	}

	writeJSON(w, http.StatusOK, entries)
}

// HandleCreate handles POST /v1/feedback
func (h *FeedbackHandler) HandleCreate(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 64*1024) // 64 KB
	var req model.CreateFeedbackRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	validCategories := map[string]bool{"bug_report": true, "feature_request": true, "general": true}
	if !validCategories[req.Category] {
		req.Category = "general"
	}

	if req.Message == "" {
		writeError(w, "message is required", http.StatusBadRequest)
		return
	}
	if len(req.Message) > 5000 {
		req.Message = req.Message[:5000]
	}
	req.Message = html.EscapeString(req.Message)

	f := &model.Feedback{
		UserID:     userID,
		DeviceID:   req.DeviceID,
		Category:   req.Category,
		Message:    req.Message,
		AppVersion: req.AppVersion,
		Platform:   req.Platform,
	}

	if err := db.CreateFeedback(h.DB, f); err != nil {
		writeError(w, "failed to create feedback", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusCreated, f)
}
