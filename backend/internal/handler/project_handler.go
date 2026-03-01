package handler

import (
	"database/sql"
	"net/http"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
)

type ProjectHandler struct {
	DB *sql.DB
}

func (h *ProjectHandler) HandleList(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	projects, err := db.ListProjects(h.DB, userID)
	if err != nil {
		writeError(w, "failed to list projects", http.StatusInternalServerError)
		return
	}

	if projects == nil {
		projects = []*model.Project{}
	}

	writeJSON(w, http.StatusOK, projects)
}
