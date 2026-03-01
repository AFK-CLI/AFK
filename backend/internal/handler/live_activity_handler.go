package handler

import (
	"database/sql"
	"encoding/json"
	"net/http"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/ws"
)

// HandleRegisterLiveActivityToken registers a Live Activity push token for a session.
func HandleRegisterLiveActivityToken(hub *ws.Hub, database *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID := auth.UserIDFromContext(r.Context())
		if userID == "" {
			writeError(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		sessionID := r.PathValue("id")
		if sessionID == "" {
			writeError(w, "missing session id", http.StatusBadRequest)
			return
		}

		// Verify session ownership.
		session, err := db.GetSession(database, sessionID)
		if err != nil {
			writeError(w, "session not found", http.StatusNotFound)
			return
		}
		if session.UserID != userID {
			writeError(w, "forbidden", http.StatusForbidden)
			return
		}

		r.Body = http.MaxBytesReader(w, r.Body, 1<<20) // 1 MB
		var req struct {
			PushToken string `json:"pushToken"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, "invalid request body", http.StatusBadRequest)
			return
		}

		if req.PushToken == "" {
			writeError(w, "pushToken is required", http.StatusBadRequest)
			return
		}

		if hub != nil && hub.Notifier != nil {
			hub.Notifier.RegisterLiveActivityToken(sessionID, req.PushToken)
		}

		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}
