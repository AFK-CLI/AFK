package db

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/AFK/afk-cloud/internal/model"
)

// Sessions

func UpsertSession(db *sql.DB, s *model.Session) error {
	_, err := db.Exec(`
		INSERT INTO sessions (id, device_id, user_id, project_path, git_branch, cwd, status, started_at, updated_at, tokens_in, tokens_out, turn_count, project_id, description, ephemeral_public_key, cost_usd)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
			ephemeral_public_key = COALESCE(excluded.ephemeral_public_key, sessions.ephemeral_public_key),
			cost_usd = sessions.cost_usd  -- preserve: accumulated via AccumulateSessionCost, not upsert
	`, s.ID, s.DeviceID, s.UserID, s.ProjectPath, s.GitBranch, s.CWD,
		string(s.Status), s.StartedAt, s.UpdatedAt, s.TokensIn, s.TokensOut, s.TurnCount,
		nullableString(s.ProjectID), s.Description, nullableString(s.EphemeralPublicKey), 0.0)
	if err != nil {
		return fmt.Errorf("upsert session: %w", err)
	}
	return nil
}

// EnsureSession creates a minimal session row if it doesn't exist.
// Unlike UpsertSession, it never overwrites existing metadata.
func EnsureSession(db *sql.DB, s *model.Session) error {
	_, err := db.Exec(`
		INSERT OR IGNORE INTO sessions (id, device_id, user_id, project_path, git_branch, cwd, status, started_at, updated_at, tokens_in, tokens_out, turn_count, project_id, description, ephemeral_public_key, cost_usd)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, s.ID, s.DeviceID, s.UserID, s.ProjectPath, s.GitBranch, s.CWD,
		string(s.Status), s.StartedAt, s.UpdatedAt, s.TokensIn, s.TokensOut, s.TurnCount,
		nullableString(s.ProjectID), s.Description, nullableString(s.EphemeralPublicKey), 0.0)
	if err != nil {
		return fmt.Errorf("ensure session: %w", err)
	}
	return nil
}

func AccumulateSessionCost(db *sql.DB, sessionID string, costUsd float64) error {
	if costUsd <= 0 || costUsd > 1000 {
		return nil // ignore non-positive or unreasonably large costs
	}
	_, err := db.Exec(`UPDATE sessions SET cost_usd = cost_usd + ?, updated_at = ? WHERE id = ?`,
		costUsd, time.Now(), sessionID)
	if err != nil {
		return fmt.Errorf("accumulate session cost: %w", err)
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
		started_at, updated_at, tokens_in, tokens_out, turn_count, project_id, description, ephemeral_public_key, cost_usd
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
			&projectID, &s.Description, &ephPubKey, &s.CostUsd)
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
			started_at, updated_at, tokens_in, tokens_out, turn_count, project_id, description, ephemeral_public_key, cost_usd
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
			&pid, &s.Description, &ephPubKey, &s.CostUsd)
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
			started_at, updated_at, tokens_in, tokens_out, turn_count, project_id, description, ephemeral_public_key, cost_usd
		FROM sessions WHERE id = ?
	`, sessionID).Scan(&s.ID, &s.DeviceID, &s.UserID, &s.ProjectPath, &s.GitBranch,
		&s.CWD, &s.Status, &s.StartedAt, &s.UpdatedAt, &s.TokensIn, &s.TokensOut, &s.TurnCount,
		&projectID, &s.Description, &ephPubKey, &s.CostUsd)
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
			started_at, updated_at, tokens_in, tokens_out, turn_count, project_id, description, ephemeral_public_key, cost_usd
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
			&projectID, &s.Description, &ephPubKey, &s.CostUsd)
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

func UpdateSessionProjectID(db *sql.DB, sessionID, projectID string) error {
	_, err := db.Exec(`UPDATE sessions SET project_id = ? WHERE id = ?`, projectID, sessionID)
	if err != nil {
		return fmt.Errorf("update session project_id: %w", err)
	}
	return nil
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
