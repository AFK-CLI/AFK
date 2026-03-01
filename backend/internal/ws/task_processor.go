package ws

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log/slog"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
)

// ProcessTaskEvent extracts task state from TaskCreate/TaskUpdate tool events
// and maintains the tasks table. Called from the agent.session.event handler.
func ProcessTaskEvent(hub *Hub, database *sql.DB, userID, sessionID string, data, content json.RawMessage) {
	if data == nil {
		return
	}

	var payload struct {
		ToolName string `json:"toolName"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return
	}

	switch payload.ToolName {
	case "TaskCreate":
		processTaskCreate(hub, database, userID, sessionID, content)
	case "TaskUpdate":
		processTaskUpdate(hub, database, userID, sessionID, content)
	default:
		return
	}
}

func processTaskCreate(hub *Hub, database *sql.DB, userID, sessionID string, content json.RawMessage) {
	fields := parseToolInputFields(content)
	if fields == nil {
		return
	}

	subject := fields["Subject"]
	description := fields["Description"]
	activeForm := fields["ActiveForm"]

	if subject == "" {
		slog.Debug("task_processor: TaskCreate with empty subject, skipping", "session_id", sessionID)
		return
	}

	// Assign sequential session_local_id.
	count, err := db.CountClaudeTasksBySession(database, sessionID)
	if err != nil {
		slog.Error("task_processor: count tasks failed", "session_id", sessionID, "error", err)
		return
	}
	localID := fmt.Sprintf("%d", count+1)

	// Look up session's project_id.
	var projectID string
	session, err := db.GetSession(database, sessionID)
	if err == nil && session != nil {
		projectID = session.ProjectID
	}

	task := &model.Task{
		ID:             auth.GenerateID(),
		UserID:         userID,
		SessionID:      sessionID,
		ProjectID:      projectID,
		Source:         "claude_code",
		SessionLocalID: localID,
		Subject:        subject,
		Description:    description,
		Status:         "pending",
		ActiveForm:     activeForm,
	}

	if err := db.UpsertClaudeTask(database, task); err != nil {
		slog.Error("task_processor: upsert claude task failed", "session_id", sessionID, "error", err)
		return
	}

	// Refetch to get joined project name.
	saved, err := db.GetTask(database, task.ID)
	if err == nil {
		task = saved
	}

	broadcastTaskUpdate(hub, userID, task)
	slog.Info("task_processor: created claude task", "task_id", task.ID, "session_local_id", localID, "subject", subject)
}

func processTaskUpdate(hub *Hub, database *sql.DB, userID, sessionID string, content json.RawMessage) {
	fields := parseToolInputFields(content)
	if fields == nil {
		return
	}

	taskID := fields["TaskID"]
	if taskID == "" {
		return
	}

	task, err := db.GetTaskBySessionLocalID(database, sessionID, taskID)
	if err != nil {
		slog.Debug("task_processor: task not found for update", "session_id", sessionID, "local_id", taskID)
		return
	}

	var subject, description, status *string
	if v, ok := fields["Status"]; ok && v != "" {
		status = &v
	}
	if v, ok := fields["Subject"]; ok && v != "" {
		subject = &v
	}
	if v, ok := fields["Description"]; ok && v != "" {
		description = &v
	}

	if err := db.UpdateTask(database, task.ID, subject, description, status); err != nil {
		slog.Error("task_processor: update task failed", "task_id", task.ID, "error", err)
		return
	}

	// Refetch to get updated state.
	updated, err := db.GetTask(database, task.ID)
	if err == nil {
		task = updated
	}

	broadcastTaskUpdate(hub, userID, task)
	slog.Info("task_processor: updated claude task", "task_id", task.ID, "status", task.Status)
}

func broadcastTaskUpdate(hub *Hub, userID string, task *model.Task) {
	msg, err := NewWSMessage("task.updated", model.TaskNotification{Task: task})
	if err != nil {
		slog.Error("task_processor: marshal task notification failed", "error", err)
		return
	}
	hub.BroadcastToUser(userID, msg)
}

// parseToolInputFields extracts the toolInputFields from event content as a label->value map.
func parseToolInputFields(content json.RawMessage) map[string]string {
	if content == nil {
		return nil
	}

	var contentMap map[string]json.RawMessage
	if err := json.Unmarshal(content, &contentMap); err != nil {
		return nil
	}

	fieldsRaw, ok := contentMap["toolInputFields"]
	if !ok {
		return nil
	}

	// toolInputFields is a JSON string containing an array, not a raw array.
	var fieldsStr string
	if err := json.Unmarshal(fieldsRaw, &fieldsStr); err != nil {
		// Try as raw array (fallback).
		var fields []struct {
			Label string `json:"label"`
			Value string `json:"value"`
		}
		if err := json.Unmarshal(fieldsRaw, &fields); err != nil {
			return nil
		}
		result := make(map[string]string, len(fields))
		for _, f := range fields {
			result[f.Label] = f.Value
		}
		return result
	}

	// Parse the JSON string.
	var fields []struct {
		Label string `json:"label"`
		Value string `json:"value"`
	}
	if err := json.Unmarshal([]byte(fieldsStr), &fields); err != nil {
		return nil
	}

	result := make(map[string]string, len(fields))
	for _, f := range fields {
		result[f.Label] = f.Value
	}
	return result
}
