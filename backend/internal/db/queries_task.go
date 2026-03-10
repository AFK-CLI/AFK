package db

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/model"
)

// nullStr converts an empty string to sql.NullString{Valid: false} (NULL in DB).
func nullStr(s string) sql.NullString {
	if s == "" {
		return sql.NullString{}
	}
	return sql.NullString{String: s, Valid: true}
}

func UpsertClaudeTask(database *sql.DB, t *model.Task) error {
	if t.ID == "" {
		t.ID = auth.GenerateID()
	}
	now := time.Now().UTC().Format(time.RFC3339)
	if t.CreatedAt == "" {
		t.CreatedAt = now
	}
	t.UpdatedAt = now

	_, err := database.Exec(`
		INSERT INTO tasks (id, user_id, session_id, project_id, source, session_local_id, subject, description, status, active_form, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
		ON CONFLICT(session_id, session_local_id) WHERE source = 'claude_code' DO UPDATE SET
			subject = CASE WHEN excluded.subject != '' THEN excluded.subject ELSE tasks.subject END,
			description = CASE WHEN excluded.description != '' THEN excluded.description ELSE tasks.description END,
			status = excluded.status,
			active_form = CASE WHEN excluded.active_form != '' THEN excluded.active_form ELSE tasks.active_form END,
			updated_at = excluded.updated_at
	`, t.ID, t.UserID, nullStr(t.SessionID), nullStr(t.ProjectID), t.Source, nullStr(t.SessionLocalID),
		t.Subject, t.Description, t.Status, t.ActiveForm, t.CreatedAt, t.UpdatedAt)
	if err != nil {
		return fmt.Errorf("upsert claude task: %w", err)
	}
	return nil
}

func CreateUserTask(database *sql.DB, t *model.Task) error {
	if t.ID == "" {
		t.ID = auth.GenerateID()
	}
	now := time.Now().UTC().Format(time.RFC3339)
	t.CreatedAt = now
	t.UpdatedAt = now
	t.Source = "user"

	_, err := database.Exec(`
		INSERT INTO tasks (id, user_id, session_id, project_id, source, subject, description, status, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
	`, t.ID, t.UserID, nullStr(t.SessionID), nullStr(t.ProjectID), t.Source, t.Subject, t.Description, t.Status, t.CreatedAt, t.UpdatedAt)
	if err != nil {
		return fmt.Errorf("create user task: %w", err)
	}
	return nil
}

func GetTask(database *sql.DB, taskID string) (*model.Task, error) {
	t := &model.Task{}
	var sessionID, projectID, sessionLocalID, activeForm, projectName sql.NullString
	err := database.QueryRow(`
		SELECT t.id, t.user_id, t.session_id, t.project_id, t.source, t.session_local_id,
			t.subject, t.description, t.status, t.active_form, t.created_at, t.updated_at,
			p.name
		FROM tasks t LEFT JOIN projects p ON t.project_id = p.id
		WHERE t.id = $1
	`, taskID).Scan(&t.ID, &t.UserID, &sessionID, &projectID, &t.Source, &sessionLocalID,
		&t.Subject, &t.Description, &t.Status, &activeForm, &t.CreatedAt, &t.UpdatedAt,
		&projectName)
	if err != nil {
		return nil, fmt.Errorf("get task: %w", err)
	}
	if sessionID.Valid {
		t.SessionID = sessionID.String
	}
	if projectID.Valid {
		t.ProjectID = projectID.String
	}
	if sessionLocalID.Valid {
		t.SessionLocalID = sessionLocalID.String
	}
	if activeForm.Valid {
		t.ActiveForm = activeForm.String
	}
	if projectName.Valid {
		t.ProjectName = projectName.String
	}
	return t, nil
}

func GetTaskBySessionLocalID(database *sql.DB, sessionID, localID string) (*model.Task, error) {
	t := &model.Task{}
	var sessID, projectID, sessionLocalID, activeForm, projectName sql.NullString
	err := database.QueryRow(`
		SELECT t.id, t.user_id, t.session_id, t.project_id, t.source, t.session_local_id,
			t.subject, t.description, t.status, t.active_form, t.created_at, t.updated_at,
			p.name
		FROM tasks t LEFT JOIN projects p ON t.project_id = p.id
		WHERE t.session_id = $1 AND t.session_local_id = $2 AND t.source = 'claude_code'
	`, sessionID, localID).Scan(&t.ID, &t.UserID, &sessID, &projectID, &t.Source, &sessionLocalID,
		&t.Subject, &t.Description, &t.Status, &activeForm, &t.CreatedAt, &t.UpdatedAt,
		&projectName)
	if err != nil {
		return nil, fmt.Errorf("get task by session local id: %w", err)
	}
	if sessID.Valid {
		t.SessionID = sessID.String
	}
	if projectID.Valid {
		t.ProjectID = projectID.String
	}
	if sessionLocalID.Valid {
		t.SessionLocalID = sessionLocalID.String
	}
	if activeForm.Valid {
		t.ActiveForm = activeForm.String
	}
	if projectName.Valid {
		t.ProjectName = projectName.String
	}
	return t, nil
}

func ListTasks(database *sql.DB, userID string, source, projectID, status string, limit, offset int) ([]*model.Task, error) {
	query := `
		SELECT t.id, t.user_id, t.session_id, t.project_id, t.source, t.session_local_id,
			t.subject, t.description, t.status, t.active_form, t.created_at, t.updated_at,
			p.name
		FROM tasks t LEFT JOIN projects p ON t.project_id = p.id
		WHERE t.user_id = $1`
	args := []any{userID}
	argPos := 2

	if source != "" {
		query += fmt.Sprintf(" AND t.source = $%d", argPos)
		args = append(args, source)
		argPos++
	}
	if projectID != "" {
		query += fmt.Sprintf(" AND t.project_id = $%d", argPos)
		args = append(args, projectID)
		argPos++
	}
	if status != "" {
		query += fmt.Sprintf(" AND t.status = $%d", argPos)
		args = append(args, status)
		argPos++
	}

	query += fmt.Sprintf(" ORDER BY t.updated_at DESC LIMIT $%d OFFSET $%d", argPos, argPos+1)
	args = append(args, limit, offset)

	rows, err := database.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("list tasks: %w", err)
	}
	defer rows.Close()

	var tasks []*model.Task
	for rows.Next() {
		t := &model.Task{}
		var sessionID, projectIDVal, sessionLocalID, activeForm, projectName sql.NullString
		if err := rows.Scan(&t.ID, &t.UserID, &sessionID, &projectIDVal, &t.Source, &sessionLocalID,
			&t.Subject, &t.Description, &t.Status, &activeForm, &t.CreatedAt, &t.UpdatedAt,
			&projectName); err != nil {
			return nil, fmt.Errorf("scan task: %w", err)
		}
		if sessionID.Valid {
			t.SessionID = sessionID.String
		}
		if projectIDVal.Valid {
			t.ProjectID = projectIDVal.String
		}
		if sessionLocalID.Valid {
			t.SessionLocalID = sessionLocalID.String
		}
		if activeForm.Valid {
			t.ActiveForm = activeForm.String
		}
		if projectName.Valid {
			t.ProjectName = projectName.String
		}
		tasks = append(tasks, t)
	}
	return tasks, nil
}

func UpdateTask(database *sql.DB, taskID string, subject, description, status *string) error {
	now := time.Now().UTC().Format(time.RFC3339)
	sets := []string{"updated_at = $1"}
	args := []any{now}
	argPos := 2

	if subject != nil {
		sets = append(sets, fmt.Sprintf("subject = $%d", argPos))
		args = append(args, *subject)
		argPos++
	}
	if description != nil {
		sets = append(sets, fmt.Sprintf("description = $%d", argPos))
		args = append(args, *description)
		argPos++
	}
	if status != nil {
		sets = append(sets, fmt.Sprintf("status = $%d", argPos))
		args = append(args, *status)
		argPos++
	}

	args = append(args, taskID)
	_, err := database.Exec(
		fmt.Sprintf("UPDATE tasks SET %s WHERE id = $%d", strings.Join(sets, ", "), argPos),
		args...,
	)
	if err != nil {
		return fmt.Errorf("update task: %w", err)
	}
	return nil
}

func DeleteTask(database *sql.DB, taskID string) error {
	_, err := database.Exec("DELETE FROM tasks WHERE id = $1", taskID)
	if err != nil {
		return fmt.Errorf("delete task: %w", err)
	}
	return nil
}

func CountClaudeTasksBySession(database *sql.DB, sessionID string) (int, error) {
	var count int
	err := database.QueryRow(
		"SELECT COUNT(*) FROM tasks WHERE session_id = $1 AND source = 'claude_code'",
		sessionID,
	).Scan(&count)
	if err != nil {
		return 0, fmt.Errorf("count claude tasks: %w", err)
	}
	return count, nil
}

// Todos

func UpsertTodo(database *sql.DB, userID, projectPath, projectID, contentHash, rawContent, itemsJSON string) error {
	now := time.Now().UTC().Format(time.RFC3339)
	id := auth.GenerateID()
	_, err := database.Exec(`
		INSERT INTO todos (id, user_id, project_path, project_id, content_hash, raw_content, items_json, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		ON CONFLICT(user_id, project_path) DO UPDATE SET
			project_id = excluded.project_id,
			content_hash = excluded.content_hash,
			raw_content = excluded.raw_content,
			items_json = excluded.items_json,
			updated_at = excluded.updated_at
	`, id, userID, projectPath, projectID, contentHash, rawContent, itemsJSON, now)
	if err != nil {
		return fmt.Errorf("upsert todo: %w", err)
	}
	return nil
}

func ListTodos(database *sql.DB, userID string) ([]*model.TodoState, error) {
	rows, err := database.Query(`
		SELECT t.project_id, t.project_path, COALESCE(p.name, ''), t.raw_content, t.items_json, t.updated_at
		FROM todos t
		LEFT JOIN projects p ON t.project_id = p.id
		WHERE t.user_id = $1
		ORDER BY t.updated_at DESC
	`, userID)
	if err != nil {
		return nil, fmt.Errorf("list todos: %w", err)
	}
	defer rows.Close()

	var todos []*model.TodoState
	for rows.Next() {
		td := &model.TodoState{}
		var itemsJSON string
		if err := rows.Scan(&td.ProjectID, &td.ProjectPath, &td.ProjectName, &td.RawContent, &itemsJSON, &td.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scan todo: %w", err)
		}
		if err := json.Unmarshal([]byte(itemsJSON), &td.Items); err != nil {
			td.Items = []model.TodoItem{}
		}
		todos = append(todos, td)
	}
	return todos, rows.Err()
}

func GetTodoByProject(database *sql.DB, userID, projectID string) (*model.TodoState, error) {
	td := &model.TodoState{}
	var itemsJSON string
	err := database.QueryRow(`
		SELECT t.project_id, t.project_path, COALESCE(p.name, ''), t.raw_content, t.items_json, t.updated_at
		FROM todos t
		LEFT JOIN projects p ON t.project_id = p.id
		WHERE t.user_id = $1 AND t.project_id = $2
	`, userID, projectID).Scan(&td.ProjectID, &td.ProjectPath, &td.ProjectName, &td.RawContent, &itemsJSON, &td.UpdatedAt)
	if err != nil {
		return nil, fmt.Errorf("get todo by project: %w", err)
	}
	if err := json.Unmarshal([]byte(itemsJSON), &td.Items); err != nil {
		td.Items = []model.TodoItem{}
	}
	return td, nil
}
