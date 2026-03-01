package handler

import (
	"database/sql"
	"encoding/json"
	"net/http"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
)

type PushToStartHandler struct {
	DB *sql.DB
}

func (h *PushToStartHandler) HandleRegister(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 1<<20) // 1 MB
	var req struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if req.Token == "" {
		writeError(w, "token is required", http.StatusBadRequest)
		return
	}

	if err := db.UpsertPushToStartToken(h.DB, userID, req.Token); err != nil {
		writeError(w, "failed to register push-to-start token", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
