package handler

import (
	"net/http"

	"github.com/AFK/afk-cloud/internal/auth"
)

// HandleCreateTicket returns a handler that issues a single-use WebSocket ticket
// for the authenticated user. An optional "deviceId" query parameter can be
// supplied (used by agents to bind the ticket to a specific device).
func HandleCreateTicket(ticketStore *auth.TicketStore) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		userID := auth.UserIDFromContext(r.Context())
		if userID == "" {
			writeError(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		deviceID := r.URL.Query().Get("deviceId")

		ticket := ticketStore.Issue(userID, deviceID)

		writeJSON(w, http.StatusOK, map[string]string{
			"ticket": ticket,
		})
	}
}
