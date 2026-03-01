package db

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/model"
)

// Users

func UpsertUser(db *sql.DB, appleUserID, email, displayName string) (*model.User, error) {
	now := time.Now()
	id := auth.GenerateID()

	_, err := db.Exec(`
		INSERT INTO users (id, apple_user_id, email, display_name, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(apple_user_id) DO UPDATE SET
			email = excluded.email,
			display_name = CASE WHEN excluded.display_name = '' THEN users.display_name ELSE excluded.display_name END,
			updated_at = excluded.updated_at
	`, id, appleUserID, email, displayName, now, now)
	if err != nil {
		return nil, fmt.Errorf("upsert user: %w", err)
	}

	return GetUserByAppleID(db, appleUserID)
}

func GetUserByAppleID(db *sql.DB, appleUserID string) (*model.User, error) {
	u := &model.User{}
	var appleID sql.NullString
	var subscriptionExpiresAt sql.NullTime
	err := db.QueryRow(`
		SELECT id, apple_user_id, email, display_name, subscription_tier, subscription_expires_at, created_at, updated_at
		FROM users WHERE apple_user_id = ?
	`, appleUserID).Scan(&u.ID, &appleID, &u.Email, &u.DisplayName, &u.SubscriptionTier, &subscriptionExpiresAt, &u.CreatedAt, &u.UpdatedAt)
	if err != nil {
		return nil, fmt.Errorf("get user by apple id: %w", err)
	}
	if appleID.Valid {
		u.AppleUserID = appleID.String
	}
	if subscriptionExpiresAt.Valid {
		u.SubscriptionExpiresAt = &subscriptionExpiresAt.Time
	}
	return u, nil
}

func GetUser(db *sql.DB, userID string) (*model.User, error) {
	u := &model.User{}
	var appleUserID sql.NullString
	var subscriptionExpiresAt sql.NullTime
	err := db.QueryRow(`
		SELECT id, apple_user_id, email, display_name, subscription_tier, subscription_expires_at, created_at, updated_at
		FROM users WHERE id = ?
	`, userID).Scan(&u.ID, &appleUserID, &u.Email, &u.DisplayName, &u.SubscriptionTier, &subscriptionExpiresAt, &u.CreatedAt, &u.UpdatedAt)
	if err != nil {
		return nil, fmt.Errorf("get user: %w", err)
	}
	if appleUserID.Valid {
		u.AppleUserID = appleUserID.String
	}
	if subscriptionExpiresAt.Valid {
		u.SubscriptionExpiresAt = &subscriptionExpiresAt.Time
	}
	return u, nil
}

// Email/password users

func CreateEmailUser(db *sql.DB, email, displayName, passwordHash string) (*model.User, error) {
	now := time.Now()
	id := auth.GenerateID()

	_, err := db.Exec(`
		INSERT INTO users (id, apple_user_id, email, display_name, password_hash, created_at, updated_at)
		VALUES (?, NULL, ?, ?, ?, ?, ?)
	`, id, email, displayName, passwordHash, now, now)
	if err != nil {
		return nil, fmt.Errorf("create email user: %w", err)
	}

	return &model.User{
		ID:               id,
		Email:            email,
		DisplayName:      displayName,
		SubscriptionTier: "free",
		CreatedAt:        now,
		UpdatedAt:        now,
	}, nil
}

func GetUserByEmail(db *sql.DB, email string) (*model.User, error) {
	u := &model.User{}
	var appleUserID sql.NullString
	var subscriptionExpiresAt sql.NullTime
	err := db.QueryRow(`
		SELECT id, apple_user_id, email, display_name, subscription_tier, subscription_expires_at, created_at, updated_at
		FROM users WHERE email = ? AND password_hash IS NOT NULL
	`, email).Scan(&u.ID, &appleUserID, &u.Email, &u.DisplayName, &u.SubscriptionTier, &subscriptionExpiresAt, &u.CreatedAt, &u.UpdatedAt)
	if err != nil {
		return nil, fmt.Errorf("get user by email: %w", err)
	}
	if appleUserID.Valid {
		u.AppleUserID = appleUserID.String
	}
	if subscriptionExpiresAt.Valid {
		u.SubscriptionExpiresAt = &subscriptionExpiresAt.Time
	}
	return u, nil
}

func GetPasswordHash(db *sql.DB, userID string) (string, error) {
	var hash sql.NullString
	err := db.QueryRow(`SELECT password_hash FROM users WHERE id = ?`, userID).Scan(&hash)
	if err != nil {
		return "", fmt.Errorf("get password hash: %w", err)
	}
	if !hash.Valid {
		return "", fmt.Errorf("no password set for user")
	}
	return hash.String, nil
}

func RecordLoginAttempt(db *sql.DB, email string, success bool, ip string) {
	s := 0
	if success {
		s = 1
	}
	db.Exec(`INSERT INTO login_attempts (email, success, ip_address) VALUES (?, ?, ?)`, email, s, ip)
}

func CountRecentFailedAttempts(db *sql.DB, email string, window time.Duration) (int, error) {
	cutoff := time.Now().Add(-window)
	var count int
	err := db.QueryRow(`
		SELECT COUNT(*) FROM login_attempts WHERE email = ? AND success = 0 AND attempted_at > ?
	`, email, cutoff).Scan(&count)
	if err != nil {
		return 0, fmt.Errorf("count failed attempts: %w", err)
	}
	return count, nil
}

func CleanupOldLoginAttempts(db *sql.DB, olderThan time.Duration) {
	cutoff := time.Now().Add(-olderThan)
	db.Exec(`DELETE FROM login_attempts WHERE attempted_at < ?`, cutoff)
}

// Devices

func CreateDevice(db *sql.DB, userID, name, publicKey, systemInfo, capabilities string) (*model.Device, error) {
	now := time.Now()
	id := auth.GenerateID()

	if capabilities == "" {
		capabilities = "[]"
	}

	_, err := db.Exec(`
		INSERT INTO devices (id, user_id, name, public_key, system_info, enrolled_at, last_seen_at, is_online, is_revoked, capabilities)
		VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?)
	`, id, userID, name, publicKey, systemInfo, now, now, capabilities)
	if err != nil {
		return nil, fmt.Errorf("create device: %w", err)
	}

	return &model.Device{
		ID:           id,
		UserID:       userID,
		Name:         name,
		PublicKey:    publicKey,
		SystemInfo:   systemInfo,
		EnrolledAt:   now,
		LastSeenAt:   now,
		IsOnline:     false,
		IsRevoked:    false,
		PrivacyMode:  "telemetry_only",
		Capabilities: json.RawMessage(capabilities),
	}, nil
}

func ListDevices(db *sql.DB, userID string) ([]*model.Device, error) {
	rows, err := db.Query(`
		SELECT id, user_id, name, public_key, system_info, enrolled_at, last_seen_at, is_online, is_revoked, privacy_mode,
			key_agreement_public_key, key_version, capabilities
		FROM devices WHERE user_id = ? AND is_revoked = 0
		ORDER BY enrolled_at DESC
	`, userID)
	if err != nil {
		return nil, fmt.Errorf("list devices: %w", err)
	}
	defer rows.Close()

	var devices []*model.Device
	for rows.Next() {
		d := &model.Device{}
		var isOnline, isRevoked int
		var kaPubKey sql.NullString
		var capStr string
		err := rows.Scan(&d.ID, &d.UserID, &d.Name, &d.PublicKey, &d.SystemInfo,
			&d.EnrolledAt, &d.LastSeenAt, &isOnline, &isRevoked, &d.PrivacyMode,
			&kaPubKey, &d.KeyVersion, &capStr)
		if err != nil {
			return nil, fmt.Errorf("scan device: %w", err)
		}
		d.IsOnline = isOnline != 0
		d.IsRevoked = isRevoked != 0
		if kaPubKey.Valid {
			d.KeyAgreementPublicKey = kaPubKey.String
		}
		d.Capabilities = json.RawMessage(capStr)
		devices = append(devices, d)
	}
	return devices, rows.Err()
}

// ReactivateDevice updates an existing device record, clears is_revoked, and refreshes metadata.
func ReactivateDevice(database *sql.DB, deviceID, name, publicKey, systemInfo, capabilities string) (*model.Device, error) {
	now := time.Now()
	if capabilities == "" {
		capabilities = "[]"
	}
	_, err := database.Exec(`
		UPDATE devices SET name = ?, public_key = ?, system_info = ?, is_revoked = 0, last_seen_at = ?, capabilities = ?
		WHERE id = ?
	`, name, publicKey, systemInfo, now, capabilities, deviceID)
	if err != nil {
		return nil, fmt.Errorf("reactivate device: %w", err)
	}
	return GetDevice(database, deviceID)
}

// FindDeviceByFingerprint finds an existing non-revoked device by user + name + system_info.
func FindDeviceByFingerprint(database *sql.DB, userID, name, systemInfo string) (*model.Device, error) {
	d := &model.Device{}
	var isOnline, isRevoked int
	var kaPubKey sql.NullString
	var capStr string
	err := database.QueryRow(`
		SELECT id, user_id, name, public_key, system_info, enrolled_at, last_seen_at, is_online, is_revoked, privacy_mode,
			key_agreement_public_key, key_version, capabilities
		FROM devices WHERE user_id = ? AND name = ? AND system_info = ? AND is_revoked = 0
		ORDER BY enrolled_at DESC LIMIT 1
	`, userID, name, systemInfo).Scan(&d.ID, &d.UserID, &d.Name, &d.PublicKey, &d.SystemInfo,
		&d.EnrolledAt, &d.LastSeenAt, &isOnline, &isRevoked, &d.PrivacyMode,
		&kaPubKey, &d.KeyVersion, &capStr)
	if err != nil {
		return nil, fmt.Errorf("find device by fingerprint: %w", err)
	}
	d.IsOnline = isOnline != 0
	d.IsRevoked = isRevoked != 0
	if kaPubKey.Valid {
		d.KeyAgreementPublicKey = kaPubKey.String
	}
	d.Capabilities = json.RawMessage(capStr)
	return d, nil
}

func DeleteDevice(db *sql.DB, deviceID, userID string) error {
	res, err := db.Exec(`UPDATE devices SET is_revoked = 1 WHERE id = ? AND user_id = ?`, deviceID, userID)
	if err != nil {
		return fmt.Errorf("delete device: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return fmt.Errorf("device not found")
	}
	return nil
}

func UpdateDeviceStatus(db *sql.DB, deviceID string, isOnline bool, lastSeenAt time.Time) error {
	online := 0
	if isOnline {
		online = 1
	}
	_, err := db.Exec(`UPDATE devices SET is_online = ?, last_seen_at = ? WHERE id = ?`,
		online, lastSeenAt, deviceID)
	if err != nil {
		return fmt.Errorf("update device status: %w", err)
	}
	return nil
}

func GetDevice(db *sql.DB, deviceID string) (*model.Device, error) {
	d := &model.Device{}
	var isOnline, isRevoked int
	var kaPubKey sql.NullString
	var capStr string
	err := db.QueryRow(`
		SELECT id, user_id, name, public_key, system_info, enrolled_at, last_seen_at, is_online, is_revoked, privacy_mode,
			key_agreement_public_key, key_version, capabilities
		FROM devices WHERE id = ?
	`, deviceID).Scan(&d.ID, &d.UserID, &d.Name, &d.PublicKey, &d.SystemInfo,
		&d.EnrolledAt, &d.LastSeenAt, &isOnline, &isRevoked, &d.PrivacyMode,
		&kaPubKey, &d.KeyVersion, &capStr)
	if err != nil {
		return nil, fmt.Errorf("get device: %w", err)
	}
	d.IsOnline = isOnline != 0
	d.IsRevoked = isRevoked != 0
	if kaPubKey.Valid {
		d.KeyAgreementPublicKey = kaPubKey.String
	}
	d.Capabilities = json.RawMessage(capStr)
	return d, nil
}

// Projects

func UpsertProject(db *sql.DB, p *model.Project) error {
	now := time.Now()
	if p.ID == "" {
		p.ID = auth.GenerateID()
	}
	_, err := db.Exec(`
		INSERT INTO projects (id, user_id, path, name, settings, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
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
		FROM projects WHERE id = ? AND user_id = ?
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
		FROM projects WHERE user_id = ? AND path = ?
	`, userID, path).Scan(&p.ID, &p.UserID, &p.Path, &p.Name, &p.Settings, &p.CreatedAt, &p.UpdatedAt)
	if err != nil {
		return nil, fmt.Errorf("get project by path: %w", err)
	}
	return p, nil
}

func ListProjects(db *sql.DB, userID string) ([]*model.Project, error) {
	rows, err := db.Query(`
		SELECT id, user_id, path, name, settings, created_at, updated_at
		FROM projects WHERE user_id = ?
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
// e.g. "/path/to/AFK/.claude/worktrees/xyz" → "/path/to/AFK"
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

func UpdateSessionProjectID(db *sql.DB, sessionID, projectID string) error {
	_, err := db.Exec(`UPDATE sessions SET project_id = ? WHERE id = ?`, projectID, sessionID)
	if err != nil {
		return fmt.Errorf("update session project_id: %w", err)
	}
	return nil
}

// Sessions

func UpsertSession(db *sql.DB, s *model.Session) error {
	_, err := db.Exec(`
		INSERT INTO sessions (id, device_id, user_id, project_path, git_branch, cwd, status, started_at, updated_at, tokens_in, tokens_out, turn_count, project_id, description, ephemeral_public_key)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			project_path = excluded.project_path,
			git_branch = excluded.git_branch,
			cwd = excluded.cwd,
			status = excluded.status,
			updated_at = excluded.updated_at,
			tokens_in = excluded.tokens_in,
			tokens_out = excluded.tokens_out,
			turn_count = excluded.turn_count,
			project_id = COALESCE(excluded.project_id, sessions.project_id),
			description = CASE WHEN excluded.description != '' THEN excluded.description ELSE sessions.description END,
			ephemeral_public_key = COALESCE(excluded.ephemeral_public_key, sessions.ephemeral_public_key)
	`, s.ID, s.DeviceID, s.UserID, s.ProjectPath, s.GitBranch, s.CWD,
		string(s.Status), s.StartedAt, s.UpdatedAt, s.TokensIn, s.TokensOut, s.TurnCount,
		nullableString(s.ProjectID), s.Description, nullableString(s.EphemeralPublicKey))
	if err != nil {
		return fmt.Errorf("upsert session: %w", err)
	}
	return nil
}

// EnsureSession creates a minimal session row if it doesn't exist.
// Unlike UpsertSession, it never overwrites existing metadata.
func EnsureSession(db *sql.DB, s *model.Session) error {
	_, err := db.Exec(`
		INSERT OR IGNORE INTO sessions (id, device_id, user_id, project_path, git_branch, cwd, status, started_at, updated_at, tokens_in, tokens_out, turn_count, project_id, description, ephemeral_public_key)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, s.ID, s.DeviceID, s.UserID, s.ProjectPath, s.GitBranch, s.CWD,
		string(s.Status), s.StartedAt, s.UpdatedAt, s.TokensIn, s.TokensOut, s.TurnCount,
		nullableString(s.ProjectID), s.Description, nullableString(s.EphemeralPublicKey))
	if err != nil {
		return fmt.Errorf("ensure session: %w", err)
	}
	return nil
}

func nullableString(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func UpdateSessionStatus(db *sql.DB, sessionID string, status model.SessionStatus) error {
	now := time.Now()
	result, err := db.Exec(`UPDATE sessions SET status = ?, updated_at = ? WHERE id = ?`,
		string(status), now, sessionID)
	if err != nil {
		return fmt.Errorf("update session status: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("session not found: %s", sessionID)
	}
	return nil
}

func ListSessions(db *sql.DB, userID, deviceID, status string) ([]*model.Session, error) {
	query := `SELECT id, device_id, user_id, project_path, git_branch, cwd, status,
		started_at, updated_at, tokens_in, tokens_out, turn_count, project_id, description, ephemeral_public_key
		FROM sessions WHERE user_id = ?`
	args := []interface{}{userID}

	if deviceID != "" {
		query += " AND device_id = ?"
		args = append(args, deviceID)
	}
	if status != "" {
		query += " AND status = ?"
		args = append(args, status)
	}
	query += " ORDER BY updated_at DESC"

	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("list sessions: %w", err)
	}
	defer rows.Close()

	var sessions []*model.Session
	for rows.Next() {
		s := &model.Session{}
		var projectID sql.NullString
		var ephPubKey sql.NullString
		err := rows.Scan(&s.ID, &s.DeviceID, &s.UserID, &s.ProjectPath, &s.GitBranch,
			&s.CWD, &s.Status, &s.StartedAt, &s.UpdatedAt, &s.TokensIn, &s.TokensOut, &s.TurnCount,
			&projectID, &s.Description, &ephPubKey)
		if err != nil {
			return nil, fmt.Errorf("scan session: %w", err)
		}
		if projectID.Valid {
			s.ProjectID = projectID.String
		}
		if ephPubKey.Valid {
			s.EphemeralPublicKey = ephPubKey.String
		}
		sessions = append(sessions, s)
	}
	return sessions, rows.Err()
}

func ListSessionsByProject(db *sql.DB, userID, projectID string) ([]*model.Session, error) {
	rows, err := db.Query(`
		SELECT id, device_id, user_id, project_path, git_branch, cwd, status,
			started_at, updated_at, tokens_in, tokens_out, turn_count, project_id, description, ephemeral_public_key
		FROM sessions WHERE user_id = ? AND project_id = ?
		ORDER BY updated_at DESC
	`, userID, projectID)
	if err != nil {
		return nil, fmt.Errorf("list sessions by project: %w", err)
	}
	defer rows.Close()

	var sessions []*model.Session
	for rows.Next() {
		s := &model.Session{}
		var pid sql.NullString
		var ephPubKey sql.NullString
		err := rows.Scan(&s.ID, &s.DeviceID, &s.UserID, &s.ProjectPath, &s.GitBranch,
			&s.CWD, &s.Status, &s.StartedAt, &s.UpdatedAt, &s.TokensIn, &s.TokensOut, &s.TurnCount,
			&pid, &s.Description, &ephPubKey)
		if err != nil {
			return nil, fmt.Errorf("scan session: %w", err)
		}
		if pid.Valid {
			s.ProjectID = pid.String
		}
		if ephPubKey.Valid {
			s.EphemeralPublicKey = ephPubKey.String
		}
		sessions = append(sessions, s)
	}
	return sessions, rows.Err()
}

func GetSession(db *sql.DB, sessionID string) (*model.Session, error) {
	s := &model.Session{}
	var projectID sql.NullString
	var ephPubKey sql.NullString
	err := db.QueryRow(`
		SELECT id, device_id, user_id, project_path, git_branch, cwd, status,
			started_at, updated_at, tokens_in, tokens_out, turn_count, project_id, description, ephemeral_public_key
		FROM sessions WHERE id = ?
	`, sessionID).Scan(&s.ID, &s.DeviceID, &s.UserID, &s.ProjectPath, &s.GitBranch,
		&s.CWD, &s.Status, &s.StartedAt, &s.UpdatedAt, &s.TokensIn, &s.TokensOut, &s.TurnCount,
		&projectID, &s.Description, &ephPubKey)
	if err != nil {
		return nil, fmt.Errorf("get session: %w", err)
	}
	if projectID.Valid {
		s.ProjectID = projectID.String
	}
	if ephPubKey.Valid {
		s.EphemeralPublicKey = ephPubKey.String
	}
	return s, nil
}

// ListRunningSessionsByDevice returns all sessions with status "running" for a given device.
func ListRunningSessionsByDevice(db *sql.DB, deviceID string) ([]string, error) {
	rows, err := db.Query(`SELECT id FROM sessions WHERE device_id = ? AND status = 'running'`, deviceID)
	if err != nil {
		return nil, fmt.Errorf("list running sessions by device: %w", err)
	}
	defer rows.Close()

	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scan session id: %w", err)
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// ListStuckSessions returns sessions that have been "running" for longer than the given duration.
func ListStuckSessions(db *sql.DB, stuckThreshold time.Duration) ([]*model.Session, error) {
	cutoff := time.Now().Add(-stuckThreshold)
	rows, err := db.Query(`
		SELECT id, device_id, user_id, project_path, git_branch, cwd, status,
			started_at, updated_at, tokens_in, tokens_out, turn_count, project_id, description, ephemeral_public_key
		FROM sessions WHERE status = 'running' AND updated_at < ?
		ORDER BY updated_at ASC
	`, cutoff)
	if err != nil {
		return nil, fmt.Errorf("list stuck sessions: %w", err)
	}
	defer rows.Close()

	var sessions []*model.Session
	for rows.Next() {
		s := &model.Session{}
		var projectID sql.NullString
		var ephPubKey sql.NullString
		err := rows.Scan(&s.ID, &s.DeviceID, &s.UserID, &s.ProjectPath, &s.GitBranch,
			&s.CWD, &s.Status, &s.StartedAt, &s.UpdatedAt, &s.TokensIn, &s.TokensOut, &s.TurnCount,
			&projectID, &s.Description, &ephPubKey)
		if err != nil {
			return nil, fmt.Errorf("scan stuck session: %w", err)
		}
		if projectID.Valid {
			s.ProjectID = projectID.String
		}
		if ephPubKey.Valid {
			s.EphemeralPublicKey = ephPubKey.String
		}
		sessions = append(sessions, s)
	}
	return sessions, rows.Err()
}

// Session Events

func InsertEvent(db *sql.DB, event *model.SessionEvent) error {
	// Use agent-assigned seq if provided (> 0), otherwise auto-assign
	if event.Seq <= 0 {
		var maxSeq int
		_ = db.QueryRow(`SELECT COALESCE(MAX(seq), 0) FROM session_events WHERE session_id = ?`, event.SessionID).Scan(&maxSeq)
		event.Seq = maxSeq + 1
	}

	var contentStr *string
	if len(event.Content) > 0 {
		s := string(event.Content)
		contentStr = &s
	}

	// ON CONFLICT DO NOTHING deduplicates re-sent events after Agent restart.
	// The unique partial index idx_session_events_dedup covers (session_id, seq) WHERE seq > 0.
	result, err := db.Exec(`
		INSERT INTO session_events (id, session_id, device_id, event_type, timestamp, payload, content, seq, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (session_id, seq) WHERE seq > 0 DO NOTHING
	`, event.ID, event.SessionID, event.DeviceID, event.EventType,
		event.Timestamp, string(event.Payload), contentStr, event.Seq, event.CreatedAt)
	if err != nil {
		return fmt.Errorf("insert event: %w", err)
	}
	// Check if the row was actually inserted (not a duplicate)
	rows, _ := result.RowsAffected()
	if rows == 0 {
		// Seq collision: an event at this (session_id, seq) already exists.
		// This happens when a Claude session is resumed (--resume) and the
		// agent restarts seq numbering from 1, colliding with events from
		// the original run. Auto-assign next available seq and re-insert.
		var maxSeq int
		_ = db.QueryRow(`SELECT COALESCE(MAX(seq), 0) FROM session_events WHERE session_id = ?`,
			event.SessionID).Scan(&maxSeq)
		event.Seq = maxSeq + 1
		_, err = db.Exec(`
			INSERT INTO session_events (id, session_id, device_id, event_type, timestamp, payload, content, seq, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		`, event.ID, event.SessionID, event.DeviceID, event.EventType,
			event.Timestamp, string(event.Payload), contentStr, event.Seq, event.CreatedAt)
		if err != nil {
			return fmt.Errorf("re-insert event after seq collision: %w", err)
		}
		slog.Debug("seq collision resolved", "session_id", event.SessionID, "new_seq", event.Seq)
	}
	return nil
}

// ListEvents loads events for a session with forward pagination (afterSeq > 0).
func ListEvents(db *sql.DB, sessionID string, limit int, afterSeq int) ([]*model.SessionEvent, bool, error) {
	rows, err := db.Query(`
		SELECT id, session_id, device_id, event_type, timestamp, payload, content, seq, created_at
		FROM session_events WHERE session_id = ? AND seq > ?
		ORDER BY seq ASC LIMIT ?
	`, sessionID, afterSeq, limit+1)
	if err != nil {
		return nil, false, fmt.Errorf("list events: %w", err)
	}
	defer rows.Close()

	events, err := scanEvents(rows)
	if err != nil {
		return nil, false, err
	}

	hasMore := len(events) > limit
	if hasMore {
		events = events[:limit]
	}
	return events, hasMore, nil
}

// ListEventsLatest loads the most recent events for a session (initial load).
// Returns events in ascending seq order, with hasMore=true if older events exist.
func ListEventsLatest(db *sql.DB, sessionID string, limit int) ([]*model.SessionEvent, bool, error) {
	rows, err := db.Query(`
		SELECT id, session_id, device_id, event_type, timestamp, payload, content, seq, created_at
		FROM (
			SELECT id, session_id, device_id, event_type, timestamp, payload, content, seq, created_at
			FROM session_events WHERE session_id = ?
			ORDER BY seq DESC LIMIT ?
		) sub ORDER BY seq ASC
	`, sessionID, limit+1)
	if err != nil {
		return nil, false, fmt.Errorf("list latest events: %w", err)
	}
	defer rows.Close()

	events, err := scanEvents(rows)
	if err != nil {
		return nil, false, err
	}

	// If we got limit+1 rows, there are older events.
	// Drop the FIRST element (oldest) since we want the latest `limit`.
	hasMore := len(events) > limit
	if hasMore {
		events = events[1:]
	}
	return events, hasMore, nil
}

// ListEventsBefore loads events older than beforeSeq (reverse pagination for "Load More").
// Returns events in ascending seq order, with hasMore=true if even older events exist.
func ListEventsBefore(db *sql.DB, sessionID string, limit int, beforeSeq int) ([]*model.SessionEvent, bool, error) {
	rows, err := db.Query(`
		SELECT id, session_id, device_id, event_type, timestamp, payload, content, seq, created_at
		FROM (
			SELECT id, session_id, device_id, event_type, timestamp, payload, content, seq, created_at
			FROM session_events WHERE session_id = ? AND seq < ?
			ORDER BY seq DESC LIMIT ?
		) sub ORDER BY seq ASC
	`, sessionID, beforeSeq, limit+1)
	if err != nil {
		return nil, false, fmt.Errorf("list events before: %w", err)
	}
	defer rows.Close()

	events, err := scanEvents(rows)
	if err != nil {
		return nil, false, err
	}

	hasMore := len(events) > limit
	if hasMore {
		events = events[1:]
	}
	return events, hasMore, nil
}

func scanEvents(rows *sql.Rows) ([]*model.SessionEvent, error) {
	var events []*model.SessionEvent
	for rows.Next() {
		e := &model.SessionEvent{}
		var payload string
		var content sql.NullString
		err := rows.Scan(&e.ID, &e.SessionID, &e.DeviceID, &e.EventType,
			&e.Timestamp, &payload, &content, &e.Seq, &e.CreatedAt)
		if err != nil {
			return nil, fmt.Errorf("scan event: %w", err)
		}
		e.Payload = json.RawMessage(payload)
		if content.Valid && content.String != "" {
			e.Content = json.RawMessage(content.String)
		}
		events = append(events, e)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return events, nil
}

// Refresh Tokens

func StoreRefreshToken(db *sql.DB, userID, tokenHash string, expiresAt time.Time) error {
	id := auth.GenerateID()
	_, err := db.Exec(`
		INSERT INTO refresh_tokens (id, user_id, token_hash, expires_at, revoked)
		VALUES (?, ?, ?, ?, 0)
	`, id, userID, tokenHash, expiresAt)
	if err != nil {
		return fmt.Errorf("store refresh token: %w", err)
	}
	return nil
}

func ValidateRefreshToken(db *sql.DB, tokenHash string) (string, error) {
	var userID string
	var expiresAt time.Time
	var revoked int
	err := db.QueryRow(`
		SELECT user_id, expires_at, revoked FROM refresh_tokens WHERE token_hash = ?
	`, tokenHash).Scan(&userID, &expiresAt, &revoked)
	if err != nil {
		return "", fmt.Errorf("validate refresh token: %w", err)
	}
	if revoked != 0 {
		return "", fmt.Errorf("refresh token revoked")
	}
	if time.Now().After(expiresAt) {
		return "", fmt.Errorf("refresh token expired")
	}
	return userID, nil
}

func RevokeRefreshToken(db *sql.DB, tokenHash string) error {
	_, err := db.Exec(`UPDATE refresh_tokens SET revoked = 1 WHERE token_hash = ?`, tokenHash)
	if err != nil {
		return fmt.Errorf("revoke refresh token: %w", err)
	}
	return nil
}

// Device Key Agreement

func UpdateDeviceKeyAgreement(db *sql.DB, deviceID, publicKey string, version int) error {
	_, err := db.Exec(`UPDATE devices SET key_agreement_public_key = ?, key_version = ? WHERE id = ?`,
		publicKey, version, deviceID)
	if err != nil {
		return fmt.Errorf("update device key agreement: %w", err)
	}
	return nil
}

func InsertDeviceKey(db *sql.DB, key *model.DeviceKey) error {
	if key.ID == "" {
		key.ID = auth.GenerateID()
	}
	now := time.Now().UTC().Format(time.RFC3339)
	active := 0
	if key.Active {
		active = 1
	}
	_, err := db.Exec(`
		INSERT INTO device_keys (id, device_id, key_type, public_key, version, active, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
	`, key.ID, key.DeviceID, key.KeyType, key.PublicKey, key.Version, active, now)
	if err != nil {
		return fmt.Errorf("insert device key: %w", err)
	}
	return nil
}

func RevokeDeviceKeys(db *sql.DB, deviceID string) error {
	now := time.Now().UTC().Format(time.RFC3339)
	_, err := db.Exec(`UPDATE device_keys SET active = 0, revoked_at = ? WHERE device_id = ? AND active = 1`,
		now, deviceID)
	if err != nil {
		return fmt.Errorf("revoke device keys: %w", err)
	}
	return nil
}

func GetActiveDeviceKey(db *sql.DB, deviceID, keyType string) (*model.DeviceKey, error) {
	k := &model.DeviceKey{}
	var active int
	var revokedAt sql.NullString
	err := db.QueryRow(`
		SELECT id, device_id, key_type, public_key, version, active, created_at, revoked_at
		FROM device_keys WHERE device_id = ? AND key_type = ? AND active = 1
		ORDER BY version DESC LIMIT 1
	`, deviceID, keyType).Scan(&k.ID, &k.DeviceID, &k.KeyType, &k.PublicKey, &k.Version, &active, &k.CreatedAt, &revokedAt)
	if err != nil {
		return nil, fmt.Errorf("get active device key: %w", err)
	}
	k.Active = active != 0
	if revokedAt.Valid {
		k.RevokedAt = &revokedAt.String
	}
	return k, nil
}

// GetDeviceKeyByVersion returns a historical device key by version.
func GetDeviceKeyByVersion(db *sql.DB, deviceID string, version int) (*model.DeviceKey, error) {
	k := &model.DeviceKey{}
	var active int
	var revokedAt sql.NullString
	err := db.QueryRow(`
		SELECT id, device_id, key_type, public_key, version, active, created_at, revoked_at
		FROM device_keys WHERE device_id = ? AND version = ?
		ORDER BY created_at DESC LIMIT 1
	`, deviceID, version).Scan(&k.ID, &k.DeviceID, &k.KeyType, &k.PublicKey, &k.Version, &active, &k.CreatedAt, &revokedAt)
	if err != nil {
		return nil, fmt.Errorf("get device key by version: %w", err)
	}
	k.Active = active != 0
	if revokedAt.Valid {
		k.RevokedAt = &revokedAt.String
	}
	return k, nil
}

// GetPeerKeyAgreementKey returns the key_agreement public key for a peer device belonging to the same user.
// Used by one device to get another device's public key for ECDH.
func GetPeerKeyAgreementKey(db *sql.DB, userID, peerDeviceID string) (string, error) {
	var pubKey sql.NullString
	err := db.QueryRow(`
		SELECT key_agreement_public_key FROM devices
		WHERE id = ? AND user_id = ? AND is_revoked = 0 AND key_agreement_public_key IS NOT NULL
	`, peerDeviceID, userID).Scan(&pubKey)
	if err != nil {
		return "", fmt.Errorf("get peer key agreement key: %w", err)
	}
	if !pubKey.Valid || pubKey.String == "" {
		return "", fmt.Errorf("peer device has no key agreement key")
	}
	return pubKey.String, nil
}

// Privacy Mode

func UpdateDevicePrivacyMode(db *sql.DB, deviceID, privacyMode string) error {
	_, err := db.Exec(`UPDATE devices SET privacy_mode = ? WHERE id = ?`, privacyMode, deviceID)
	if err != nil {
		return fmt.Errorf("update device privacy mode: %w", err)
	}
	return nil
}

func GetDevicePrivacyMode(db *sql.DB, deviceID string) (string, error) {
	var mode string
	err := db.QueryRow(`SELECT privacy_mode FROM devices WHERE id = ?`, deviceID).Scan(&mode)
	if err != nil {
		return "", fmt.Errorf("get device privacy mode: %w", err)
	}
	return mode, nil
}

func UpsertProjectPrivacy(db *sql.DB, id, userID, deviceID, projectPathHash, privacyMode string) error {
	now := time.Now()
	_, err := db.Exec(`
		INSERT OR REPLACE INTO project_privacy (id, user_id, device_id, project_path_hash, privacy_mode, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
	`, id, userID, deviceID, projectPathHash, privacyMode, now, now)
	if err != nil {
		return fmt.Errorf("upsert project privacy: %w", err)
	}
	return nil
}

func GetProjectPrivacy(db *sql.DB, deviceID, projectPathHash string) (string, error) {
	var mode string
	err := db.QueryRow(`
		SELECT privacy_mode FROM project_privacy WHERE device_id = ? AND project_path_hash = ?
	`, deviceID, projectPathHash).Scan(&mode)
	if err == sql.ErrNoRows {
		return "telemetry_only", nil
	}
	if err != nil {
		return "", fmt.Errorf("get project privacy: %w", err)
	}
	return mode, nil
}

// Audit Log

func InsertAuditLog(db *sql.DB, entry *model.AuditLogEntry) error {
	if entry.ID == "" {
		entry.ID = auth.GenerateID()
	}
	if entry.CreatedAt == "" {
		entry.CreatedAt = time.Now().UTC().Format(time.RFC3339)
	}
	_, err := db.Exec(`
		INSERT INTO audit_log (id, user_id, device_id, action, details, content_hash, ip_address, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
	`, entry.ID, entry.UserID, entry.DeviceID, entry.Action, entry.Details,
		entry.ContentHash, entry.IPAddress, entry.CreatedAt)
	if err != nil {
		return fmt.Errorf("insert audit log: %w", err)
	}
	return nil
}

// Commands

func CreateCommand(database *sql.DB, cmd *model.Command) error {
	_, err := database.Exec(`
		INSERT INTO commands (id, session_id, user_id, device_id, prompt_hash, prompt_encrypted, nonce, status, created_at, updated_at, expires_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, cmd.ID, cmd.SessionID, cmd.UserID, cmd.DeviceID, cmd.PromptHash,
		cmd.PromptEncrypted, cmd.Nonce, cmd.Status, cmd.CreatedAt, cmd.UpdatedAt, cmd.ExpiresAt)
	if err != nil {
		return fmt.Errorf("create command: %w", err)
	}
	return nil
}

func UpdateCommandStatus(database *sql.DB, commandID, status string) error {
	now := time.Now().UTC().Format(time.RFC3339)
	_, err := database.Exec(`UPDATE commands SET status = ?, updated_at = ? WHERE id = ?`,
		status, now, commandID)
	if err != nil {
		return fmt.Errorf("update command status: %w", err)
	}
	return nil
}

func GetCommand(database *sql.DB, commandID string) (*model.Command, error) {
	cmd := &model.Command{}
	var promptEncrypted sql.NullString
	err := database.QueryRow(`
		SELECT id, session_id, user_id, device_id, prompt_hash, prompt_encrypted, nonce, status, created_at, updated_at, expires_at
		FROM commands WHERE id = ?
	`, commandID).Scan(&cmd.ID, &cmd.SessionID, &cmd.UserID, &cmd.DeviceID,
		&cmd.PromptHash, &promptEncrypted, &cmd.Nonce, &cmd.Status,
		&cmd.CreatedAt, &cmd.UpdatedAt, &cmd.ExpiresAt)
	if err != nil {
		return nil, fmt.Errorf("get command: %w", err)
	}
	if promptEncrypted.Valid {
		cmd.PromptEncrypted = promptEncrypted.String
	}
	return cmd, nil
}

// Push Tokens

func UpsertPushToken(database *sql.DB, userID, deviceToken, platform, bundleID string) error {
	now := time.Now().UTC().Format(time.RFC3339)
	id := auth.GenerateID()
	_, err := database.Exec(`
		INSERT INTO push_tokens (id, user_id, device_token, platform, bundle_id, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(device_token) DO UPDATE SET
			user_id = excluded.user_id,
			platform = excluded.platform,
			bundle_id = excluded.bundle_id,
			updated_at = excluded.updated_at
	`, id, userID, deviceToken, platform, bundleID, now, now)
	if err != nil {
		return fmt.Errorf("upsert push token: %w", err)
	}
	return nil
}

func DeletePushToken(database *sql.DB, deviceToken string) error {
	_, err := database.Exec(`DELETE FROM push_tokens WHERE device_token = ?`, deviceToken)
	if err != nil {
		return fmt.Errorf("delete push token: %w", err)
	}
	return nil
}

func DeletePushTokenForUser(database *sql.DB, deviceToken, userID string) error {
	_, err := database.Exec(`DELETE FROM push_tokens WHERE device_token = ? AND user_id = ?`, deviceToken, userID)
	if err != nil {
		return fmt.Errorf("delete push token for user: %w", err)
	}
	return nil
}

func DeletePushTokenByToken(database *sql.DB, deviceToken string) error {
	return DeletePushToken(database, deviceToken)
}

func ListPushTokensByUser(database *sql.DB, userID string) ([]model.PushToken, error) {
	rows, err := database.Query(`
		SELECT id, user_id, device_token, platform, bundle_id, created_at, updated_at
		FROM push_tokens WHERE user_id = ?
		ORDER BY created_at DESC
	`, userID)
	if err != nil {
		return nil, fmt.Errorf("list push tokens: %w", err)
	}
	defer rows.Close()

	var tokens []model.PushToken
	for rows.Next() {
		var t model.PushToken
		if err := rows.Scan(&t.ID, &t.UserID, &t.DeviceToken, &t.Platform, &t.BundleID, &t.CreatedAt, &t.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scan push token: %w", err)
		}
		tokens = append(tokens, t)
	}
	return tokens, rows.Err()
}

// Notification Preferences

func GetNotificationPrefs(database *sql.DB, userID string) (*model.NotificationPrefs, error) {
	var prefs model.NotificationPrefs
	var permReq, sessErr, sessComp, askUser, sessActivity int
	var quietStart, quietEnd sql.NullString
	err := database.QueryRow(`
		SELECT user_id, permission_requests, session_errors, session_completions, ask_user, session_activity, quiet_hours_start, quiet_hours_end
		FROM notification_preferences WHERE user_id = ?
	`, userID).Scan(&prefs.UserID, &permReq, &sessErr, &sessComp, &askUser, &sessActivity, &quietStart, &quietEnd)
	if err == sql.ErrNoRows {
		// Return defaults: all enabled except session activity (off by default).
		return &model.NotificationPrefs{
			UserID:             userID,
			PermissionRequests: true,
			SessionErrors:      true,
			SessionCompletions: true,
			AskUser:            true,
			SessionActivity:    false,
		}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("get notification prefs: %w", err)
	}
	prefs.PermissionRequests = permReq != 0
	prefs.SessionErrors = sessErr != 0
	prefs.SessionCompletions = sessComp != 0
	prefs.AskUser = askUser != 0
	prefs.SessionActivity = sessActivity != 0
	if quietStart.Valid {
		prefs.QuietHoursStart = quietStart.String
	}
	if quietEnd.Valid {
		prefs.QuietHoursEnd = quietEnd.String
	}
	return &prefs, nil
}

func UpsertNotificationPrefs(database *sql.DB, userID string, prefs *model.NotificationPrefs) error {
	now := time.Now().UTC().Format(time.RFC3339)
	boolToInt := func(b bool) int {
		if b {
			return 1
		}
		return 0
	}
	var quietStart, quietEnd *string
	if prefs.QuietHoursStart != "" {
		quietStart = &prefs.QuietHoursStart
	}
	if prefs.QuietHoursEnd != "" {
		quietEnd = &prefs.QuietHoursEnd
	}
	_, err := database.Exec(`
		INSERT INTO notification_preferences (user_id, permission_requests, session_errors, session_completions, ask_user, session_activity, quiet_hours_start, quiet_hours_end, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(user_id) DO UPDATE SET
			permission_requests = excluded.permission_requests,
			session_errors = excluded.session_errors,
			session_completions = excluded.session_completions,
			ask_user = excluded.ask_user,
			session_activity = excluded.session_activity,
			quiet_hours_start = excluded.quiet_hours_start,
			quiet_hours_end = excluded.quiet_hours_end,
			updated_at = excluded.updated_at
	`, userID,
		boolToInt(prefs.PermissionRequests),
		boolToInt(prefs.SessionErrors),
		boolToInt(prefs.SessionCompletions),
		boolToInt(prefs.AskUser),
		boolToInt(prefs.SessionActivity),
		quietStart, quietEnd, now, now)
	if err != nil {
		return fmt.Errorf("upsert notification prefs: %w", err)
	}
	return nil
}

// Push-to-Start Tokens

func UpsertPushToStartToken(db *sql.DB, userID, token string) error {
	now := time.Now().UTC().Format(time.RFC3339)
	_, err := db.Exec(`
		INSERT INTO push_to_start_tokens (user_id, token, created_at, updated_at)
		VALUES (?, ?, ?, ?)
		ON CONFLICT(user_id) DO UPDATE SET
			token = excluded.token,
			updated_at = excluded.updated_at
	`, userID, token, now, now)
	if err != nil {
		return fmt.Errorf("upsert push-to-start token: %w", err)
	}
	return nil
}

func GetPushToStartToken(db *sql.DB, userID string) (string, error) {
	var token string
	err := db.QueryRow(`SELECT token FROM push_to_start_tokens WHERE user_id = ?`, userID).Scan(&token)
	if err != nil {
		return "", fmt.Errorf("get push-to-start token: %w", err)
	}
	return token, nil
}

func DeletePushToStartToken(db *sql.DB, userID string) error {
	_, err := db.Exec(`DELETE FROM push_to_start_tokens WHERE user_id = ?`, userID)
	if err != nil {
		return fmt.Errorf("delete push-to-start token: %w", err)
	}
	return nil
}

func ListAuditLog(db *sql.DB, userID string, limit, offset int) ([]*model.AuditLogEntry, error) {
	rows, err := db.Query(`
		SELECT id, user_id, device_id, action, details, content_hash, ip_address, created_at
		FROM audit_log WHERE user_id = ?
		ORDER BY created_at DESC LIMIT ? OFFSET ?
	`, userID, limit, offset)
	if err != nil {
		return nil, fmt.Errorf("list audit log: %w", err)
	}
	defer rows.Close()

	var entries []*model.AuditLogEntry
	for rows.Next() {
		e := &model.AuditLogEntry{}
		var deviceID, contentHash, ipAddress sql.NullString
		err := rows.Scan(&e.ID, &e.UserID, &deviceID, &e.Action, &e.Details,
			&contentHash, &ipAddress, &e.CreatedAt)
		if err != nil {
			return nil, fmt.Errorf("scan audit log: %w", err)
		}
		if deviceID.Valid {
			e.DeviceID = deviceID.String
		}
		if contentHash.Valid {
			e.ContentHash = contentHash.String
		}
		if ipAddress.Valid {
			e.IPAddress = ipAddress.String
		}
		entries = append(entries, e)
	}
	return entries, rows.Err()
}

// Subscriptions

func UpdateUserSubscription(db *sql.DB, userID, tier, productID, originalTxID string, expiresAt *time.Time) error {
	_, err := db.Exec(`
		UPDATE users SET subscription_tier = ?, subscription_product_id = ?,
			subscription_original_transaction_id = ?, subscription_expires_at = ?,
			updated_at = CURRENT_TIMESTAMP
		WHERE id = ?
	`, tier, productID, originalTxID, expiresAt, userID)
	if err != nil {
		return fmt.Errorf("update user subscription: %w", err)
	}
	return nil
}

func GetUserByOriginalTransactionID(db *sql.DB, originalTxID string) (*model.User, error) {
	u := &model.User{}
	var appleUserID sql.NullString
	var subscriptionExpiresAt sql.NullTime
	err := db.QueryRow(`
		SELECT id, apple_user_id, email, display_name, subscription_tier, subscription_expires_at, created_at, updated_at
		FROM users WHERE subscription_original_transaction_id = ?
	`, originalTxID).Scan(&u.ID, &appleUserID, &u.Email, &u.DisplayName, &u.SubscriptionTier, &subscriptionExpiresAt, &u.CreatedAt, &u.UpdatedAt)
	if err != nil {
		return nil, fmt.Errorf("get user by original transaction id: %w", err)
	}
	if appleUserID.Valid {
		u.AppleUserID = appleUserID.String
	}
	if subscriptionExpiresAt.Valid {
		u.SubscriptionExpiresAt = &subscriptionExpiresAt.Time
	}
	return u, nil
}

func GetUserTier(db *sql.DB, userID string) (string, error) {
	var tier string
	err := db.QueryRow(`SELECT subscription_tier FROM users WHERE id = ?`, userID).Scan(&tier)
	if err != nil {
		return "", fmt.Errorf("get user tier: %w", err)
	}
	return tier, nil
}

func CountActiveDevicesByType(db *sql.DB, userID string) (agentCount, iosCount int, err error) {
	err = db.QueryRow(`
		SELECT
			COUNT(CASE WHEN system_info NOT LIKE 'iOS%' THEN 1 END),
			COUNT(CASE WHEN system_info LIKE 'iOS%' THEN 1 END)
		FROM devices WHERE user_id = ? AND is_revoked = 0
	`, userID).Scan(&agentCount, &iosCount)
	if err != nil {
		return 0, 0, fmt.Errorf("count active devices by type: %w", err)
	}
	return agentCount, iosCount, nil
}

func PurgeExpiredEvents(db *sql.DB, freeCutoff, proCutoff time.Time) (int64, error) {
	result, err := db.Exec(`
		DELETE FROM session_events WHERE id IN (
			SELECT se.id FROM session_events se
			JOIN sessions s ON se.session_id = s.id
			JOIN users u ON s.user_id = u.id
			WHERE (u.subscription_tier = 'free' AND se.created_at < ?)
			   OR (u.subscription_tier != 'free' AND se.created_at < ?)
		)
	`, freeCutoff, proCutoff)
	if err != nil {
		return 0, fmt.Errorf("purge expired events: %w", err)
	}
	return result.RowsAffected()
}

// PurgeExpiredCommands deletes commands that have expired and are in a terminal
// or pending state. This prevents unbounded growth of the commands table.
func PurgeExpiredCommands(db *sql.DB, cutoff time.Time) (int64, error) {
	result, err := db.Exec(`
		DELETE FROM commands
		WHERE expires_at < ?
		  AND status IN ('pending', 'completed', 'failed', 'cancelled')
	`, cutoff)
	if err != nil {
		return 0, fmt.Errorf("purge expired commands: %w", err)
	}
	return result.RowsAffected()
}

// Tasks

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
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
		WHERE t.id = ?
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
		WHERE t.session_id = ? AND t.session_local_id = ? AND t.source = 'claude_code'
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
		WHERE t.user_id = ?`
	args := []any{userID}

	if source != "" {
		query += " AND t.source = ?"
		args = append(args, source)
	}
	if projectID != "" {
		query += " AND t.project_id = ?"
		args = append(args, projectID)
	}
	if status != "" {
		query += " AND t.status = ?"
		args = append(args, status)
	}

	query += " ORDER BY t.updated_at DESC LIMIT ? OFFSET ?"
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
	sets := []string{"updated_at = ?"}
	args := []any{now}

	if subject != nil {
		sets = append(sets, "subject = ?")
		args = append(args, *subject)
	}
	if description != nil {
		sets = append(sets, "description = ?")
		args = append(args, *description)
	}
	if status != nil {
		sets = append(sets, "status = ?")
		args = append(args, *status)
	}

	args = append(args, taskID)
	_, err := database.Exec(
		fmt.Sprintf("UPDATE tasks SET %s WHERE id = ?", strings.Join(sets, ", ")),
		args...,
	)
	if err != nil {
		return fmt.Errorf("update task: %w", err)
	}
	return nil
}

func DeleteTask(database *sql.DB, taskID string) error {
	_, err := database.Exec("DELETE FROM tasks WHERE id = ?", taskID)
	if err != nil {
		return fmt.Errorf("delete task: %w", err)
	}
	return nil
}

func CountClaudeTasksBySession(database *sql.DB, sessionID string) (int, error) {
	var count int
	err := database.QueryRow(
		"SELECT COUNT(*) FROM tasks WHERE session_id = ? AND source = 'claude_code'",
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
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
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
		WHERE t.user_id = ?
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
		WHERE t.user_id = ? AND t.project_id = ?
	`, userID, projectID).Scan(&td.ProjectID, &td.ProjectPath, &td.ProjectName, &td.RawContent, &itemsJSON, &td.UpdatedAt)
	if err != nil {
		return nil, fmt.Errorf("get todo by project: %w", err)
	}
	if err := json.Unmarshal([]byte(itemsJSON), &td.Items); err != nil {
		td.Items = []model.TodoItem{}
	}
	return td, nil
}
