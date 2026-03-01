package handler

import (
	"database/sql"
	"net/http"
	"strconv"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
)

type SessionHandler struct {
	DB *sql.DB
}

func (h *SessionHandler) HandleList(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	deviceID := r.URL.Query().Get("deviceId")
	status := r.URL.Query().Get("status")

	sessions, err := db.ListSessions(h.DB, userID, deviceID, status)
	if err != nil {
		writeError(w, "failed to list sessions", http.StatusInternalServerError)
		return
	}

	if sessions == nil {
		sessions = []*model.Session{}
	}

	writeJSON(w, http.StatusOK, sessions)
}

func (h *SessionHandler) HandleDetail(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	sessionID := r.PathValue("id")
	if sessionID == "" {
		writeError(w, "session id is required", http.StatusBadRequest)
		return
	}

	session, err := db.GetSession(h.DB, sessionID)
	if err != nil {
		writeError(w, "session not found", http.StatusNotFound)
		return
	}

	if session.UserID != userID {
		writeError(w, "forbidden", http.StatusForbidden)
		return
	}

	// Parse pagination parameters
	limit := 100
	if l, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && l > 0 {
		limit = l
	}
	if limit > 500 {
		limit = 500
	}

	afterSeqStr := r.URL.Query().Get("after_seq")
	beforeSeqStr := r.URL.Query().Get("before_seq")

	var events []*model.SessionEvent
	var hasMore bool

	switch {
	case beforeSeqStr != "":
		// Reverse pagination: load older events before a given seq
		beforeSeq, _ := strconv.Atoi(beforeSeqStr)
		events, hasMore, err = db.ListEventsBefore(h.DB, sessionID, limit, beforeSeq)
	case afterSeqStr != "":
		// Forward pagination: load newer events after a given seq
		afterSeq, _ := strconv.Atoi(afterSeqStr)
		events, hasMore, err = db.ListEvents(h.DB, sessionID, limit, afterSeq)
	default:
		// Initial load: return the latest events
		events, hasMore, err = db.ListEventsLatest(h.DB, sessionID, limit)
	}

	if err != nil {
		events = []*model.SessionEvent{}
		hasMore = false
	}
	// Ensure non-nil slice so JSON marshals as [] not null
	if events == nil {
		events = []*model.SessionEvent{}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"session": session,
		"events":  events,
		"hasMore": hasMore,
	})
}
