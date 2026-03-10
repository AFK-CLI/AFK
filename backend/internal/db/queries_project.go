package db

import (
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/model"
)

// Projects

func UpsertProject(db *sql.DB, p *model.Project) error {
	now := time.Now()
	if p.ID == "" {
		p.ID = auth.GenerateID()
	}
	_, err := db.Exec(`
		INSERT INTO projects (id, user_id, path, name, settings, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		ON CONFLICT(user_id, path) DO UPDATE SET
			name = excluded.name,
			updated_at = excluded.updated_at
	`, p.ID, p.UserID, p.Path, p.Name, p.Settings, now, now)
	if err != nil {
		return fmt.Errorf("upsert project: %w", err)
	}
	return nil
}

func GetProjectByID(db *sql.DB, userID, projectID string) (*model.Project, error) {
	p := &model.Project{}
	err := db.QueryRow(`
		SELECT id, user_id, path, name, settings, created_at, updated_at
		FROM projects WHERE id = $1 AND user_id = $2
	`, projectID, userID).Scan(&p.ID, &p.UserID, &p.Path, &p.Name, &p.Settings, &p.CreatedAt, &p.UpdatedAt)
	if err != nil {
		return nil, fmt.Errorf("get project by id: %w", err)
	}
	return p, nil
}

func GetProjectByPath(db *sql.DB, userID, path string) (*model.Project, error) {
	p := &model.Project{}
	err := db.QueryRow(`
		SELECT id, user_id, path, name, settings, created_at, updated_at
		FROM projects WHERE user_id = $1 AND path = $2
	`, userID, path).Scan(&p.ID, &p.UserID, &p.Path, &p.Name, &p.Settings, &p.CreatedAt, &p.UpdatedAt)
	if err != nil {
		return nil, fmt.Errorf("get project by path: %w", err)
	}
	return p, nil
}

func ListProjects(db *sql.DB, userID string) ([]*model.Project, error) {
	rows, err := db.Query(`
		SELECT id, user_id, path, name, settings, created_at, updated_at
		FROM projects WHERE user_id = $1
		ORDER BY updated_at DESC
	`, userID)
	if err != nil {
		return nil, fmt.Errorf("list projects: %w", err)
	}
	defer rows.Close()

	var projects []*model.Project
	for rows.Next() {
		p := &model.Project{}
		if err := rows.Scan(&p.ID, &p.UserID, &p.Path, &p.Name, &p.Settings, &p.CreatedAt, &p.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scan project: %w", err)
		}
		projects = append(projects, p)
	}
	return projects, rows.Err()
}

// resolveWorktreePath resolves worktree paths to their parent project path.
// e.g. "/path/to/AFK/.claude/worktrees/xyz" -> "/path/to/AFK"
func resolveWorktreePath(path string) string {
	if idx := strings.Index(path, "/.claude/worktrees/"); idx != -1 {
		return path[:idx]
	}
	return path
}

// EnsureProjectForSession auto-creates or retrieves a project based on the session's project_path.
// Worktree paths are resolved to their parent project so worktree sessions group correctly.
// Returns the project ID, or "" if project_path is empty.
func EnsureProjectForSession(db *sql.DB, userID, projectPath string) string {
	if projectPath == "" {
		return ""
	}

	// Resolve worktree paths to parent project path.
	resolvedPath := resolveWorktreePath(projectPath)

	// Try to get existing project by resolved path.
	p, err := GetProjectByPath(db, userID, resolvedPath)
	if err == nil {
		return p.ID
	}

	// Extract name from resolved path.
	name := resolvedPath
	for i := len(resolvedPath) - 1; i >= 0; i-- {
		if resolvedPath[i] == '/' {
			name = resolvedPath[i+1:]
			break
		}
	}

	newProject := &model.Project{
		UserID:   userID,
		Path:     resolvedPath,
		Name:     name,
		Settings: "{}",
	}
	if err := UpsertProject(db, newProject); err != nil {
		return ""
	}

	// Fetch the project to get the ID (may have been created by a race).
	p, err = GetProjectByPath(db, userID, resolvedPath)
	if err != nil {
		return ""
	}
	return p.ID
}

// Project Privacy

func UpsertProjectPrivacy(db *sql.DB, id, userID, deviceID, projectPathHash, privacyMode string) error {
	now := time.Now()
	_, err := db.Exec(`
		INSERT INTO project_privacy (id, user_id, device_id, project_path_hash, privacy_mode, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		ON CONFLICT(device_id, project_path_hash) DO UPDATE SET
			privacy_mode = excluded.privacy_mode,
			updated_at = excluded.updated_at
	`, id, userID, deviceID, projectPathHash, privacyMode, now, now)
	if err != nil {
		return fmt.Errorf("upsert project privacy: %w", err)
	}
	return nil
}

func GetProjectPrivacy(db *sql.DB, deviceID, projectPathHash string) (string, error) {
	var mode string
	err := db.QueryRow(`
		SELECT privacy_mode FROM project_privacy WHERE device_id = $1 AND project_path_hash = $2
	`, deviceID, projectPathHash).Scan(&mode)
	if err == sql.ErrNoRows {
		return "telemetry_only", nil
	}
	if err != nil {
		return "", fmt.Errorf("get project privacy: %w", err)
	}
	return mode, nil
}
