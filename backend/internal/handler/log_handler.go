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

type LogHandler struct {
	DB *sql.DB
}

// HandleList handles GET /v1/logs?level=&device_id=&source=&subsystem=&limit=50&offset=0
func (h *LogHandler) HandleList(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	q := r.URL.Query()
	level := q.Get("level")
	deviceID := q.Get("device_id")
	source := q.Get("source")
	subsystem := q.Get("subsystem")

	limit := 50
	if v := q.Get("limit"); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil && parsed > 0 {
			limit = parsed
		}
	}
	if limit > 200 {
		limit = 200
	}

	offset := 0
	if v := q.Get("offset"); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil && parsed >= 0 {
			offset = parsed
		}
	}

	logs, err := db.ListAppLogs(h.DB, userID, level, deviceID, source, subsystem, limit, offset)
	if err != nil {
		writeError(w, "failed to list logs", http.StatusInternalServerError)
		return
	}

	if logs == nil {
		logs = []*model.AppLog{}
	}

	writeJSON(w, http.StatusOK, logs)
}

// HandleBatch handles POST /v1/logs
func (h *LogHandler) HandleBatch(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 1<<20) // 1 MB limit

	var req model.BatchLogRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if len(req.Entries) == 0 {
		writeError(w, "entries required", http.StatusBadRequest)
		return
	}
	if len(req.Entries) > 100 {
		writeError(w, "max 100 entries per batch", http.StatusBadRequest)
		return
	}

	validLevels := map[string]bool{"debug": true, "info": true, "warn": true, "error": true}
	validSources := map[string]bool{"agent": true, "ios": true}

	for i := range req.Entries {
		e := &req.Entries[i]
		if !validLevels[e.Level] {
			e.Level = "info"
		}
		if !validSources[e.Source] {
			e.Source = "unknown"
		}
		if len(e.Message) > 4096 {
			e.Message = e.Message[:4096]
		}
		e.Message = html.EscapeString(e.Message)
		e.Subsystem = html.EscapeString(e.Subsystem)
	}

	if err := db.BatchInsertAppLogs(h.DB, userID, req.Entries); err != nil {
		writeError(w, "failed to insert logs", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}
