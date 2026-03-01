package handler

import (
	"database/sql"
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"
	"strings"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
)

// validTaskStatuses defines the allowed values for task status fields.
var validTaskStatuses = map[string]bool{
	"pending":    true,
	"in_progress": true,
	"completed":  true,
	"cancelled":  true,
}

// sanitizeTaskText strips HTML angle brackets from task text fields.
func sanitizeTaskText(s string) string {
	r := strings.NewReplacer("<", "", ">", "")
	return r.Replace(s)
}

type TaskHandler struct {
	DB *sql.DB
}

func (h *TaskHandler) HandleList(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	source := r.URL.Query().Get("source")
	projectID := r.URL.Query().Get("project_id")
	status := r.URL.Query().Get("status")

	limit := 100
	if l := r.URL.Query().Get("limit"); l != "" {
		if n, err := strconv.Atoi(l); err == nil && n > 0 && n <= 500 {
			limit = n
		}
	}
	offset := 0
	if o := r.URL.Query().Get("offset"); o != "" {
		if n, err := strconv.Atoi(o); err == nil && n >= 0 {
			offset = n
		}
	}

	tasks, err := db.ListTasks(h.DB, userID, source, projectID, status, limit, offset)
	if err != nil {
		slog.Error("list tasks failed", "user_id", userID, "error", err)
		writeError(w, "failed to list tasks", http.StatusInternalServerError)
		return
	}

	if tasks == nil {
		tasks = []*model.Task{}
	}

	writeJSON(w, http.StatusOK, tasks)
}

func (h *TaskHandler) HandleCreate(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 1<<20) // 1 MB
	var req model.CreateTaskRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if req.Subject == "" {
		writeError(w, "subject is required", http.StatusBadRequest)
		return
	}

	task := &model.Task{
		UserID:      userID,
		ProjectID:   req.ProjectID,
		Source:      "user",
		Subject:     sanitizeTaskText(req.Subject),
		Description: sanitizeTaskText(req.Description),
		Status:      "pending",
	}

	if err := db.CreateUserTask(h.DB, task); err != nil {
		slog.Error("create task failed", "user_id", userID, "error", err)
		writeError(w, "failed to create task", http.StatusInternalServerError)
		return
	}

	// Refetch to get joined project name.
	saved, err := db.GetTask(h.DB, task.ID)
	if err == nil {
		task = saved
	}

	writeJSON(w, http.StatusCreated, task)
}

func (h *TaskHandler) HandleUpdate(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	taskID := r.PathValue("id")
	if taskID == "" {
		writeError(w, "task id is required", http.StatusBadRequest)
		return
	}

	// Verify ownership.
	task, err := db.GetTask(h.DB, taskID)
	if err != nil {
		writeError(w, "task not found", http.StatusNotFound)
		return
	}
	if task.UserID != userID {
		writeError(w, "forbidden", http.StatusForbidden)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 1<<20) // 1 MB
	var req model.UpdateTaskRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	// Validate status if provided.
	if req.Status != nil && !validTaskStatuses[*req.Status] {
		writeError(w, "invalid status value", http.StatusBadRequest)
		return
	}

	// Sanitize text fields.
	if req.Subject != nil {
		s := sanitizeTaskText(*req.Subject)
		req.Subject = &s
	}
	if req.Description != nil {
		s := sanitizeTaskText(*req.Description)
		req.Description = &s
	}

	if err := db.UpdateTask(h.DB, taskID, req.Subject, req.Description, req.Status); err != nil {
		writeError(w, "failed to update task", http.StatusInternalServerError)
		return
	}

	updated, err := db.GetTask(h.DB, taskID)
	if err != nil {
		writeError(w, "failed to fetch updated task", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, updated)
}

func (h *TaskHandler) HandleDelete(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	taskID := r.PathValue("id")
	if taskID == "" {
		writeError(w, "task id is required", http.StatusBadRequest)
		return
	}

	// Verify ownership and source.
	task, err := db.GetTask(h.DB, taskID)
	if err != nil {
		writeError(w, "task not found", http.StatusNotFound)
		return
	}
	if task.UserID != userID {
		writeError(w, "forbidden", http.StatusForbidden)
		return
	}
	if task.Source != "user" {
		writeError(w, "only user tasks can be deleted", http.StatusBadRequest)
		return
	}

	if err := db.DeleteTask(h.DB, taskID); err != nil {
		writeError(w, "failed to delete task", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}
